#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'H'
Usage:
  ./bin/rsedp demo-autoscaling

What it does:
  - applies manifests/demo-autoscaling.yaml
  - scales cpu-hog to 5 replicas to force scheduling pressure
  - shows pending pods + nodes
H
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }

echo "==> Apply autoscaling demo deployment"
kubectl apply -f manifests/demo-autoscaling.yaml

echo "==> Scale cpu-hog to 5 replicas (should trigger scale-up if capacity is insufficient)"
kubectl scale deploy/cpu-hog --replicas=5

echo "==> Show pods (watch for Pending)"
kubectl get pods -l app=cpu-hog -o wide || true

echo "==> Current nodes"
kubectl get nodes -o wide || true

echo "Tip: watch autoscaler logs:"
echo "  kubectl -n kube-system logs deploy/cluster-autoscaler -f --tail=200"
