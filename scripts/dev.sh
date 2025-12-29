#!/usr/bin/env bash
set -euo pipefail

# Ensure tools
bash scripts/bootstrap.sh

# Ensure AWS login (SSO)
bash scripts/aws-login.sh

# Verify toolchain
bash scripts/verify-env.sh

echo ""
echo "Ready."
echo "Tip: export AWS_PROFILE=${AWS_PROFILE:-dev}"
echo "Tip: export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-eu-west-3}"
