#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${ROOT_DIR}/manifests/demo-velero.yaml"

DEMO_NS="${DEMO_NS:-demo-velero}"
VELERO_NS="${VELERO_NS:-velero}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}" # 10 min default

log() { printf '[demo-velero] %s\n' "$*"; }
die() { printf '[demo-velero][ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'H'
Usage:
  ./bin/rsedp demo-velero

What it does:
  - verifies Velero is installed (namespace "velero" + deploy/velero exists)
  - applies manifests/demo-velero.yaml (Deployment + Service in namespace demo-velero)
  - verifies service responds ("ok") using an in-cluster curl pod
  - creates a Velero Backup CR for namespace demo-velero
  - waits for Backup phase=Completed
  - deletes namespace demo-velero (simulated disaster)
  - creates a Velero Restore CR from that backup
  - waits for Restore phase=Completed
  - verifies the service responds again ("ok")
  - prints commands you can paste into the PR as evidence

Prereqs:
  - Velero installed and configured with S3 backend + IRSA (run: ./bin/rsedp velero)
  - kubectl context points to the target EKS cluster

Notes:
  - This drill uses Velero CRDs (no velero CLI required).
H
}


case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac


need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

now_epoch() { date +%s; }

wait_for_jsonpath() {
  # wait_for_jsonpath <desc> <cmd...> <expected_regex> <timeout_seconds>
  local desc="$1"; shift
  local expected="$1"; shift
  local timeout="$1"; shift
  local start; start="$(now_epoch)"

  while true; do
    local out=""
    set +e
    out="$("$@" 2>/dev/null)"
    local rc=$?
    set -e
    if [[ $rc -eq 0 && "$out" =~ $expected ]]; then
      log "OK: ${desc}: ${out}"
      return 0
    fi
    if (( "$(now_epoch)" - start > timeout )); then
      die "Timeout waiting for: ${desc}. Last output: '${out}'"
    fi
    sleep 3
  done
}

wait_backup_phase() {
  local name="$1"
  local timeout="$2"
  local start; start="$(now_epoch)"

  while true; do
    local phase=""
    set +e
    phase="$(kubectl -n "${VELERO_NS}" get backup "${name}" -o jsonpath='{.status.phase}' 2>/dev/null)"
    set -e

    if [[ "${phase}" == "Completed" ]]; then
      log "Backup ${name} phase=Completed"
      return 0
    fi
    if [[ "${phase}" == "Failed" || "${phase}" == "PartiallyFailed" ]]; then
      kubectl -n "${VELERO_NS}" get backup "${name}" -o yaml || true
      die "Backup ${name} phase=${phase}"
    fi

    if (( "$(now_epoch)" - start > timeout )); then
      kubectl -n "${VELERO_NS}" get backup "${name}" -o yaml || true
      die "Timeout waiting for Backup ${name} to complete (last phase='${phase}')"
    fi
    sleep 4
  done
}

wait_restore_phase() {
  local name="$1"
  local timeout="$2"
  local start; start="$(now_epoch)"

  while true; do
    local phase=""
    set +e
    phase="$(kubectl -n "${VELERO_NS}" get restore "${name}" -o jsonpath='{.status.phase}' 2>/dev/null)"
    set -e

    if [[ "${phase}" == "Completed" ]]; then
      log "Restore ${name} phase=Completed"
      return 0
    fi
    if [[ "${phase}" == "Failed" || "${phase}" == "PartiallyFailed" ]]; then
      kubectl -n "${VELERO_NS}" get restore "${name}" -o yaml || true
      die "Restore ${name} phase=${phase}"
    fi

    if (( "$(now_epoch)" - start > timeout )); then
      kubectl -n "${VELERO_NS}" get restore "${name}" -o yaml || true
      die "Timeout waiting for Restore ${name} to complete (last phase='${phase}')"
    fi
    sleep 4
  done
}

ensure_velero_ready() {
  kubectl get ns "${VELERO_NS}" >/dev/null 2>&1 || die "Velero namespace '${VELERO_NS}' not found. Install Velero first (e.g. ./bin/rsedp velero)."
  kubectl -n "${VELERO_NS}" get deploy/velero >/dev/null 2>&1 || die "Velero deployment not found. Install Velero first."
  kubectl -n "${VELERO_NS}" rollout status deploy/velero --timeout=5m
}

deploy_demo() {
  [[ -f "${MANIFEST}" ]] || die "Missing manifest: ${MANIFEST}"
  log "Applying demo manifest: ${MANIFEST}"
  kubectl apply -f "${MANIFEST}"
  log "Waiting for demo deployment rollout"
  kubectl -n "${DEMO_NS}" rollout status deploy/demo-velero --timeout=5m
}

curl_check() {
  local expected="$1"

  log "Running in-cluster curl check (expect: '${expected}')"
  # Create a tiny curl pod to exec from (more reliable than kubectl run --rm across kubectl versions)
  kubectl -n "${DEMO_NS}" delete pod demo-velero-curl --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${DEMO_NS}" run demo-velero-curl --image=curlimages/curl:8.6.0 --restart=Never --command -- sleep 3600 >/dev/null

  kubectl -n "${DEMO_NS}" wait --for=condition=Ready pod/demo-velero-curl --timeout=2m >/dev/null

  local out=""
  set +e
  out="$(kubectl -n "${DEMO_NS}" exec demo-velero-curl -- curl -sS --max-time 5 "http://demo-velero:5678/" 2>/dev/null)"
  local rc=$?
  set -e

  kubectl -n "${DEMO_NS}" delete pod demo-velero-curl --ignore-not-found >/dev/null 2>&1 || true

  if [[ $rc -ne 0 ]]; then
    die "Curl request failed (rc=${rc})."
  fi
  if [[ "${out}" != "${expected}" ]]; then
    die "Unexpected response. got='${out}' expected='${expected}'"
  fi
  log "Curl OK: '${out}'"
}

create_backup() {
  local backup_name="$1"

  log "Creating Velero Backup '${backup_name}' (namespace: ${DEMO_NS})"
  kubectl -n "${VELERO_NS}" apply -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${backup_name}
  namespace: ${VELERO_NS}
spec:
  includedNamespaces:
    - ${DEMO_NS}
  ttl: 720h0m0s
EOF
  wait_backup_phase "${backup_name}" "${TIMEOUT_SECONDS}"
}

delete_demo_namespace() {
  log "Deleting namespace '${DEMO_NS}'"
  kubectl delete ns "${DEMO_NS}" --wait=false >/dev/null

  log "Waiting for namespace '${DEMO_NS}' to disappear"
  local start; start="$(now_epoch)"
  while kubectl get ns "${DEMO_NS}" >/dev/null 2>&1; do
    if (( "$(now_epoch)" - start > TIMEOUT_SECONDS )); then
      die "Timeout waiting for namespace '${DEMO_NS}' deletion"
    fi
    sleep 3
  done
  log "Namespace '${DEMO_NS}' deleted"
}

create_restore() {
  local backup_name="$1"
  local restore_name="$2"

  log "Creating Velero Restore '${restore_name}' from backup '${backup_name}'"
  kubectl -n "${VELERO_NS}" apply -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${restore_name}
  namespace: ${VELERO_NS}
spec:
  backupName: ${backup_name}
  includedNamespaces:
    - ${DEMO_NS}
  restorePVs: false
EOF
  wait_restore_phase "${restore_name}" "${TIMEOUT_SECONDS}"

  log "Waiting for restored demo deployment rollout"
  kubectl -n "${DEMO_NS}" rollout status deploy/demo-velero --timeout=5m
}

main() {
  need kubectl

  ensure_velero_ready

  local ts; ts="$(date +%Y%m%d%H%M%S)"
  local backup_name="demo-velero-${ts}"
  local restore_name="demo-velero-restore-${ts}"

  log "=== Step 1: Deploy demo app"
  deploy_demo
  curl_check "ok"

  log "=== Step 2: Create backup"
  create_backup "${backup_name}"

  log "=== Step 3: Delete namespace (simulate disaster)"
  delete_demo_namespace

  log "=== Step 4: Restore"
  create_restore "${backup_name}" "${restore_name}"

  log "=== Step 5: Verify service responds again"
  curl_check "ok"

  log "DONE ✅"
  log "Evidence:"
  log "  kubectl -n ${VELERO_NS} get backup ${backup_name} -o wide"
  log "  kubectl -n ${VELERO_NS} get restore ${restore_name} -o wide"
}

main "$@"
