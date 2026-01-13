#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${TF_DIR:-$ROOT_DIR/infra/environments/dev}"
AWS_REGION="${AWS_REGION:-eu-west-3}"
COUNT="${1:-20}"

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
require terraform
require aws

QUEUE_URL="$(cd "$TF_DIR" && terraform output -raw keda_demo_queue_url)"

echo "[pump] queue_url=$QUEUE_URL"
echo "[pump] sending $COUNT messages..."

for i in $(seq 1 "$COUNT"); do
  aws sqs send-message \
    --region "$AWS_REGION" \
    --queue-url "$QUEUE_URL" \
    --message-body "demo-msg-$i" >/dev/null
done

echo "[pump] done."
