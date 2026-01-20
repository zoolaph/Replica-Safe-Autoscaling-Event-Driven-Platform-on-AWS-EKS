
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_NAME="${ENV_NAME:-dev}"
ENV_DIR="${ROOT_DIR}/infra/environments/${ENV_NAME}"

BUCKET="$(terraform -chdir="${ENV_DIR}" output -raw velero_bucket_name)"
REGION="${AWS_DEFAULT_REGION:-$(terraform -chdir="${ENV_DIR}" output -raw region 2>/dev/null || echo eu-west-3)}"

TMP="$(mktemp)"
export VELERO_BUCKET="${BUCKET}"
export AWS_REGION="${REGION}"

envsubst < "${ROOT_DIR}/platform/addons/velero/values.yaml.tmpl" > "${TMP}"

helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null
helm repo update >/dev/null

helm upgrade --install velero vmware-tanzu/velero \
  --namespace velero --create-namespace \
  -f "${TMP}"

kubectl -n velero rollout status deploy/velero --timeout=5m
kubectl -n velero get pods
