#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"
echo "[DEPRECATED] Use: ./bin/rsedp destroy infra --env dev"
exec "${ROOT_DIR}/scripts/infra/destroy-infra.sh" "$@"
