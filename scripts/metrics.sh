#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'H'
Usage:
  ./bin/rsedp metrics

What it does:
  - kubectl apply -f manifests/metrics.yaml
  - waits for rollout in kube-system
  - runs: kubectl top nodes (best-effort)
H
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }

echo "==> Applying metrics-server manifest"
kubectl apply -f manifests/metrics.yaml

echo "==> Waiting for metrics-server rollout"
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s

echo "==> Quick check (kubectl top nodes)"
kubectl top nodes || true

echo "==> Metrics server installed."
