#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# -----------------------------
# Config (defaults)
# -----------------------------
AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-3}}"
export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

APPROVED="false"

# -----------------------------
# Utils
# -----------------------------
log()  { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<H
Usage:
  ./bin/rsedp down [--yes]

What it does (in order):
  1. Deletes Kubernetes demo resources (demo-app, demo-ingress, demo-storage)
     so the AWS Load Balancer Controller can deprovision ALBs before VPC teardown
  2. Runs terraform destroy on the dev environment
  3. Prints a summary of what was destroyed and what was intentionally preserved

What it does NOT destroy:
  - Terraform backend (S3 state bucket + DynamoDB lock table)
  - ECR repositories

Options:
  --yes    Skip interactive confirmation prompt
  -h, --help  Show this help

Env:
  AWS_PROFILE, AWS_REGION / AWS_DEFAULT_REGION
H
}

# -----------------------------
# Arg parsing
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --yes) APPROVED="true"; shift ;;
    *)
      die "Unknown argument: $1 (use --help)" ;;
  esac
done

# -----------------------------
# Confirmation
# -----------------------------
if [[ "${APPROVED}" != "true" ]]; then
  echo ""
  echo "  !! DESTRUCTIVE OPERATION !!"
  echo ""
  echo "  This will:"
  echo "    - Delete all Kubernetes demo resources (demo-app, demo-ingress, demo-storage)"
  echo "    - Run terraform destroy on infra/environments/dev"
  echo "    - Deprovision: EKS cluster, VPC, IRSA roles, SQS queue, S3 backup bucket"
  echo ""
  echo "  This will NOT destroy:"
  echo "    - Terraform backend (S3 state bucket + DynamoDB lock table)"
  echo ""
  read -rp "  Type 'yes' to confirm: " answer
  [[ "${answer}" == "yes" ]] || die "Aborted."
  echo ""
fi

# -----------------------------
# Teardown
# -----------------------------
log "Starting full platform teardown (AWS_PROFILE=${AWS_PROFILE} AWS_REGION=${AWS_REGION})"

log "Step 1/2 — Destroying demo resources + terraform environment"
"${ROOT_DIR}/scripts/destroy.sh" --yes

# -----------------------------
# Summary
# -----------------------------
echo ""
echo "========================================================"
echo "  Teardown complete"
echo "========================================================"
echo ""
echo "  DESTROYED:"
echo "    [k8s] demo-app namespace (ALBs, LoadBalancer services)"
echo "    [k8s] demo-ingress namespace"
echo "    [k8s] demo-storage namespace"
echo "    [k8s] cpu-hog, sqs-worker demo workloads"
echo "    [tf]  EKS cluster, node groups"
echo "    [tf]  VPC, subnets, security groups"
echo "    [tf]  IRSA IAM roles"
echo "    [tf]  SQS queue"
echo "    [tf]  S3 backup bucket"
echo ""
echo "  PRESERVED (intentional):"
echo "    [tf]  Terraform state backend — S3 bucket + DynamoDB lock table"
echo "          To destroy manually:"
echo "            cd infra/bootstrap"
echo "            terraform destroy"
echo ""
echo "========================================================"
