#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

TF_DIR="infra/environments/dev"
TMPL="manifests/sqs.yaml.tmpl"

usage() {
  cat <<H
Usage:
  ./bin/rsedp sqs

What it does:
  - installs KEDA (helm) into namespace 'keda'
  - applies SQS worker + ScaledObject (renders ${TMPL})
  - reads Terraform outputs from ${TF_DIR}:
      - keda_demo_queue_url
      - sqs_worker_role_arn

Next:
  ./bin/rsedp pump-sqs 30
  kubectl -n default get deploy sqs-worker -w
H
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need aws
need terraform
need kubectl
need helm

[[ -f "$TMPL" ]] || { echo "ERROR: missing $TMPL"; exit 1; }

# Must be authenticated
if ! aws sts get-caller-identity --profile "${AWS_PROFILE}" >/dev/null 2>&1; then
  echo "ERROR: Not authenticated. Run: ./bin/rsedp aws"
  exit 1
fi

QUEUE_URL="$(terraform -chdir="$TF_DIR" output -raw keda_demo_queue_url 2>/dev/null || true)"
ROLE_ARN="$(terraform -chdir="$TF_DIR" output -raw sqs_worker_role_arn 2>/dev/null || true)"

[[ -n "$QUEUE_URL" ]] || { echo "ERROR: terraform output keda_demo_queue_url missing in ${TF_DIR}"; exit 1; }
[[ -n "$ROLE_ARN" ]] || { echo "ERROR: terraform output sqs_worker_role_arn missing in ${TF_DIR}"; exit 1; }

echo "==> Installing KEDA"
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl get ns keda >/dev/null 2>&1 || kubectl create ns keda >/dev/null

helm upgrade --install keda kedacore/keda -n keda --wait

echo "==> Applying SQS demo worker + ScaledObject"
export AWS_REGION QUEUE_URL ROLE_ARN
envsubst < "$TMPL" | kubectl apply -f -

echo
echo "==> Status"
kubectl -n keda get pods
kubectl -n default get sa sqs-worker -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'; echo
kubectl -n default get deploy sqs-worker
kubectl -n default get scaledobject sqs-worker -o wide || true

echo
echo "Next:"
echo "  ./bin/rsedp pump-sqs 30"
echo "  kubectl -n default get deploy sqs-worker -w"
echo "  kubectl -n keda logs deploy/keda-operator -f --tail=200"
