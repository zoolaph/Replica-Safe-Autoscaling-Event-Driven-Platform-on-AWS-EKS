#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-kyverno}"
RELEASE="${RELEASE:-kyverno}"
CHART="${CHART:-kyverno/kyverno}"
CHART_VERSION="${CHART_VERSION:-3.2.6}"   # pinned
VALUES_FILE="${VALUES_FILE:-platform/addons/kyverno/values.yaml}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'"; exit 1; }; }
need kubectl
need helm

kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install "${RELEASE}" "${CHART}" \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  -f "${VALUES_FILE}" \
  --wait \
  --timeout 10m

kubectl -n "${NAMESPACE}" get pods -o wide
