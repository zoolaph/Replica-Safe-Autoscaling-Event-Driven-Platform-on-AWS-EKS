#!/usr/bin/env bash
set -euo pipefail

NS="demo-ingress"
ING="web"

usage() {
  cat <<'H'
Usage:
  ./bin/rsedp demo-alb

What it does:
  - applies manifests/demo-alb.yaml
  - waits for deployment ready
  - waits for ingress to get an ALB hostname
  - prints the URL and tries to curl it (best-effort)

Prereqs:
  - AWS Load Balancer Controller installed
  - IngressClass "alb" exists
  - Your subnet IDs in the manifest are valid
H
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }

echo "==> Apply ALB demo manifest"
kubectl apply -f manifests/demo-alb.yaml

echo "==> Wait for deployment rollout"
kubectl -n "${NS}" rollout status deploy/web --timeout=180s

echo "==> Waiting for ALB hostname on ingress/${ING}"
# Wait up to ~5 minutes for ALB provisioning
for i in {1..60}; do
  HOST="$(kubectl -n "${NS}" get ingress "${ING}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "${HOST}" ]]; then
    echo "ALB hostname: ${HOST}"
    echo "URL: http://${HOST}/"
    break
  fi
  sleep 5
done

if [[ -z "${HOST:-}" ]]; then
  echo "ERROR: Ingress has no hostname yet."
  echo "Debug:"
  kubectl -n "${NS}" describe ingress "${ING}" || true
  exit 1
fi

# Best-effort curl (may fail due to propagation / security groups)
if command -v curl >/dev/null 2>&1; then
  echo "==> Curling ALB (best-effort)"
  curl -sS "http://${HOST}/" || true
else
  echo "curl not found; skipping HTTP check"
fi

echo "==> Demo complete."
echo "Cleanup: kubectl delete ns ${NS}"
