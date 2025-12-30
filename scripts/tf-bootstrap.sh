#!/usr/bin/env bash
set -euo pipefail
# -e: exit on error
# -u: error on unset variables (prevents silent bugs)
# -o pipefail: pipelines fail if any command fails

# Fail fast if AWS_PROFILE isn't set (prevents using wrong account by accident)
: "${AWS_PROFILE:?AWS_PROFILE is required (ex: dev)}"

# Default region if not provided
: "${AWS_REGION:=eu-west-3}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

# Discover account id from current credentials
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# Bucket names must be globally unique -> include account id + region
BUCKET="replicasafeeks-tfstate-${ACCOUNT_ID}-${AWS_REGION}"

# Lock table name (regional resource, not global)
TABLE="replicasafeeks-tflock"

echo "==> Bootstrap Terraform backend"
echo "AWS_PROFILE=${AWS_PROFILE}"
echo "AWS_REGION=${AWS_REGION}"
echo "Account=${ACCOUNT_ID}"
echo "Bucket=${BUCKET}"
echo "DynamoDB=${TABLE}"
echo

# Init downloads providers and prepares the working directory
terraform -chdir=infra/bootstrap init

# Apply creates the backend resources
terraform -chdir=infra/bootstrap apply \
  -var="region=${AWS_REGION}" \
  -var="state_bucket_name=${BUCKET}" \
  -var="lock_table_name=${TABLE}"
