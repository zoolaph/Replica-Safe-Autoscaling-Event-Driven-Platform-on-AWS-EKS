#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'H'
Usage:
  ./bin/rsedp all

Runs the full dev setup (no demos):
  aws -> bootstrap -> env -> metrics -> alb -> autoscaler -> sqs -> check
H
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

run() {
  local cmd="$1"
  echo
  echo "=============================="
  echo "==> rsedp ${cmd}"
  echo "=============================="
  "${ROOT_DIR}/bin/rsedp" "${cmd}"
}

#run aws
run env
run metrics
run alb
run autoscaler
run sqs
run check

echo
echo "==> all done."
