#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; }
info() { echo "[INFO] $*"; }

usage() {
  cat <<'H'
Usage:
  ./bin/rsedp check

Checks:
  - kubectl connectivity + nodes
  - metrics-server (kubectl top nodes)
  - EBS CSI driver presence
  - ALB controller presence
  - cluster-autoscaler presence
  - KEDA presence
  - (optional) SQS demo objects presence
  - (optional) ALB demo ingress hostname
H
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }

# AWS identity is optional (cluster checks can work without it)
if command -v aws >/dev/null 2>&1; then
  if aws sts get-caller-identity --profile "${AWS_PROFILE}" >/dev/null 2>&1; then
    pass "AWS identity available (profile=${AWS_PROFILE})"
  else
    fail "AWS identity NOT available (run: ./bin/rsedp aws)"
  fi
else
  info "aws CLI not found; skipping AWS identity check"
fi

# Cluster connectivity
if kubectl get nodes >/dev/null 2>&1; then
  pass "kubectl can reach cluster"
  kubectl get nodes -o wide
else
  fail "kubectl cannot reach cluster (kubeconfig/cluster down)"
  exit 1
fi

# metrics-server
if kubectl top nodes >/dev/null 2>&1; then
  pass "metrics-server working (kubectl top nodes)"
else
  fail "metrics-server not working (run: ./bin/rsedp metrics)"
fi

# EBS CSI: either addon pods or CSI driver objects
if kubectl -n kube-system get pods 2>/dev/null | grep -qi 'ebs-csi'; then
  pass "EBS CSI pods present"
elif kubectl get csidriver 2>/dev/null | grep -qi 'ebs'; then
  pass "CSIDriver present (EBS)"
else
  fail "EBS CSI not detected (storage may not work)"
fi

# ALB controller
if kubectl -n kube-system get deploy aws-load-balancer-controller >/dev/null 2>&1; then
  pass "AWS Load Balancer Controller installed"
else
  fail "AWS Load Balancer Controller missing (run: ./bin/rsedp alb)"
fi

# Cluster Autoscaler
if kubectl -n kube-system get deploy cluster-autoscaler >/dev/null 2>&1; then
  pass "Cluster Autoscaler installed"
else
  fail "Cluster Autoscaler missing (run: ./bin/rsedp autoscaler)"
fi

# KEDA
if kubectl -n keda get deploy keda-operator >/dev/null 2>&1; then
  pass "KEDA installed"
else
  fail "KEDA missing (run: ./bin/rsedp sqs)"
fi

# Optional: SQS demo objects
if kubectl -n default get scaledobject.keda.sh sqs-worker >/dev/null 2>&1; then
  pass "SQS demo ScaledObject present"
else
  info "SQS demo ScaledObject not present (ok if you haven't run ./bin/rsedp sqs)"
fi

# Optional: ALB demo ingress hostname
if kubectl -n demo-ingress get ingress web >/dev/null 2>&1; then
  HOST="$(kubectl -n demo-ingress get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "${HOST}" ]]; then
    pass "ALB demo ingress has hostname: ${HOST}"
  else
    info "ALB demo ingress exists but no hostname yet (ALB provisioning still running)"
  fi
else
  info "ALB demo ingress not present (ok if you haven't run ./bin/rsedp demo-alb)"
fi

# --- Velero checks ---
if kubectl get ns velero >/dev/null 2>&1; then
  kubectl -n velero rollout status deploy/velero --timeout=2m >/dev/null \
    && pass "velero deployment ready" \
    || fail "velero deployment not ready"

  bsl_phase="$(kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null || echo missing)"
  if [ "${bsl_phase}" = "Available" ]; then
    pass "velero backupstoragelocation default: Available"
  else
    fail "velero backupstoragelocation default not Available (phase=${bsl_phase})"
  fi
else
  info "velero not installed (namespace missing)"
fi


# ---- VPC Endpoints checks (AWS-side, before kubectl) ----
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[FAIL] missing: $1"; exit 1; }; }

require_cmd aws
require_cmd terraform

ENV_DIR="${ENV_DIR:-infra/environments/dev}"

info "[AWS] Checking VPC endpoints exist (reduce NAT spend)..."
pushd "$ENV_DIR" >/dev/null

# Grab vpc id from outputs (ground truth)
VPC_ID="$(terraform output -raw vpc_id 2>/dev/null || true)"
REGION="$(terraform output -raw region 2>/dev/null || true)"

if [[ -z "${VPC_ID}" ]]; then
  fail "Could not read terraform output vpc_id (did you run terraform apply?)"
  popd >/dev/null
  exit 1
fi

# Describe all endpoints in that VPC
ENDPOINTS_JSON="$(aws ec2 describe-vpc-endpoints --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'VpcEndpoints[].{Service:ServiceName,Type:VpcEndpointType,State:State,PrivateDns:PrivateDnsEnabled,Id:VpcEndpointId}' \
  --output json)"

popd >/dev/null

# helper: check presence
has_service() { echo "$ENDPOINTS_JSON" | jq -e --arg s "$1" '.[] | select(.Service==$s)' >/dev/null; }
get_field()   { echo "$ENDPOINTS_JSON" | jq -r --arg s "$1" --arg f "$2" '.[] | select(.Service==$s) | .[$f]'; }

# Expected service names
S3="com.amazonaws.${REGION}.s3"
ECR_API="com.amazonaws.${REGION}.ecr.api"
ECR_DKR="com.amazonaws.${REGION}.ecr.dkr"
STS="com.amazonaws.${REGION}.sts"

# S3 gateway endpoint
if has_service "$S3"; then
  [[ "$(get_field "$S3" "Type")" == "Gateway" ]] || fail "S3 endpoint exists but is not Gateway"
  pass "S3 gateway endpoint present"
else
  fail "Missing S3 gateway endpoint (${S3})"
fi

# Interface endpoints
for svc in "$ECR_API" "$ECR_DKR" "$STS"; do
  if has_service "$svc"; then
    [[ "$(get_field "$svc" "Type")" == "Interface" ]] || fail "$svc exists but is not Interface"
    [[ "$(get_field "$svc" "PrivateDns")" == "true" ]] || fail "$svc exists but PrivateDnsEnabled is not true"
    pass "Interface endpoint OK: $svc"
  else
    fail "Missing interface endpoint: $svc"
  fi
done


echo
pass "Check complete."
