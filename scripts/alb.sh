#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

TF_DIR="infra/environments/dev"
VALUES_FILE="platform/addons/aws-load-balancer-controller/values.yaml"

usage() {
  cat <<H
Usage:
  ./bin/rsedp alb

Installs AWS Load Balancer Controller (Helm) using terraform outputs from:
  ${TF_DIR}

Environment:
  AWS_PROFILE         (default: dev)
  AWS_DEFAULT_REGION  (default: eu-west-3)

Requires:
  aws, terraform, kubectl, helm
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

# Require terraform outputs to exist
CLUSTER_NAME="$(terraform -chdir="$TF_DIR" output -raw cluster_name 2>/dev/null || true)"
VPC_ID="$(terraform -chdir="$TF_DIR" output -raw vpc_id 2>/dev/null || true)"
ROLE_ARN="$(terraform -chdir="$TF_DIR" output -raw aws_load_balancer_controller_role_arn 2>/dev/null || true)"

[[ -n "$CLUSTER_NAME" ]] || { echo "ERROR: terraform output cluster_name missing in ${TF_DIR}"; exit 1; }
[[ -n "$VPC_ID" ]] || { echo "ERROR: terraform output vpc_id missing in ${TF_DIR}"; exit 1; }
[[ -n "$ROLE_ARN" ]] || { echo "ERROR: terraform output aws_load_balancer_controller_role_arn missing in ${TF_DIR}"; exit 1; }

echo "==> Installing AWS Load Balancer Controller"
echo "AWS_PROFILE=$AWS_PROFILE"
echo "AWS_REGION=$AWS_REGION"
echo "TF_DIR=$TF_DIR"
echo "CLUSTER_NAME=$CLUSTER_NAME"
echo "VPC_ID=$VPC_ID"
echo "ROLE_ARN=$ROLE_ARN"
echo

# Ensure authenticated
if ! aws sts get-caller-identity --profile "${AWS_PROFILE}" >/dev/null 2>&1; then
  echo "ERROR: Not authenticated. Run: ./bin/rsedp aws"
  exit 1
fi

echo "==> Update kubeconfig"
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME" \
  --profile "$AWS_PROFILE" >/dev/null

echo "==> Helm repo update"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

[[ -f "$VALUES_FILE" ]] || { echo "ERROR: missing values file: $VALUES_FILE"; exit 1; }

echo "==> Install/upgrade chart"
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --create-namespace \
  -f "$VALUES_FILE" \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN"

echo "==> Wait for rollout"
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=180s

echo "==> OK: Controller installed"
kubectl -n kube-system get deploy aws-load-balancer-controller
