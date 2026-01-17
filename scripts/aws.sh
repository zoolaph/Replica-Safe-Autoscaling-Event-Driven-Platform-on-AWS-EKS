#!/usr/bin/env bash
set -euo pipefail

PROFILE="${AWS_PROFILE:-dev}"
REGION="${AWS_DEFAULT_REGION:-eu-west-3}"

usage() {
  cat <<H
Usage:
  ./bin/rsedp aws
  AWS_PROFILE=dev AWS_DEFAULT_REGION=eu-west-3 ./bin/rsedp aws

What it does:
  - Ensures AWS SSO profile exists (runs 'aws configure sso' once if missing)
  - Logs in with 'aws sso login' if session is not valid
  - Prints caller identity

Defaults:
  AWS_PROFILE=dev
  AWS_DEFAULT_REGION=eu-west-3
H
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

echo "Using AWS profile: ${PROFILE}"
echo "Default region: ${REGION}"

# Ensure AWS CLI exists
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found"; exit 1; }

# If profile not configured, run interactive setup once.
if ! aws configure list-profiles | grep -qx "${PROFILE}"; then
  echo "AWS profile '${PROFILE}' not found. Running one-time SSO setup..."
  echo "You will need: SSO Start URL + SSO Region (Identity Center home region)."
  aws configure sso --profile "${PROFILE}"
fi

# Check if already authenticated
if aws sts get-caller-identity --profile "${PROFILE}" >/dev/null 2>&1; then
  echo "AWS SSO session is already valid."
else
  echo "No valid AWS SSO session. Logging in..."
  aws sso login --profile "${PROFILE}"
fi

echo "Authenticated identity:"
aws sts get-caller-identity --profile "${PROFILE}"
