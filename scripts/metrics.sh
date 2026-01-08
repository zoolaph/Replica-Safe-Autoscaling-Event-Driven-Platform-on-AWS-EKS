#!/usr/bin/env bash
set -euo pipefail

export AWS_PAGER="${AWS_PAGER:-}"

AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_REGION:-eu-west-3}"
TF_DIR="${TF_DIR:-infra/environments/dev}"


helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system --create-namespace \
  -f platform/addons/metrics-server/values.yaml