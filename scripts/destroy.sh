#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

ENV_DIR="infra/environments/dev"

usage() {
  cat <<H
Usage:
  ./bin/rsedp destroy

What it destroys:
  - demo namespaces: demo-ingress, demo-storage (if present)
  - demo workloads: cpu-hog, sqs-worker/scaledobject (if present)
  - terraform environment: ${ENV_DIR}
  - DOES NOT destroy terraform backend (S3+DynamoDB)
H
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need terraform

# kubectl is optional (if cluster already gone we still want terraform destroy)
if command -v kubectl >/dev/null 2>&1; then
  echo "==> Cleaning Kubernetes demo resources (best-effort)"

  # ALB demo
  kubectl delete ns demo-ingress --ignore-not-found=true || true

  # Storage demo
  kubectl delete ns demo-storage --ignore-not-found=true || true

  # Autoscaling demo (default ns)
  kubectl delete deploy cpu-hog --ignore-not-found=true || true

  # SQS/KEDA demo (default ns)
  kubectl delete scaledobject.keda.sh sqs-worker -n default --ignore-not-found=true || true
  kubectl delete triggerauthentication.keda.sh aws-sqs-auth -n default --ignore-not-found=true || true
  kubectl delete deploy sqs-worker -n default --ignore-not-found=true || true
  kubectl delete sa sqs-worker -n default --ignore-not-found=true || true
fi

if [[ ! -d "${ENV_DIR}" ]]; then
  echo "ERROR: Environment directory '${ENV_DIR}' does not exist."
  exit 1
fi

if [[ ! -f "${ENV_DIR}/terraform.tfstate" && ! -d "${ENV_DIR}/.terraform" ]]; then
  echo "No Terraform state found in '${ENV_DIR}'. Nothing to destroy."
  exit 0
fi

echo "==> Terraform destroy (${ENV_DIR})"
terraform -chdir="${ENV_DIR}" destroy -auto-approve

echo "==> Destroy complete."
echo "NOTE: Terraform backend (S3 state bucket + DynamoDB lock table) is intentionally NOT destroyed."
