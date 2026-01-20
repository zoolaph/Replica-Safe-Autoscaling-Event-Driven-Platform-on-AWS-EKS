
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


usage() {
  cat <<'H'
Usage:
  ./bin/rsedp velero

What it does:
  - reads Terraform outputs (velero_bucket_name + region)
  - renders platform/addons/velero/values.yaml.tmpl into a temp values file
  - installs or upgrades Velero via Helm in namespace "velero"
  - waits for the velero deployment rollout
  - prints velero pods

Prereqs:
  - Terraform applied in infra/environments/dev (creates S3 bucket + IRSA)
  - kubectl context points to the target EKS cluster
  - helm installed

Notes:
  - This installs Velero (platform component). It does NOT run a backup/restore drill.
  - Use: ./bin/rsedp demo-velero to prove DoD (backup → delete ns → restore).
H
}


envsubst < "${ROOT_DIR}/platform/addons/velero/values.yaml.tmpl" > "${TMP}"

helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null
helm repo update >/dev/null

helm upgrade --install velero vmware-tanzu/velero \
  --namespace velero --create-namespace \
  -f "${TMP}"

kubectl -n velero rollout status deploy/velero --timeout=5m
kubectl -n velero get pods
