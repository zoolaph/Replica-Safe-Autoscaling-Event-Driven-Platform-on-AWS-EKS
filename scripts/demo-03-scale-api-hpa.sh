#!/usr/bin/env bash
# demo-03-scale-api-hpa.sh — Prove HPA scales the API under CPU load.
#
# What it proves:
#   - HPA target: 70% of 50m CPU → fires at ~35m per pod
#   - Under 50 concurrent VUs via k6 the API scales 1 → 3-4 replicas
#   - After load stops, HPA scales back down (cooldown ~5 min)
#
# Usage:
#   ./scripts/demo-03-scale-api-hpa.sh
#
# Prerequisites:
#   - demo-01-deploy.sh completed (stack deployed)
#   - k6 installed (https://k6.io/docs/getting-started/installation/)
#   - API reachable — set API_BASE_URL or port-forward will be auto-started
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_BASE_URL="${API_BASE_URL:-}"
WATCH_INTERVAL=10   # seconds between HPA polls during test

banner() { echo; echo "==> $*"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need kubectl
need k6

# Resolve API URL (same logic as demo-02)
if [[ -z "${API_BASE_URL}" ]]; then
  API_SVC_TYPE="$(kubectl -n demo-app get svc api -o jsonpath='{.spec.type}' 2>/dev/null || echo unknown)"
  if [[ "${API_SVC_TYPE}" == "LoadBalancer" ]]; then
    API_HOST="$(kubectl -n demo-app get svc api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [[ -n "${API_HOST}" ]] || { echo "ERROR: LB not yet provisioned. Set API_BASE_URL=http://..."; exit 1; }
    API_BASE_URL="http://${API_HOST}"
  else
    echo "[info] Starting port-forward on localhost:8080"
    kubectl -n demo-app port-forward svc/api 8080:80 >/dev/null 2>&1 &
    PF_PID=$!
    trap "kill ${PF_PID} 2>/dev/null || true" EXIT
    sleep 2
    API_BASE_URL="http://localhost:8080"
  fi
fi

banner "Starting state"
echo "--- HPA before load ---"
kubectl -n demo-app get hpa api
echo
echo "--- Replicas before load ---"
kubectl -n demo-app get deploy api

# Watch HPA in background while k6 runs
banner "Starting HPA watcher (background)"
(
  while true; do
    echo "[$(date '+%H:%M:%S')] $(kubectl -n demo-app get hpa api --no-headers 2>/dev/null)"
    sleep "${WATCH_INTERVAL}"
  done
) &
WATCHER_PID=$!
trap "kill ${WATCHER_PID} ${PF_PID:-} 2>/dev/null || true" EXIT

banner "Running k6 load test (5 min — 1m ramp → 3m @ 50 VUs → 1m ramp-down)"
echo "Base URL: ${API_BASE_URL}"
echo

k6 run \
  -e BASE_URL="${API_BASE_URL}" \
  "${ROOT_DIR}/tests/load/k6-api.js"

K6_EXIT=$?
kill "${WATCHER_PID}" 2>/dev/null || true

banner "Load test complete (k6 exit=${K6_EXIT})"
echo
echo "--- HPA after load ---"
kubectl -n demo-app get hpa api
echo
echo "--- Replica count ---"
kubectl -n demo-app get deploy api
echo
echo "--- HPA events ---"
kubectl -n demo-app describe hpa api | grep -A 40 "Events:"

banner "Expected evidence"
cat <<'EOF'
  - HPA TARGETS column showed > 70% CPU during sustained phase
  - REPLICAS column increased from 1 to 3-4
  - k6 p95 < 2000 ms (threshold in tests/load/k6-api.js)
  - k6 error rate < 5%
  - After test, HPA will scale back to minReplicas=1 in ~5 min

See docs/demo/hpa-api.md for a full walkthrough with annotated screenshots.
EOF

banner "Demo 03 complete."
echo "Next: ./scripts/demo-04-scale-worker-keda.sh"
