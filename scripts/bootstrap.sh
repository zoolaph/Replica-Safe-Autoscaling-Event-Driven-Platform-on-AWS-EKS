#!/usr/bin/env bash
set -euo pipefail

# Defaults (simple + predictable)
AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

usage() {
  cat <<H
Usage:
  ./bin/rsedp bootstrap

Environment:
  AWS_PROFILE         (default: dev)
  AWS_DEFAULT_REGION  (default: eu-west-3)

What it does:
  - Uses current AWS credentials to detect ACCOUNT_ID
  - Builds unique S3 bucket name: replicasafeeks-tfstate-<account>-<region>
  - Uses DynamoDB lock table: replicasafeeks-tflock
  - Runs terraform init/apply in infra/bootstrap
H
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found"; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo "ERROR: terraform not found"; exit 1; }

# Must be authenticated; fail clearly
ACCOUNT_ID="$(aws sts get-caller-identity --profile "${AWS_PROFILE}" --query Account --output text 2>/dev/null || true)"
if [[ -z "${ACCOUNT_ID}" || "${ACCOUNT_ID}" == "null" ]]; then
  echo "ERROR: Not authenticated to AWS for profile '${AWS_PROFILE}'."
  echo "Run: ./bin/rsedp aws"
  exit 1
fi

BUCKET="replicasafeeks-tfstate-${ACCOUNT_ID}-${AWS_REGION}"
TABLE="replicasafeeks-tflock"

echo "==> Bootstrap Terraform backend"
echo "AWS_PROFILE=${AWS_PROFILE}"
echo "AWS_REGION=${AWS_REGION}"
echo "Account=${ACCOUNT_ID}"
echo "Bucket=${BUCKET}"
echo "DynamoDB=${TABLE}"
echo

terraform -chdir=infra/bootstrap init

terraform -chdir=infra/bootstrap apply -auto-approve \
  -var="region=${AWS_REGION}" \
  -var="state_bucket_name=${BUCKET}" \
  -var="lock_table_name=${TABLE}"
