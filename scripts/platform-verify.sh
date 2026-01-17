#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "[DEPRECATED] Use: ./bin/rsedp verify platform --env dev --cluster <name>"
exec "${ROOT_DIR}/scripts/platform/verify-platform.sh" "$@"
