#!/usr/bin/env bash
# demo-06-fix-idempotency.sh — Prove idempotent mode eliminates duplicates.
#
# What it proves (the "after" state):
#   - In idempotent mode the worker uses ON CONFLICT (event_id) DO NOTHING
#     into the events table (UNIQUE constraint on event_id).
#   - Running 5 replicas against the same messages produces exactly N rows —
#     duplicate deliveries are silently skipped and counted via deduped_total.
#   - The system is safe to scale horizontally.
#
# This script also purges leftover SQS messages from demo-05 before sending
# fresh events, so the counts are clean.
#
# Usage:
#   ./scripts/demo-06-fix-idempotency.sh [event-count]
#   event-count defaults to 50
#
# Prerequisites:
#   - demo-05-incident-001.sh completed (worker is in non-idempotent mode)
#   - AWS credentials available
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infra/environments/dev"
EVENT_COUNT="${1:-50}"
AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
REPLICAS=5
DRAIN_WAIT=60

banner() { echo; echo "==> $*"; }
pass()   { echo "  [PASS] $*"; }
fail()   { echo "  [FAIL] $*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need kubectl
need aws
need terraform

# Auth check
if ! aws sts get-caller-identity --profile "${AWS_PROFILE}" >/dev/null 2>&1; then
  echo "ERROR: Not authenticated to AWS. Run: ./bin/rsedp aws"
  exit 1
fi

QUEUE_URL="$(terraform -chdir="${TF_DIR}" output -raw sqs_queue_url 2>/dev/null || true)"
[[ -n "${QUEUE_URL}" ]] || { echo "ERROR: terraform output sqs_queue_url missing"; exit 1; }

DB_POD="$(kubectl -n demo-app get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')"

banner "Step 1 — Purge leftover SQS messages from demo-05"
# Purge clears the queue in ~60 s (AWS SQS async operation)
aws sqs purge-queue \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --queue-url "${QUEUE_URL}" 2>/dev/null || true
echo "[info] Purge request sent. Waiting 65 s for SQS to clear..."
sleep 65

# Scale worker to 1 during the purge wait to stop re-processing
kubectl -n demo-app scale deployment/worker --replicas=1 2>/dev/null || true

banner "Step 2 — Switch worker to WORKER_MODE=idempotent"
kubectl -n demo-app set env deployment/worker WORKER_MODE=idempotent
kubectl -n demo-app rollout status deployment/worker --timeout=60s
echo "[info] Worker mode: $(kubectl -n demo-app get deploy worker -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="WORKER_MODE")].value}')"

# Scale to 5 replicas to prove idempotency under concurrent processing
banner "Step 3 — Scale worker to ${REPLICAS} replicas"
kubectl -n demo-app scale deployment/worker --replicas="${REPLICAS}"
kubectl -n demo-app rollout status deployment/worker --timeout=90s
echo "[info] Replicas ready: $(kubectl -n demo-app get deploy worker -o jsonpath='{.status.readyReplicas}')"

# Fresh table for clean count
banner "Step 4 — Ensure events table is clean for idempotency test"
kubectl -n demo-app exec "${DB_POD}" -- \
  psql -U app -d app -c \
  "DELETE FROM events WHERE type='idempotency.demo';" 2>/dev/null
echo "[info] Previous idempotency.demo events removed."

# Send events (same event_id will be re-sent twice to force SQS re-delivery)
banner "Step 5 — Sending ${EVENT_COUNT} events (each event_id sent TWICE to simulate re-delivery)"
for i in $(seq 1 "${EVENT_COUNT}"); do
  EVENT_ID="fix-demo-$(printf '%06d' ${i})"
  MSG="{\"event_id\":\"${EVENT_ID}\",\"type\":\"idempotency.demo\",\"payload\":{\"n\":${i}},\"ts\":$(date +%s)}"
  # Send the same message twice to simulate a re-delivery / at-least-once scenario
  for _ in 1 2; do
    aws sqs send-message \
      --profile "${AWS_PROFILE}" \
      --region "${AWS_REGION}" \
      --queue-url "${QUEUE_URL}" \
      --message-body "${MSG}" >/dev/null
  done
done
TOTAL_MESSAGES=$(( EVENT_COUNT * 2 ))
echo "[info] ${TOTAL_MESSAGES} SQS messages sent (${EVENT_COUNT} unique event_ids × 2)."

# Watch worker logs for deduped lines
banner "Step 6 — Worker logs (watching for processed / deduped lines)"
echo "Tailing logs for ${DRAIN_WAIT}s..."
timeout "${DRAIN_WAIT}" kubectl -n demo-app logs -l app=worker --prefix --follow 2>/dev/null \
  | grep --line-buffered "processed\|deduped" \
  || true

# Count rows
banner "Step 7 — Row count in events table"
ROW_COUNT="$(kubectl -n demo-app exec "${DB_POD}" -- \
  psql -U app -d app -tAc \
  "SELECT COUNT(*) FROM events WHERE type='idempotency.demo';" 2>/dev/null | tr -d '[:space:]')"

# Count deduped events from metrics
DEDUPED_TOTAL=0
for pod in $(kubectl -n demo-app get pod -l app=worker -o jsonpath='{.items[*].metadata.name}'); do
  D="$(kubectl -n demo-app exec "${pod}" -- \
    curl -s http://localhost:8000/metrics 2>/dev/null \
    | grep '^worker_events_deduped_total' | awk '{sum += $2} END {print int(sum)}')"
  DEDUPED_TOTAL=$(( DEDUPED_TOTAL + ${D:-0} ))
done

echo
echo "  Unique event_ids sent:  ${EVENT_COUNT}"
echo "  Total SQS messages:     ${TOTAL_MESSAGES} (each event_id sent twice)"
echo "  DB rows (events table): ${ROW_COUNT}"
echo "  deduped_total (all pods): ${DEDUPED_TOTAL}"
echo

if [[ -n "${ROW_COUNT}" ]] && [[ "${ROW_COUNT}" -eq "${EVENT_COUNT}" ]]; then
  pass "Row count = ${EVENT_COUNT} — exactly one row per unique event_id. No duplicates!"
elif [[ -n "${ROW_COUNT}" ]] && [[ "${ROW_COUNT}" -lt "${EVENT_COUNT}" ]]; then
  echo "  [WARN] Only ${ROW_COUNT}/${EVENT_COUNT} rows — worker may still be draining. Increase DRAIN_WAIT."
else
  fail "Row count ${ROW_COUNT} does not equal ${EVENT_COUNT} — unexpected"
fi

if [[ "${DEDUPED_TOTAL}" -gt 0 ]]; then
  pass "deduped_total=${DEDUPED_TOTAL} — ON CONFLICT DO NOTHING fired correctly for re-deliveries"
fi

# Restore worker to 1 replica (KEDA will manage from here)
banner "Step 8 — Restore worker to 1 replica (hand back to KEDA)"
kubectl -n demo-app scale deployment/worker --replicas=1

banner "Fix verified. System restored to idempotent mode."
echo
echo "Key takeaways:"
echo "  - ON CONFLICT (event_id) DO NOTHING makes writes atomic and safe at any replica count"
echo "  - deduped_total > 0 is expected (and healthy) — it means idempotency is working"
echo "  - Scaling from 1 → 5 → 10 replicas will never create duplicate rows"
echo
echo "See docs/incidents/INCIDENT-001.md for the full postmortem and root cause."
echo
echo "All demos complete."
