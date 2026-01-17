#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

TF_DIR="infra/environments/dev"
TMPL="manifests/cluster-autoscaler.yaml.tmpl"

usage() {
  cat <<H
Usage:
  ./bin/rsedp autoscaler

Installs Cluster Autoscaler using terraform outputs from:
  ${TF_DIR}

Requires:
  aws, terraform, kubectl
H
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need aws
need terraform
need kubectl

[[ -f "$TMPL" ]] || { echo "ERROR: missing $TMPL"; exit 1; }

# Ensure authenticated
if ! aws sts get-caller-identity --profile "${AWS_PROFILE}" >/dev/null 2>&1; then
  echo "ERROR: Not authenticated. Run: ./bin/rsedp aws"
  exit 1
fi

CLUSTER_NAME="$(terraform -chdir="${TF_DIR}" output -raw cluster_name 2>/dev/null || true)"
ROLE_ARN="$(terraform -chdir="${TF_DIR}" output -raw cluster_autoscaler_role_arn 2>/dev/null || true)"
# prefer terraform region output if you have it, else keep AWS_DEFAULT_REGION
TF_REGION="$(terraform -chdir="${TF_DIR}" output -raw region 2>/dev/null || true)"
if [[ -n "${TF_REGION}" ]]; then AWS_REGION="${TF_REGION}"; export AWS_DEFAULT_REGION="${AWS_REGION}"; fi

[[ -n "$CLUSTER_NAME" ]] || { echo "ERROR: terraform output cluster_name missing in ${TF_DIR}"; exit 1; }
[[ -n "$ROLE_ARN" ]] || { echo "ERROR: terraform output cluster_autoscaler_role_arn missing in ${TF_DIR}"; exit 1; }

echo "==> Installing Cluster Autoscaler"
echo "AWS_PROFILE=${AWS_PROFILE}"
echo "AWS_REGION=${AWS_REGION}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "ROLE_ARN=${ROLE_ARN}"
echo

# Ensure kubeconfig points to the cluster
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --profile "$AWS_PROFILE" >/dev/null

# Render and apply template
export CLUSTER_NAME AWS_REGION ROLE_ARN
envsubst < "$TMPL" | kubectl apply -f -

echo "==> Waiting for rollout"
kubectl -n kube-system rollout status deploy/cluster-autoscaler --timeout=180s

echo "==> OK: Cluster Autoscaler installed"
echo "Hint: kubectl -n kube-system logs deploy/cluster-autoscaler --tail=200"
