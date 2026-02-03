#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-external-dns}"
RELEASE="${RELEASE:-external-dns}"
CHART="${CHART:-external-dns/external-dns}"
CHART_VERSION="${CHART_VERSION:-1.14.5}"   # pinned
VALUES_FILE="${VALUES_FILE:-platform/addons/external-dns/values.yaml}"

# Required: hosted zone info
DOMAIN="${DOMAIN:-}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"

# Recommended: IRSA role ARN (Terraform addon or created manually)
EXTERNAL_DNS_ROLE_ARN="${EXTERNAL_DNS_ROLE_ARN:-}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'"; exit 1; }; }
fail() { echo "ERROR: $*"; exit 1; }

need kubectl
need helm

[[ -f "${VALUES_FILE}" ]] || fail "Values file not found: ${VALUES_FILE}"
[[ -n "${DOMAIN}" ]] || fail "DOMAIN is required (example: DOMAIN=example.com)"
[[ -n "${HOSTED_ZONE_ID}" ]] || fail "HOSTED_ZONE_ID is required (example: HOSTED_ZONE_ID=Z123...)"

kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ >/dev/null 2>&1 || true
helm repo update >/dev/null

args=(
  upgrade --install "${RELEASE}" "${CHART}"
  --namespace "${NAMESPACE}"
  --version "${CHART_VERSION}"
  -f "${VALUES_FILE}"
  --set "domainFilters[0]=${DOMAIN}"
  --set "zoneIdFilters[0]=${HOSTED_ZONE_ID}"
  --wait
  --timeout 10m
)

if [[ -n "${EXTERNAL_DNS_ROLE_ARN}" ]]; then
  args+=( --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${EXTERNAL_DNS_ROLE_ARN}" )
fi

helm "${args[@]}"

kubectl -n "${NAMESPACE}" get pods -o wide
