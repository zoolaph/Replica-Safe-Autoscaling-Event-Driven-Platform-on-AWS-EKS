#!/usr/bin/env bash
# demo-01-deploy.sh — Deploy the demo-app stack into the demo-app namespace.
#
# What it does:
#   1. Renders secrets.yaml from Terraform outputs (SQS queue URL, worker IRSA role)
#   2. Applies all manifests in manifests/demo-app/ (namespace, serviceaccounts,
#      postgres, secrets, api, worker, hpa, keda-scaledobject)
#   3. Waits for all deployments to be ready
#   4. Prints pod status and the API endpoint URL
#
# Usage:
#   ./scripts/demo-01-deploy.sh
#
# Prerequisites:
#   - kubectl context pointing at replicasafe-dev cluster
#   - AWS credentials available (./bin/rsedp aws)
#   - Terraform applied (./bin/rsedp env) — needed for SQS URL + IAM role ARN
#   - ECR images pushed: YOUR_ECR/api:dev, YOUR_ECR/worker:dev
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS_DIR="${ROOT_DIR}/manifests/demo-app"
TF_DIR="${ROOT_DIR}/infra/environments/dev"
AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

banner() { echo; echo "==> $*"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need kubectl
need aws
need terraform

# Auth check
if ! aws sts get-caller-identity --profile "${AWS_PROFILE}" >/dev/null 2>&1; then
  echo "ERROR: Not authenticated to AWS. Run: ./bin/rsedp aws"
  exit 1
fi

# Read Terraform outputs
banner "Reading Terraform outputs from ${TF_DIR}"
QUEUE_URL="$(terraform -chdir="${TF_DIR}" output -raw sqs_queue_url 2>/dev/null || true)"
WORKER_ROLE_ARN="$(terraform -chdir="${TF_DIR}" output -raw worker_irsa_role_arn 2>/dev/null || true)"

[[ -n "${QUEUE_URL}" ]]       || { echo "ERROR: terraform output sqs_queue_url missing"; exit 1; }
[[ -n "${WORKER_ROLE_ARN}" ]] || { echo "ERROR: terraform output worker_irsa_role_arn missing"; exit 1; }

echo "  QUEUE_URL        = ${QUEUE_URL}"
echo "  WORKER_ROLE_ARN  = ${WORKER_ROLE_ARN}"

# Apply namespace first (idempotent)
banner "Applying namespace"
kubectl apply -f "${MANIFESTS_DIR}/namespace.yaml"

# Apply service accounts (IRSA annotation must be on the SA)
banner "Applying service accounts"
kubectl apply -f "${MANIFESTS_DIR}/serviceaccounts.yaml"

# Annotate the worker SA with the IRSA role (in case the YAML has a placeholder)
kubectl -n demo-app annotate serviceaccount worker \
  "eks.amazonaws.com/role-arn=${WORKER_ROLE_ARN}" \
  --overwrite

# Apply secrets (base64-encoded values come from Terraform outputs via a template,
# or you can set them manually — see manifests/demo-app/secrets.yaml)
banner "Applying secrets"
# Patch SQS_QUEUE_URL into the secret
SQS_B64="$(echo -n "${QUEUE_URL}" | base64)"
kubectl apply -f "${MANIFESTS_DIR}/secrets.yaml"
kubectl -n demo-app patch secret demo-app-secrets \
  --type=merge \
  -p "{\"data\":{\"sqs_queue_url\":\"${SQS_B64}\"}}"

# Apply infra: postgres
banner "Applying Postgres"
kubectl apply -f "${MANIFESTS_DIR}/postgres.yaml"
kubectl -n demo-app rollout status deployment/postgres --timeout=120s

# Apply app: api + worker
banner "Applying API and Worker"
kubectl apply -f "${MANIFESTS_DIR}/api.yaml"
kubectl apply -f "${MANIFESTS_DIR}/worker.yaml"

# Apply autoscalers
banner "Applying HPA (API) and KEDA ScaledObject (Worker)"
kubectl apply -f "${MANIFESTS_DIR}/hpa.yaml"
kubectl apply -f "${MANIFESTS_DIR}/keda-scaledobject.yaml"

# Wait for rollouts
banner "Waiting for API rollout"
kubectl -n demo-app rollout status deployment/api --timeout=120s

banner "Waiting for Worker rollout"
kubectl -n demo-app rollout status deployment/worker --timeout=120s

# Summary
banner "Stack status"
kubectl -n demo-app get pods -o wide
echo
kubectl -n demo-app get hpa
echo
kubectl -n demo-app get scaledobject

# API endpoint
API_SVC_TYPE="$(kubectl -n demo-app get svc api -o jsonpath='{.spec.type}' 2>/dev/null || echo unknown)"
if [[ "${API_SVC_TYPE}" == "LoadBalancer" ]]; then
  API_HOST="$(kubectl -n demo-app get svc api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "${API_HOST}" ]] && echo "API endpoint: http://${API_HOST}/events" || echo "API LB provisioning (re-check in ~60 s)"
else
  echo "API service type: ${API_SVC_TYPE}"
  echo "For local access: kubectl -n demo-app port-forward svc/api 8080:80"
  echo "Then: curl http://localhost:8080/healthz"
fi

banner "Demo 01 complete — stack deployed."
echo "Next: ./scripts/demo-02-smoke.sh"
