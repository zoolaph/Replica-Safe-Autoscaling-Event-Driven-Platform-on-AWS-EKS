#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"
echo "[DEPRECATED] Use: ./bin/rsedp deploy platform --env dev"
exec "${ROOT_DIR}/scripts/platform/deploy-platform.sh" "$@"
