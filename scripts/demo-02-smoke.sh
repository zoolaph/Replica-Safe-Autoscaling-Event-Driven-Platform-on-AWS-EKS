#!/usr/bin/env bash
# demo-02-smoke.sh — Send N events via the API and assert N rows land in Postgres.
#
# What it proves:
#   - API /events endpoint is reachable and returns 200
#   - SQS queue is connected (messages produced)
#   - Worker consumes messages (reads from SQS)
#   - Postgres receives exactly N unique rows (idempotency check)
#
# Usage:
#   ./scripts/demo-02-smoke.sh [count]
#   count defaults to 20
#
# Prerequisites:
#   - demo-01-deploy.sh completed successfully
#   - kubectl port-forward running OR API accessible via LoadBalancer
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COUNT="${1:-20}"
API_BASE_URL="${API_BASE_URL:-}"   # override if LB is provisioned
DRAIN_WAIT="${DRAIN_WAIT:-30}"     # seconds to wait for worker to drain queue

banner() { echo; echo "==> $*"; }
pass()   { echo "  [PASS] $*"; }
fail()   { echo "  [FAIL] $*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need kubectl
need curl

# Resolve API URL
if [[ -z "${API_BASE_URL}" ]]; then
  API_SVC_TYPE="$(kubectl -n demo-app get svc api -o jsonpath='{.spec.type}' 2>/dev/null || echo unknown)"
  if [[ "${API_SVC_TYPE}" == "LoadBalancer" ]]; then
    API_HOST="$(kubectl -n demo-app get svc api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [[ -n "${API_HOST}" ]] || { echo "ERROR: LB not yet provisioned. Wait ~60 s or set API_BASE_URL=http://..."; exit 1; }
    API_BASE_URL="http://${API_HOST}"
  else
    # Auto-start port-forward in background
    echo "[info] Starting port-forward on localhost:8080"
    kubectl -n demo-app port-forward svc/api 8080:80 >/dev/null 2>&1 &
    PF_PID=$!
    trap "kill ${PF_PID} 2>/dev/null || true" EXIT
    sleep 2
    API_BASE_URL="http://localhost:8080"
  fi
fi

banner "Smoke test: sending ${COUNT} events to ${API_BASE_URL}/events"

# Health check
HTTP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" "${API_BASE_URL}/healthz" || echo 000)"
[[ "${HTTP_STATUS}" == "200" ]] || fail "Health check failed — status ${HTTP_STATUS}"
pass "API health check OK"

# Send events
SENT=0
for i in $(seq 1 "${COUNT}"); do
  EVENT_ID="smoke-$(date +%s%N)-${i}"
  RESP="$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/events" \
    -H "Content-Type: application/json" \
    -d "{\"event_id\":\"${EVENT_ID}\",\"type\":\"smoke.test\",\"payload\":{\"n\":${i}}}")"
  STATUS="$(echo "${RESP}" | tail -1)"
  if [[ "${STATUS}" == "200" ]]; then
    SENT=$((SENT + 1))
  else
    echo "  [WARN] event ${i} returned HTTP ${STATUS}"
  fi
done

pass "${SENT}/${COUNT} events accepted by API"
[[ "${SENT}" -eq "${COUNT}" ]] || fail "Not all events accepted"

# Wait for worker to drain
banner "Waiting ${DRAIN_WAIT}s for worker to drain queue..."
sleep "${DRAIN_WAIT}"

# Count rows in Postgres
banner "Querying Postgres for row count"
DB_POD="$(kubectl -n demo-app get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')"

ROW_COUNT="$(kubectl -n demo-app exec "${DB_POD}" -- \
  psql -U app -d app -tAc \
  "SELECT COUNT(*) FROM events WHERE type='smoke.test';" 2>/dev/null | tr -d '[:space:]')"

echo "  Events sent:  ${SENT}"
echo "  DB row count: ${ROW_COUNT}"

if [[ "${ROW_COUNT}" -eq "${SENT}" ]]; then
  pass "Row count matches — no duplicates, no lost events"
elif [[ "${ROW_COUNT}" -gt "${SENT}" ]]; then
  fail "Duplicate rows detected: ${ROW_COUNT} rows for ${SENT} events"
else
  fail "Missing rows: ${ROW_COUNT} rows for ${SENT} events (worker may still be processing — try increasing DRAIN_WAIT)"
fi

# Check dedup counter (should be 0 in normal idempotent mode with unique events)
banner "Checking worker metrics"
WORKER_POD="$(kubectl -n demo-app get pod -l app=worker -o jsonpath='{.items[0].metadata.name}')"
DEDUPED="$(kubectl -n demo-app exec "${WORKER_POD}" -- \
  curl -s http://localhost:8000/metrics 2>/dev/null \
  | grep '^worker_events_deduped_total' | awk '{sum += $2} END {print int(sum)}')"
echo "  worker_events_deduped_total: ${DEDUPED:-0}"

banner "Smoke test PASSED — stack is healthy."
echo "Next: ./scripts/demo-03-scale-api-hpa.sh"
