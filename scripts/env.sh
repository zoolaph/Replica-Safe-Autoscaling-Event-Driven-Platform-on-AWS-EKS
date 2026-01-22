#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

ENV_DIR="infra/environments/dev"
CLUSTER_NAME="replicasafe-dev"

usage() {
  cat <<H
Usage:
  ./bin/rsedp env

Environment:
  AWS_PROFILE         (default: dev)
  AWS_DEFAULT_REGION  (default: eu-west-3)

What it does:
  - terraform init/validate/plan/apply in ${ENV_DIR}
  - updates kubeconfig for cluster: ${CLUSTER_NAME}
  - verifies access: kubectl get nodes
H
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found"; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo "ERROR: terraform not found"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }

# Must be authenticated
if ! aws sts get-caller-identity --profile "${AWS_PROFILE}" >/dev/null 2>&1; then
  echo "ERROR: Not authenticated to AWS for profile '${AWS_PROFILE}'."
  echo "Run: ./bin/rsedp aws"
  exit 1
fi

echo "==> Deploy dev environment"
echo "AWS_PROFILE=${AWS_PROFILE}"
echo "AWS_REGION=${AWS_REGION}"
echo "ENV_DIR=${ENV_DIR}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo

# Ensure backend.hcl exists (since your init uses it)
if [[ ! -f "${ENV_DIR}/backend.hcl" ]]; then
  echo "ERROR: Missing ${ENV_DIR}/backend.hcl"
  echo "Did you run: ./bin/rsedp bootstrap ?"
  exit 1
fi

echo "==> Terraform init (remote backend)"
terraform -chdir="${ENV_DIR}" init -reconfigure -backend-config=backend.hcl

echo "==> Terraform validate"
terraform -chdir="${ENV_DIR}" validate

echo "==> Terraform plan"
terraform -chdir="${ENV_DIR}" plan

echo "==> Terraform apply"
terraform -chdir="${ENV_DIR}" apply -auto-approve

echo "==> Update kubeconfig"
aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${CLUSTER_NAME}" \
  --profile "${AWS_PROFILE}" >/dev/null

echo "==> Verify cluster access"
kubectl get nodes

echo "==> Dev environment ready."
