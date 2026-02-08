#!/usr/bin/env bash
set -euo pipefail

# Safe defaults:
# - enforce baseline (blocks obvious unsafe)
# - warn/audit restricted (gives signal without breaking everything)
ENFORCE="${ENFORCE:-baseline}"
WARN="${WARN:-restricted}"
AUDIT="${AUDIT:-restricted}"

# Namespaces to label (edit as you grow)
TARGET_NAMESPACES_DEFAULT=("default")

# Any namespace matching these prefixes will also be labeled
PREFIX_MATCH_DEFAULT=("demo-")

# Namespaces to NEVER label (system / addons that may need exemptions)
EXCLUDE_NAMESPACES=("kube-system" "kube-public" "kube-node-lease" "kyverno" "cert-manager" "external-dns" "logging" "observability")

info() { echo "[INFO] $*"; }

should_exclude() {
  local ns="$1"
  for x in "${EXCLUDE_NAMESPACES[@]}"; do
    [[ "$ns" == "$x" ]] && return 0
  done
  return 1
}

matches_prefix() {
  local ns="$1"
  for p in "${PREFIX_MATCH_DEFAULT[@]}"; do
    [[ "$ns" == "$p"* ]] && return 0
  done
  return 1
}

label_ns() {
  local ns="$1"
  info "Labeling namespace=${ns} enforce=${ENFORCE} warn=${WARN} audit=${AUDIT}"
  kubectl label ns "$ns" --overwrite \
    pod-security.kubernetes.io/enforce="${ENFORCE}" \
    pod-security.kubernetes.io/enforce-version="latest" \
    pod-security.kubernetes.io/warn="${WARN}" \
    pod-security.kubernetes.io/warn-version="latest" \
    pod-security.kubernetes.io/audit="${AUDIT}" \
    pod-security.kubernetes.io/audit-version="latest"
}

# label explicit namespaces
for ns in "${TARGET_NAMESPACES_DEFAULT[@]}"; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    if should_exclude "$ns"; then
      info "Skipping excluded namespace: $ns"
    else
      label_ns "$ns"
    fi
  else
    info "Namespace not found (skipping): $ns"
  fi
done

# label namespaces by prefix
ALL_NS="$(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
while read -r ns; do
  [[ -z "$ns" ]] && continue
  if should_exclude "$ns"; then
    continue
  fi
  if matches_prefix "$ns"; then
    label_ns "$ns"
  fi
done <<< "${ALL_NS}"

info "Done. Current PSS labels (filtered):"
kubectl get ns --show-labels | grep -E 'pod-security.kubernetes.io/(enforce|warn|audit)=' || true
