#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
NAMESPACE="${NAMESPACE:-logging}"
RELEASE="${RELEASE:-logging}"
CHART="${CHART:-aws/aws-for-fluent-bit}"
CHART_VERSION="${CHART_VERSION:-0.1.35}"   # pinned
VALUES_FILE="${VALUES_FILE:-platform/addons/logging-cloudwatch/values.yaml}"

CLUSTER_NAME="${CLUSTER_NAME:-}"
CLOUDWATCH_ROLE_ARN="${CLOUDWATCH_ROLE_ARN:-}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'"; exit 1; }; }
info() { echo "[INFO] $*"; }
fail() { echo "[FAIL] $*"; exit 1; }

need kubectl
need helm

[[ -f "${VALUES_FILE}" ]] || fail "Values file not found: ${VALUES_FILE}"
[[ -n "${CLUSTER_NAME}" ]] || fail "CLUSTER_NAME is required (ex: CLUSTER_NAME=replicasafe-dev ./scripts/install-logging.sh)"

info "Installing logging -> CloudWatch (aws-for-fluent-bit)"
info "  Namespace: ${NAMESPACE}"
info "  Release:   ${RELEASE}"
info "  Chart:     ${CHART}"
info "  Version:   ${CHART_VERSION}"
info "  Region:    ${AWS_REGION}"
info "  Cluster:   ${CLUSTER_NAME}"
info "  IRSA role: ${CLOUDWATCH_ROLE_ARN:-<none>}"

kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

helm repo add aws https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

args=(
  upgrade --install "${RELEASE}" "${CHART}"
  --namespace "${NAMESPACE}"
  --version "${CHART_VERSION}"
  -f "${VALUES_FILE}"
  --set "cloudWatch.region=${AWS_REGION}"
  --set "cloudWatch.logGroupTemplate=/aws/eks/${CLUSTER_NAME}/\$(kubernetes['namespace_name'])"
  --wait
  --timeout 10m
)

if [[ -n "${CLOUDWATCH_ROLE_ARN}" ]]; then
  args+=( --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${CLOUDWATCH_ROLE_ARN}" )
else
  info "CLOUDWATCH_ROLE_ARN not set → will rely on node IAM role (IRSA recommended)."
fi

helm "${args[@]}"

info "Pods:"
kubectl -n "${NAMESPACE}" get pods -o wide

info "ServiceAccount annotation:"
kubectl -n "${NAMESPACE}" get sa aws-for-fluent-bit -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'; echo

echo
info "Expected CloudWatch log group pattern:"
echo "  /aws/eks/${CLUSTER_NAME}/<namespace>"
