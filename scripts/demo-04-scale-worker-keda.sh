#!/usr/bin/env bash
# demo-04-scale-worker-keda.sh — Prove KEDA scales the worker based on SQS queue depth.
#
# What it proves:
#   - KEDA ScaledObject trigger: aws-sqs-queue, queueLength=5, maxReplicaCount=10
#   - Pumping 100 messages → KEDA scales worker from 0/1 to 10 replicas
#   - Worker drains the queue, KEDA scales back to 0 (or minReplicaCount)
#   - Scale-down cooldown (default 5 min) is observable
#
# Usage:
#   ./scripts/demo-04-scale-worker-keda.sh [message-count]
#   message-count defaults to 100
#
# Prerequisites:
#   - demo-01-deploy.sh completed
#   - AWS credentials available (KEDA reads SQS depth via IRSA)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MSG_COUNT="${1:-100}"
TF_DIR="${ROOT_DIR}/infra/environments/dev"
AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
POLL_INTERVAL=10     # seconds between replica count polls

banner() { echo; echo "==> $*"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need kubectl
need aws
need terraform

# Auth check
if ! aws sts get-caller-identity --profile "${AWS_PROFILE}" >/dev/null 2>&1; then
  echo "ERROR: Not authenticated to AWS. Run: ./bin/rsedp aws"
  exit 1
fi

# Resolve queue URL
QUEUE_URL="$(terraform -chdir="${TF_DIR}" output -raw sqs_queue_url 2>/dev/null || true)"
[[ -n "${QUEUE_URL}" ]] || { echo "ERROR: terraform output sqs_queue_url missing"; exit 1; }

banner "Starting state"
echo "--- ScaledObject ---"
kubectl -n demo-app get scaledobject worker -o wide
echo
echo "--- Worker replicas ---"
kubectl -n demo-app get deploy worker
echo
echo "--- Queue depth (before) ---"
aws sqs get-queue-attributes \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --queue-url "${QUEUE_URL}" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' \
  --output text

banner "Pumping ${MSG_COUNT} messages into SQS queue"
echo "Queue URL: ${QUEUE_URL}"
echo

BATCH_SIZE=10
BATCHES=$(( (MSG_COUNT + BATCH_SIZE - 1) / BATCH_SIZE ))
for b in $(seq 1 "${BATCHES}"); do
  ENTRIES=""
  for j in $(seq 1 "${BATCH_SIZE}"); do
    IDX=$(( (b-1)*BATCH_SIZE + j ))
    [[ ${IDX} -le ${MSG_COUNT} ]] || break
    EVENT_ID="keda-demo-$(date +%s)-${IDX}"
    MSG="{\"event_id\":\"${EVENT_ID}\",\"type\":\"keda.demo\",\"payload\":{\"n\":${IDX}},\"ts\":$(date +%s)}"
    ENTRIES="${ENTRIES} Id=msg${IDX},MessageBody='${MSG}'"
  done
  # Send batch
  eval "aws sqs send-message-batch \
    --profile '${AWS_PROFILE}' \
    --region '${AWS_REGION}' \
    --queue-url '${QUEUE_URL}' \
    --entries ${ENTRIES}" >/dev/null
  echo -n "."
done
echo
echo "[info] All ${MSG_COUNT} messages sent."

banner "Watching KEDA scale-out (press Ctrl+C to stop watching)"
echo "Polling every ${POLL_INTERVAL}s — KEDA polling interval is 30s by default."
echo

START_TS=$(date +%s)
MAX_REPLICAS=0
for _ in $(seq 1 60); do
  REPLICAS="$(kubectl -n demo-app get deploy worker -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  REPLICAS="${REPLICAS:-0}"
  QUEUE_DEPTH="$(aws sqs get-queue-attributes \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --queue-url "${QUEUE_URL}" \
    --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' \
    --output text 2>/dev/null || echo '?')"
  ELAPSED=$(( $(date +%s) - START_TS ))
  echo "  [+${ELAPSED}s] worker_replicas=${REPLICAS}  queue_depth=${QUEUE_DEPTH}"
  [[ ${REPLICAS} -gt ${MAX_REPLICAS} ]] && MAX_REPLICAS=${REPLICAS}
  # Stop watching once queue is drained
  if [[ "${QUEUE_DEPTH}" == "0" ]] && [[ ${REPLICAS} -gt 0 ]]; then
    echo "[info] Queue drained. Worker will scale down after cooldown (~5 min)."
    break
  fi
  sleep "${POLL_INTERVAL}"
done

banner "Final state"
echo "--- ScaledObject ---"
kubectl -n demo-app get scaledobject worker
echo
echo "--- Worker replicas (may still be cooling down) ---"
kubectl -n demo-app get deploy worker
echo
echo "Peak replicas observed: ${MAX_REPLICAS}"

banner "Expected evidence"
cat <<'EOF'
  - Queue depth rose to ~100 after pump
  - KEDA scaled worker: 1 → 10 replicas (queueLength=5, 100/5=20 but capped at maxReplicaCount=10)
  - Queue drained within ~2 min at 10 replicas
  - KEDA scaled worker back to 0 after cooldownPeriod (default: 300 s)

See docs/demo/keda-worker.md for a full walkthrough with annotated output.
EOF

banner "Demo 04 complete."
echo "Next: ./scripts/demo-05-incident-001.sh"
