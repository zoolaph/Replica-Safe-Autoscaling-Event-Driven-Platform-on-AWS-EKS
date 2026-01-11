#!/usr/bin/env bash
set -euo pipefail

TF_DIR="${TF_DIR:-infra/environments/dev}"


kubectl create ns demo-autoscaling --dry-run=client -o yaml
kubectl apply -f platform/demos/demo-autoscaling.yaml
