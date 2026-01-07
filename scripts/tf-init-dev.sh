#!/usr/bin/env bash
set -euo pipefail

: "${AWS_PROFILE:?AWS_PROFILE is required (ex: dev)}"
: "${AWS_REGION:=eu-west-3}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

echo "==> Init dev environment with remote backend"
echo "AWS_PROFILE=${AWS_PROFILE}"
echo "AWS_REGION=${AWS_REGION}"
echo

terraform -chdir=infra/environments/dev init -reconfigure -backend-config=backend.hcl
terraform -chdir=infra/environments/dev validate
terraform -chdir=infra/environments/dev plan 
terraform -chdir=infra/environments/dev apply 