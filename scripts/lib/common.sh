#!/usr/bin/env bash
set -euo pipefail

log()   { printf '%s\n' "$*"; }
info()  { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
err()   { printf '[ERR ] %s\n' "$*" >&2; }

die() { err "$*"; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.."; pwd)"

# Common flags used across scripts/CLI
ENV_NAME="${ENV_NAME:-dev}"
REGION="${REGION:-eu-west-3}"
CLUSTER_NAME="${CLUSTER_NAME:-}"

print_common_flags_help() {
  cat <<'H'
Common flags:
  --env <name>        Environment name (default: dev)
  --region <region>   AWS region (default: eu-west-3)
  --cluster <name>    EKS cluster name (optional)
H
}

detect_cluster_from_tfvars() {
  local tfdir="$1"

  # If terraform.tfvars exists and contains name = "..."
  if [[ -f "$tfdir/terraform.tfvars" ]]; then
    awk -F= '
      $1 ~ /^[[:space:]]*name[[:space:]]*$/ {
        gsub(/"/,"",$2); gsub(/[[:space:]]/,"",$2);
        print $2; exit
      }' "$tfdir/terraform.tfvars" 2>/dev/null || true
  fi
}


parse_common_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env) ENV_NAME="${2:-}"; [[ -n "$ENV_NAME" ]] || die "Missing value for --env"; shift 2 ;;
      --region) REGION="${2:-}"; [[ -n "$REGION" ]] || die "Missing value for --region"; shift 2 ;;
      --cluster) CLUSTER_NAME="${2:-}"; [[ -n "$CLUSTER_NAME" ]] || die "Missing value for --cluster"; shift 2 ;;
      --help|-h) return 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  return 0
}

