#!/usr/bin/env bash
set -euo pipefail

echo "==> Verifying repo conventions..."
test -d platform/addons || (echo "ERROR: missing platform/addons" >&2 && exit 1)
test -d docs/demos || (echo "ERROR: missing docs/demos" >&2 && exit 1)

echo "==> Verifying cluster connectivity..."
kubectl version --client >/dev/null
kubectl get nodes
kubectl get pods -A | head -n 30

echo "==> OK"
