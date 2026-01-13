#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${TF_DIR:-$ROOT_DIR/infra/environments/dev}"

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
require kubectl
require terraform

AWS_REGION="${AWS_REGION:-eu-west-3}"
NAMESPACE="${NAMESPACE:-default}"
SA_NAME="${SA_NAME:-sqs-worker}"
DEPLOY_NAME="${DEPLOY_NAME:-sqs-worker}"
QUEUE_LENGTH="${QUEUE_LENGTH:-5}"
MAX_REPLICAS="${MAX_REPLICAS:-5}"
POLLING_INTERVAL="${POLLING_INTERVAL:-10}"
COOLDOWN_PERIOD="${COOLDOWN_PERIOD:-60}"

tf_out() {
  (cd "$TF_DIR" && terraform output -raw "$1")
}

echo "[demo] reading terraform outputs from: $TF_DIR"
QUEUE_URL="$(tf_out keda_demo_queue_url)"
ROLE_ARN="$(tf_out sqs_worker_role_arn)"

if [[ -z "$QUEUE_URL" || -z "$ROLE_ARN" ]]; then
  echo "ERROR: missing terraform outputs. Need keda_demo_queue_url and sqs_worker_role_arn." >&2
  exit 1
fi

echo "[demo] queue_url=$QUEUE_URL"
echo "[demo] role_arn=$ROLE_ARN"

echo "[demo] ensuring keda is installed..."
"$ROOT_DIR/scripts/install-keda.sh" >/dev/null

echo "[demo] applying demo resources in namespace=$NAMESPACE"

kubectl apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
    eks.amazonaws.com/sts-regional-endpoints: "true"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 0
  selector:
    matchLabels:
      app: ${DEPLOY_NAME}
  template:
    metadata:
      labels:
        app: ${DEPLOY_NAME}
    spec:
      serviceAccountName: ${SA_NAME}
      containers:
        - name: worker
          image: amazon/aws-cli:2
          imagePullPolicy: IfNotPresent
          env:
            - name: AWS_REGION
              value: ${AWS_REGION}
            - name: QUEUE_URL
              value: ${QUEUE_URL}
          command: ["/bin/sh","-lc"]
          args:
            - |
              echo "Starting SQS worker (receive+delete)...";
              while true; do
                RH="\$(aws sqs receive-message \
                  --region "\$AWS_REGION" \
                  --queue-url "\$QUEUE_URL" \
                  --max-number-of-messages 1 \
                  --wait-time-seconds 20 \
                  --query 'Messages[0].ReceiptHandle' \
                  --output text || true)"
                if [ "\$RH" != "None" ] && [ -n "\$RH" ]; then
                  aws sqs delete-message --region "\$AWS_REGION" --queue-url "\$QUEUE_URL" --receipt-handle "\$RH" >/dev/null
                  echo "Deleted one message"
                fi
              done
---
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: aws-sqs-auth
  namespace: ${NAMESPACE}
spec:
  podIdentity:
    provider: aws
    identityOwner: workload
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    name: ${DEPLOY_NAME}
  pollingInterval: ${POLLING_INTERVAL}
  cooldownPeriod: ${COOLDOWN_PERIOD}
  minReplicaCount: 0
  maxReplicaCount: ${MAX_REPLICAS}
  triggers:
    - type: aws-sqs-queue
      metadata:
        queueURL: "${QUEUE_URL}"
        queueLength: "${QUEUE_LENGTH}"
        awsRegion: "${AWS_REGION}"
      authenticationRef:
        name: aws-sqs-auth
YAML

echo
echo "[demo] status:"
kubectl -n "$NAMESPACE" get sa "$SA_NAME" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'; echo
kubectl -n "$NAMESPACE" get deploy "$DEPLOY_NAME"
kubectl -n "$NAMESPACE" get scaledobject "$DEPLOY_NAME" -o wide || true
kubectl -n "$NAMESPACE" get hpa || true

echo
echo "[demo] next:"
echo "  - Pump messages:   ./scripts/pump-sqs-demo.sh 30"
echo "  - Watch scaling:   kubectl -n $NAMESPACE get deploy $DEPLOY_NAME -w"
echo "  - KEDA logs:       kubectl -n keda logs deploy/keda-operator --tail=200 -f"
