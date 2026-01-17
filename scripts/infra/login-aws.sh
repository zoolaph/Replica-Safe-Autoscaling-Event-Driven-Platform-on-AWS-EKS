#!/usr/bin/env bash
set -euo pipefail

PROFILE="${AWS_PROFILE:-dev}"
REGION="${AWS_DEFAULT_REGION:-eu-west-3}"

echo "Using AWS profile: ${PROFILE}"
echo "Default region: ${REGION}"

# If profile not configured, run interactive setup once.
if ! aws configure list-profiles | grep -qx "${PROFILE}"; then
  echo "AWS profile '${PROFILE}' not found. Running one-time SSO setup..."
  echo "You will need: SSO Start URL + SSO Region (Identity Center home region)."
  aws configure sso --profile "${PROFILE}"
fi

# Check if already authenticated (fast + reliable)
if aws sts get-caller-identity --profile "${PROFILE}" >/dev/null 2>&1; then
  echo "AWS SSO session is already valid."
else
  echo "No valid AWS SSO session. Logging in..."
  aws sso login --profile "${PROFILE}"
fi

echo "Authenticated identity:"
aws sts get-caller-identity --profile "${PROFILE}"
