#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
NAMESPACE="${NAMESPACE:-logging}"
RELEASE="${RELEASE:-logging}"
CHART="${CHART:-aws/aws-for-fluent-bit}"
CHART_VERSION="${CHART_VERSION:-}"  # optionally pin, e.g. "0.1.35"
VALUES_FILE="${VALUES_FILE:-platform/addons/logging-cloudwatch/values.yaml}"

CLUSTER_NAME="${CLUSTER_NAME:-}"          # REQUIRED for log group template
CLOUDWATCH_ROLE_ARN="${CLOUDWATCH_ROLE_ARN:-}"  # OPTIONAL (IRSA)

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'"; exit 1; }; }
info() { echo "[INFO] $*"; }
fail() { echo "[FAIL] $*"; exit 1; }

need kubectl
need helm

[[ -f "${VALUES_FILE}" ]] || fail "Values file not found: ${VALUES_FILE}"
[[ -n "${CLUSTER_NAME}" ]] || fail "CLUSTER_NAME is required (example: CLUSTER_NAME=replicasafe-dev ./scripts/install-logging.sh)"

info "Installing logging -> CloudWatch (aws-for-fluent-bit)"
info "  Namespace:     ${NAMESPACE}"
info "  Release:       ${RELEASE}"
info "  Chart:         ${CHART}"
info "  Chart version: ${CHART_VERSION:-<not pinned>}"
info "  Region:        ${AWS_REGION}"
info "  Cluster:       ${CLUSTER_NAME}"
info "  Values:        ${VALUES_FILE}"
info "  IRSA role:     ${CLOUDWATCH_ROLE_ARN:-<none>}"

kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

helm repo add aws https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# Build helm args
args=(
  upgrade --install "${RELEASE}" "${CHART}"
  --namespace "${NAMESPACE}"
  -f "${VALUES_FILE}"
  --set "cloudWatch.region=${AWS_REGION}"
  --set "cloudWatch.logGroupTemplate=/aws/eks/${CLUSTER_NAME}/\$(kubernetes['namespace_name'])"
  --wait
  --timeout 10m
)

# Optional pin
if [[ -n "${CHART_VERSION}" ]]; then
  args+=( --version "${CHART_VERSION}" )
else
  info "CHART_VERSION not set → installing latest chart (set CHART_VERSION to pin)."
fi

# Optional IRSA annotation injection
if [[ -n "${CLOUDWATCH_ROLE_ARN}" ]]; then
  args+=( --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${CLOUDWATCH_ROLE_ARN}" )
else
  info "CLOUDWATCH_ROLE_ARN not set → Fluent Bit will rely on node IAM role (OK for dev, IRSA recommended)."
fi

helm "${args[@]}"

info "Pods:"
kubectl -n "${NAMESPACE}" get pods -o wide

info "ServiceAccount (check IRSA annotation if set):"
kubectl -n "${NAMESPACE}" get sa aws-for-fluent-bit -o yaml | sed -n '1,120p'

echo
info "Expected CloudWatch log group pattern:"
echo "  /aws/eks/${CLUSTER_NAME}/<namespace>"
echo "Example namespaces: kube-system, default, constellation, etc."

echo
info "CLI verification commands (examples):"
echo "  aws logs describe-log-groups --log-group-name-prefix /aws/eks/${CLUSTER_NAME}/"
echo "  aws logs describe-log-streams --log-group-name /aws/eks/${CLUSTER_NAME}/default --order-by LastEventTime --descending"
