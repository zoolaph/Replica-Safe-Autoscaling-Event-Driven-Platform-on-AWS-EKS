#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-observability}"
RELEASE="${RELEASE:-observability}"
CHART="${CHART:-prometheus-community/kube-prometheus-stack}"
CHART_VERSION="${CHART_VERSION:-}" # set this to pin, e.g. "61.7.2"
VALUES_FILE="${VALUES_FILE:-platform/addons/observability/values.yaml}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'"; exit 1; }; }
info() { echo "[INFO] $*"; }
fail() { echo "[FAIL] $*"; exit 1; }

need kubectl
need helm

[[ -f "${VALUES_FILE}" ]] || fail "Values file not found: ${VALUES_FILE}"

info "Installing observability baseline (kube-prometheus-stack)"
info "  Namespace:     ${NAMESPACE}"
info "  Release:       ${RELEASE}"
info "  Chart:         ${CHART}"
info "  Chart version: ${CHART_VERSION:-<not pinned>}"
info "  Values:        ${VALUES_FILE}"

# Namespace (idempotent)
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

# Helm repo (idempotent)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# Install/upgrade (idempotent)
args=(
  upgrade --install "${RELEASE}" "${CHART}"
  --namespace "${NAMESPACE}"
  -f "${VALUES_FILE}"
  --wait
  --timeout 10m
)

# Optional version pin
if [[ -n "${CHART_VERSION}" ]]; then
  args+=( --version "${CHART_VERSION}" )
else
  info "CHART_VERSION not set → installing latest chart (set CHART_VERSION to pin)."
fi

helm "${args[@]}"

info "Installed. Pods:"
kubectl -n "${NAMESPACE}" get pods -o wide

echo
info "Services:"
kubectl -n "${NAMESPACE}" get svc

echo
info "Port-forward commands:"
echo "  Grafana:    kubectl -n ${NAMESPACE} port-forward svc/${RELEASE}-grafana 3000:80"
echo "  Prometheus: kubectl -n ${NAMESPACE} port-forward svc/${RELEASE}-kube-prometheus-stack-prometheus 9090:9090"

echo
info "Grafana login (dev baseline):"
echo "  URL:  http://localhost:3000"
echo "  user: admin"
echo "  pass: admin"
