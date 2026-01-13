#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
DEPLOY_NAME="${DEPLOY_NAME:-sqs-worker}"
SA_NAME="${SA_NAME:-sqs-worker}"

echo "[cleanup] removing demo resources..."
kubectl -n "$NAMESPACE" delete scaledobject "$DEPLOY_NAME" --ignore-not-found
kubectl -n "$NAMESPACE" delete triggerauthentication aws-sqs-auth --ignore-not-found
kubectl -n "$NAMESPACE" delete deploy "$DEPLOY_NAME" --ignore-not-found
kubectl -n "$NAMESPACE" delete sa "$SA_NAME" --ignore-not-found

echo "[cleanup] done."
