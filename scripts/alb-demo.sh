#!/usr/bin/env bash
set -euo pipefail

TF_DIR="${TF_DIR:-infra/environments/dev}"

# Get current public subnets from Terraform as a comma-separated list (no jq needed)
PUBLIC_SUBNETS="$(
  terraform -chdir="$TF_DIR" output -json public_subnets \
  | python -c 'import sys,json; print(",".join(json.load(sys.stdin)))'
)"

echo "Using public subnets: $PUBLIC_SUBNETS"

kubectl apply -f platform/demos/alb-demo.yaml

kubectl -n demo-ingress annotate ingress web \
  alb.ingress.kubernetes.io/subnets="$PUBLIC_SUBNETS" \
  --overwrite

kubectl -n demo-ingress get ingress web -w
