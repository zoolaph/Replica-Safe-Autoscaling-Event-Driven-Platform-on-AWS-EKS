#!/usr/bin/env bash
set -euo pipefail

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }

require kubectl
require helm

KEDA_NS="${KEDA_NS:-keda}"
KEDA_RELEASE="${KEDA_RELEASE:-keda}"
KEDA_CHART="${KEDA_CHART:-kedacore/keda}"

echo "[keda] adding repo..."
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "[keda] installing/upgrading..."
kubectl get ns "$KEDA_NS" >/dev/null 2>&1 || kubectl create ns "$KEDA_NS" >/dev/null

helm upgrade --install "$KEDA_RELEASE" "$KEDA_CHART" \
  -n "$KEDA_NS" \
  --wait

echo "[keda] ok:"
kubectl -n "$KEDA_NS" get pods
