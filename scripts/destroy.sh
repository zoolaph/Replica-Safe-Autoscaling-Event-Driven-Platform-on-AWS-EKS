#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config (defaults)
# -----------------------------
AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-3}}"
export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

ENV_DIR_DEFAULT="infra/environments/dev"
ENV_DIR="${ENV_DIR_DEFAULT}"

DO_K8S_CLEANUP="true"
DO_WAIT_K8S="true"
DRY_RUN="false"
APPROVED="false"
K8S_WAIT_TIMEOUT_SEC="180"

# -----------------------------
# Utils
# -----------------------------
log()  { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

on_err() {
  local exit_code=$?
  warn "Failed at line ${BASH_LINENO[0]} (exit=${exit_code})"
  exit "${exit_code}"
}
trap on_err ERR

need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<H
Usage:
  ./bin/rsedp destroy [--yes] [--dry-run] [--skip-k8s] [--no-wait-k8s] [--env-dir PATH]

Safety:
  - Requires explicit approval: --yes OR DESTROY_APPROVE=dev

What it destroys:
  - demo namespaces: demo-ingress, demo-storage (best-effort)
  - demo workloads: cpu-hog, sqs-worker objects (best-effort)
  - terraform environment: ${ENV_DIR_DEFAULT}
  - DOES NOT destroy terraform backend (S3 + DynamoDB)

Options:
  --yes               Approve destroy (or set DESTROY_APPROVE=dev)
  --dry-run           Run terraform plan -destroy (no changes)
  --skip-k8s          Skip kubectl cleanup
  --no-wait-k8s       Do not wait for demo namespaces/resources to terminate
  --env-dir PATH      Override terraform environment dir (default: ${ENV_DIR_DEFAULT})
  -h, --help          Show this help

Env:
  AWS_PROFILE, AWS_REGION / AWS_DEFAULT_REGION
  DESTROY_APPROVE=dev  (alternative to --yes)
H
}

# -----------------------------
# Arg parsing
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --yes) APPROVED="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --skip-k8s) DO_K8S_CLEANUP="false"; shift ;;
    --no-wait-k8s) DO_WAIT_K8S="false"; shift ;;
    --env-dir)
      [[ -n "${2:-}" ]] || die "--env-dir requires a value"
      ENV_DIR="$2"; shift 2 ;;
    *)
      die "Unknown argument: $1 (use --help)" ;;
  esac
done

if [[ "${DESTROY_APPROVE:-}" == "dev" ]]; then
  APPROVED="true"
fi

# -----------------------------
# Preconditions
# -----------------------------
need terraform

if [[ "${APPROVED}" != "true" ]]; then
  die "Refusing to destroy without explicit approval. Use --yes OR set DESTROY_APPROVE=dev"
fi

[[ -d "${ENV_DIR}" ]] || die "Environment directory '${ENV_DIR}' does not exist."

# Soft check: make sure this looks like a terraform env directory
compgen -G "${ENV_DIR}/*.tf" >/dev/null || warn "No *.tf files found in ${ENV_DIR} (is this the right env dir?)"

log "AWS_PROFILE=${AWS_PROFILE} AWS_REGION=${AWS_REGION}"
if have aws; then
  log "AWS identity:"
  aws sts get-caller-identity || warn "Could not read caller identity (aws cli configured?)"
else
  warn "aws cli not found (skipping identity print)"
fi

# -----------------------------
# Kubernetes cleanup (best-effort)
# -----------------------------
k8s_reachable() {
  kubectl version --request-timeout='5s' >/dev/null 2>&1
}

k8s_delete_demo_ns() {
  local ns="$1"

  # Delete LB-creating objects FIRST (best-effort)
  kubectl delete ingress -n "${ns}" --all --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete svc -n "${ns}" --field-selector spec.type=LoadBalancer --ignore-not-found=true >/dev/null 2>&1 || true

  # Then delete namespace
  kubectl delete ns "${ns}" --ignore-not-found=true >/dev/null 2>&1 || true
}

k8s_cleanup() {
  if ! have kubectl; then
    warn "kubectl not found (skipping k8s cleanup)"
    return 0
  fi
  if ! k8s_reachable; then
    warn "Kubernetes cluster not reachable (skipping k8s cleanup)"
    return 0
  fi

  log "Cleaning Kubernetes demo resources (best-effort)"

  # Namespaces that may contain ALB/LB demos
  k8s_delete_demo_ns "demo-ingress"
  k8s_delete_demo_ns "demo-storage"

  # Autoscaling demo (default ns)
  kubectl delete deploy cpu-hog -n default --ignore-not-found=true >/dev/null 2>&1 || true

  # SQS/KEDA demo (default ns)
  kubectl delete scaledobject.keda.sh sqs-worker -n default --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete triggerauthentication.keda.sh aws-sqs-auth -n default --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete deploy sqs-worker -n default --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete sa sqs-worker -n default --ignore-not-found=true >/dev/null 2>&1 || true

  if [[ "${DO_WAIT_K8S}" == "true" ]]; then
    log "Waiting up to ${K8S_WAIT_TIMEOUT_SEC}s for demo namespaces to terminate (best-effort)"
    local end=$((SECONDS + K8S_WAIT_TIMEOUT_SEC))
    while [[ $SECONDS -lt $end ]]; do
      # If both namespaces are gone, stop waiting
      if ! kubectl get ns demo-ingress >/dev/null 2>&1 && ! kubectl get ns demo-storage >/dev/null 2>&1; then
        break
      fi
      sleep 3
    done
  fi
}

if [[ "${DO_K8S_CLEANUP}" == "true" ]]; then
  k8s_cleanup
fi

# -----------------------------
# Terraform destroy (remote backend safe)
# -----------------------------
export TF_IN_AUTOMATION=1

log "Terraform init (${ENV_DIR})"
terraform -chdir="${ENV_DIR}" init -input=false -no-color

if [[ "${DRY_RUN}" == "true" ]]; then
  log "Dry-run: terraform plan -destroy (${ENV_DIR})"
  terraform -chdir="${ENV_DIR}" plan -destroy -input=false -no-color
  log "Dry-run complete (no changes applied)."
  exit 0
fi

log "Terraform destroy (${ENV_DIR})"
terraform -chdir="${ENV_DIR}" destroy -auto-approve -input=false -no-color

log "Destroy complete."
log "NOTE: Terraform backend (S3 state bucket + DynamoDB lock table) is intentionally NOT destroyed."
