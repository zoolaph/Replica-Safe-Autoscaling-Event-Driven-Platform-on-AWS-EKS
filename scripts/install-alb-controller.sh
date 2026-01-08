#!/usr/bin/env bash
set -euo pipefail

export AWS_PAGER="${AWS_PAGER:-}"

AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_REGION:-eu-west-3}"
TF_DIR="${TF_DIR:-infra/environments/dev}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need aws
need terraform
need kubectl
need helm

# Pull truth from Terraform outputs (prevents wrong cluster / wrong VPC)
CLUSTER_NAME="${CLUSTER_NAME:-$(terraform -chdir="$TF_DIR" output -raw cluster_name)}"
VPC_ID="${VPC_ID:-$(terraform -chdir="$TF_DIR" output -raw vpc_id)}"
ROLE_ARN="${ROLE_ARN:-$(terraform -chdir="$TF_DIR" output -raw aws_load_balancer_controller_role_arn)}"

echo "==> Installing AWS Load Balancer Controller"
echo "    AWS_PROFILE=$AWS_PROFILE"
echo "    AWS_REGION=$AWS_REGION"
echo "    TF_DIR=$TF_DIR"
echo "    CLUSTER_NAME=$CLUSTER_NAME"
echo "    VPC_ID=$VPC_ID"
echo "    ROLE_ARN=$ROLE_ARN"

echo "==> Ensuring AWS auth..."
aws sso login --profile "$AWS_PROFILE" >/dev/null

echo "==> Updating kubeconfig..."
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME" \
  --profile "$AWS_PROFILE" >/dev/null

echo "==> Helm repo..."
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

VALUES_FILE="platform/addons/aws-load-balancer-controller/values.yaml"

echo "==> Installing/upgrading chart..."
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --create-namespace \
  -f "$VALUES_FILE" \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN"

echo "==> Waiting for rollout..."
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=180s

echo "==> OK: Controller installed"
kubectl -n kube-system get pods | grep aws-load-balancer-controller