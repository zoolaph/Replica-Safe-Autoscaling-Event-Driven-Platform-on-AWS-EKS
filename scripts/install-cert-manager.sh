#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-cert-manager}"
RELEASE="${RELEASE:-cert-manager}"
CHART="${CHART:-jetstack/cert-manager}"
CHART_VERSION="${CHART_VERSION:-v1.15.3}"   # pinned
VALUES_FILE="${VALUES_FILE:-platform/addons/cert-manager/values.yaml}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'"; exit 1; }; }
need kubectl
need helm

kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install "${RELEASE}" "${CHART}" \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  -f "${VALUES_FILE}" \
  --wait \
  --timeout 10m

kubectl -n "${NAMESPACE}" get pods -o wide
