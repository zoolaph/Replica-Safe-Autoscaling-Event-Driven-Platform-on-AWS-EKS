#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

TF_DIR="infra/environments/dev"
COUNT="${1:-20}"

usage() {
  cat <<H
Usage:
  ./bin/rsedp pump-sqs [count]

Sends messages to the demo SQS queue (from terraform output keda_demo_queue_url).
Default count: 20
H
}

case "${COUNT:-}" in
  -h|--help) usage; exit 0 ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need aws
need terraform

# Must be authenticated
if ! aws sts get-caller-identity --profile "${AWS_PROFILE}" >/dev/null 2>&1; then
  echo "ERROR: Not authenticated. Run: ./bin/rsedp aws"
  exit 1
fi

QUEUE_URL="$(terraform -chdir="$TF_DIR" output -raw keda_demo_queue_url 2>/dev/null || true)"
[[ -n "$QUEUE_URL" ]] || { echo "ERROR: terraform output keda_demo_queue_url missing in ${TF_DIR}"; exit 1; }

echo "[pump] queue_url=$QUEUE_URL"
echo "[pump] sending ${COUNT} messages..."

for i in $(seq 1 "${COUNT}"); do
  aws sqs send-message \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --queue-url "${QUEUE_URL}" \
    --message-body "demo-msg-$i" >/dev/null
done

echo "[pump] done."
