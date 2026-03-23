#!/usr/bin/env bash
# demo-05-incident-001.sh — Reproduce INCIDENT-001: duplicate event processing.
#
# What it proves (the "before" state):
#   - In non-idempotent mode the worker uses a 1-second SQS visibility timeout
#     and never deletes messages — every replica processes every message.
#   - Scaling to 5 replicas causes duplicate rows in `processed_events`.
#   - The `worker_events_processed_total{mode="non-idempotent"}` counter inflates
#     far beyond the number of unique events sent.
#
# Usage:
#   ./scripts/demo-05-incident-001.sh [event-count]
#   event-count defaults to 50
#
# IMPORTANT:
#   This demo intentionally breaks data correctness.
#   Run demo-06-fix-idempotency.sh afterward to restore the system.
#
# Prerequisites:
#   - demo-01-deploy.sh completed (stack deployed in idempotent mode)
#   - AWS credentials available
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infra/environments/dev"
EVENT_COUNT="${1:-50}"
AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
BROKEN_REPLICAS=5
DRAIN_WAIT=45   # seconds for worker to process messages (1-s vis timeout re-delivers fast)

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

QUEUE_URL="$(terraform -chdir="${TF_DIR}" output -raw sqs_queue_url 2>/dev/null || true)"
[[ -n "${QUEUE_URL}" ]] || { echo "ERROR: terraform output sqs_queue_url missing"; exit 1; }

banner "INCIDENT-001 REPRO — non-idempotent worker mode"
echo "WARNING: This demo intentionally causes data duplication."
echo "Run demo-06-fix-idempotency.sh afterward."
echo

# Step 1: Switch worker to broken mode
banner "Step 1 — Switch worker to WORKER_MODE=non-idempotent"
kubectl -n demo-app set env deployment/worker WORKER_MODE=non-idempotent
kubectl -n demo-app rollout status deployment/worker --timeout=60s
echo "[info] Worker mode: $(kubectl -n demo-app get deploy worker -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="WORKER_MODE")].value}')"

# Step 2: Scale to 5 replicas to amplify the problem
banner "Step 2 — Scale worker to ${BROKEN_REPLICAS} replicas"
kubectl -n demo-app scale deployment/worker --replicas="${BROKEN_REPLICAS}"
kubectl -n demo-app rollout status deployment/worker --timeout=90s
echo "[info] Current replicas: $(kubectl -n demo-app get deploy worker -o jsonpath='{.status.readyReplicas}')"

# Step 3: Clear processed_events table for a clean count
banner "Step 3 — Clear processed_events table (fresh slate)"
DB_POD="$(kubectl -n demo-app get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')"
kubectl -n demo-app exec "${DB_POD}" -- \
  psql -U app -d app -c "TRUNCATE processed_events;" 2>/dev/null
echo "[info] processed_events truncated."

# Step 4: Send events
banner "Step 4 — Sending ${EVENT_COUNT} events via SQS (directly, bypassing API)"
for i in $(seq 1 "${EVENT_COUNT}"); do
  EVENT_ID="incident001-$(date +%s%3N)-${i}"
  MSG="{\"event_id\":\"${EVENT_ID}\",\"type\":\"incident.demo\",\"payload\":{\"n\":${i}},\"ts\":$(date +%s)}"
  aws sqs send-message \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --queue-url "${QUEUE_URL}" \
    --message-body "${MSG}" >/dev/null
done
echo "[info] ${EVENT_COUNT} events sent."

# Step 5: Watch worker logs for BROKEN log lines
banner "Step 5 — Worker logs (watching for BROKEN processed lines)"
echo "Tailing logs for ${DRAIN_WAIT}s..."
timeout "${DRAIN_WAIT}" kubectl -n demo-app logs -l app=worker --prefix --follow 2>/dev/null \
  | grep --line-buffered "BROKEN\|processed\|deduped" \
  || true

# Step 6: Count rows
banner "Step 6 — Row count in processed_events"
ROW_COUNT="$(kubectl -n demo-app exec "${DB_POD}" -- \
  psql -U app -d app -tAc \
  "SELECT COUNT(*) FROM processed_events WHERE type='incident.demo';" 2>/dev/null | tr -d '[:space:]')"

echo
echo "  Events sent:           ${EVENT_COUNT}"
echo "  Rows in DB:            ${ROW_COUNT}"
if [[ -n "${ROW_COUNT}" ]] && [[ "${ROW_COUNT}" -gt "${EVENT_COUNT}" ]]; then
  RATIO=$(echo "scale=1; ${ROW_COUNT} / ${EVENT_COUNT}" | bc 2>/dev/null || echo "?")
  echo "  Duplication ratio:     ${RATIO}x"
  echo
  echo "  [INCIDENT REPRODUCED] — ${ROW_COUNT} rows for ${EVENT_COUNT} unique events."
elif [[ -n "${ROW_COUNT}" ]]; then
  echo "  [NOTE] ${ROW_COUNT} rows — may need more time or more replicas to amplify. Re-run with higher count."
fi

# Step 7: Show pod breakdown — which pod wrote what
banner "Step 7 — Duplicate breakdown by pod"
kubectl -n demo-app exec "${DB_POD}" -- \
  psql -U app -d app -c \
  "SELECT pod_name, COUNT(*) AS row_count FROM processed_events WHERE type='incident.demo' GROUP BY pod_name ORDER BY row_count DESC;" \
  2>/dev/null || true

banner "Incident reproduced."
echo
echo "Root cause:"
echo "  1. VISIBILITY_TIMEOUT=1s  — message reappears before the writing pod deletes it"
echo "  2. No delete_message call — message stays on queue forever"
echo "  3. No UNIQUE constraint   — processed_events accepts any number of duplicate rows"
echo
echo "See docs/incidents/INCIDENT-001.md for the full postmortem."
echo
echo "Next: ./scripts/demo-06-fix-idempotency.sh"
