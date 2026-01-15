#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/lib/common.sh"

usage() {
  echo "Usage: destroy-infra.sh [--env <name>] [--region <region>]"
  print_common_flags_help
}

# Parse flags first (so ENV_NAME is set), allow --help
if ! parse_common_flags "$@"; then
  usage
  exit 0
fi

ENV_DIR="${ROOT_DIR}/infra/environments/${ENV_NAME}"

if [[ ! -d "${ENV_DIR}" ]]; then
  echo "ERROR: Environment directory '${ENV_DIR}' does not exist."
  echo "Nothing to destroy."
  exit 1
fi

if [[ ! -f "${ENV_DIR}/terraform.tfstate" && ! -d "${ENV_DIR}/.terraform" ]]; then
  echo "No Terraform state found in '${ENV_DIR}'. Nothing to destroy."
  exit 0
fi

echo "Destroying infrastructure in environment from: ${ENV_DIR}"
cd "${ENV_DIR}"

terraform destroy -auto-approve

echo "Infrastructure destroyed."
echo "NOTE: Remote backend resources (S3 state bucket + DynamoDB lock table) are intentionally NOT destroyed."
echo "Verify in AWS that EKS/VPC/NAT/EC2/LB are gone."
