#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_REGION:-eu-west-3}"   
TF_DIR="${TF_DIR:-infra/environments/dev}"  

for bin in terraform kubectl aws; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: required command not found in PATH: $bin" >&2
    exit 1
  fi
done


CLUSTER_NAME="${CLUSTER_NAME:-}"

if [[ -z "$CLUSTER_NAME" ]]; then
    CLUSTER_NAME="$(terraform -chdir="$TF_DIR" output -raw cluster_name 2>/dev/null || true)"
fi

if [[ -z "$CLUSTER_NAME" ]]; then
    echo "ERROR: CLUSTER_NAME is empty." >&2
    echo "Fix one of the following:" >&2
    echo " - export CLUSTER_NAME=<name>" >&2
    echo " - set CLUSTER_NAME in Terraform outputs in ${TF_DIR}" >&2   
    exit 1
fi

echo "==> Using configuration:"
echo "    AWS_PROFILE: $AWS_PROFILE"
echo "    AWS_REGION:  $AWS_REGION"
echo "    TF_DIR:      $TF_DIR"
echo "    CLUSTER_NAME:$CLUSTER_NAME"

echo "==> Ensuring AWS SSO session exists (may open browser)..."
aws sso login --profile "$AWS_PROFILE" >/dev/null

echo "==> AWS identity:"
aws sts get-caller-identity --profile "$AWS_PROFILE"

echo "==> Updating kubeconfig to point to target cluster..."
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME" \
  --profile "$AWS_PROFILE" >/dev/null

echo "==> Verifying cluster access (kubectl get nodes)..."
kubectl get nodes

echo "==> Platform bootstrap OK."
echo "    Next: install addons (EBS CSI, metrics-server, ALB controller, etc.)"