#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/lib/common.sh"

usage() {
  echo "Usage: verify-platform.sh [--env <name>] [--region <region>] [--cluster <name>]"
  print_common_flags_help
}

if ! parse_common_flags "$@"; then
  usage
  exit 0
fi

TF_DIR="${ROOT_DIR}/infra/environments/${ENV_NAME}"



if [[ -z "${CLUSTER_NAME:-}" ]]; then
  CLUSTER_NAME="$(terraform -chdir="$TF_DIR" output -raw cluster_name 2>/dev/null || true)"
fi

if [[ -z "${CLUSTER_NAME:-}" ]]; then
  CLUSTER_NAME="$(detect_cluster_from_tfvars "$TF_DIR" || true)"
fi

# Final fallback (because your default is fixed)
if [[ -z "${CLUSTER_NAME:-}" && "${ENV_NAME}" == "dev" ]]; then
  CLUSTER_NAME="replicasafe-dev"
fi

[[ -n "${CLUSTER_NAME:-}" ]] || die "CLUSTER_NAME is empty. Pass --cluster or set terraform var 'name' (terraform.tfvars) / output 'cluster_name'."



# Auto-detect cluster name (terraform output first)
if [[ -z "${CLUSTER_NAME:-}" ]]; then
  CLUSTER_NAME="$(terraform -chdir="$TF_DIR" output -raw cluster_name 2>/dev/null || true)"
fi

# If still empty, force explicit flag
[[ -n "${CLUSTER_NAME:-}" ]] || die "CLUSTER_NAME is empty. Use --cluster <name> or add terraform output 'cluster_name' in ${TF_DIR}."


echo "==> Verifying repo conventions..."
test -d platform/addons || (echo "ERROR: missing platform/addons" >&2 && exit 1)
test -d docs/demos || (echo "ERROR: missing docs/demos" >&2 && exit 1)

echo "==> Verifying cluster connectivity..."
kubectl version --client >/dev/null
kubectl get nodes
kubectl get pods -A | head -n 30

echo "==> OK"
