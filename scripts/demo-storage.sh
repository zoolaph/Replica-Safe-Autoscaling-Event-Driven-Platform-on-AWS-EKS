#!/usr/bin/env bash
set -euo pipefail

NS="demo-storage"

usage() {
  cat <<'H'
Usage:
  ./bin/rsedp demo-storage

What it does:
  - creates namespace demo-storage
  - applies manifests/demo-storage.yaml (PVC + writer pod)
  - shows PVC + pod
  - tails the file from writer
  - deletes writer and starts reader (same PVC) to prove persistence
  - prints reader logs
H
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }

echo "==> Ensure namespace: ${NS}"
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

echo "==> Apply demo manifest (PVC + writer)"
kubectl apply -f manifests/demo-storage.yaml

echo "==> Wait for writer pod ready"
kubectl -n "${NS}" wait --for=condition=Ready pod/writer --timeout=120s || {
  echo "Writer pod not ready. Current status:"
  kubectl -n "${NS}" get pod writer -o wide || true
  exit 1
}

echo "==> Show PVC + Pod"
kubectl -n "${NS}" get pvc,pod

echo "==> Tail proof from writer"
kubectl -n "${NS}" exec writer -- tail -n 5 /data/out.txt || true

echo "==> Delete writer pod"
kubectl -n "${NS}" delete pod writer --wait=true

echo "==> Start reader pod (same PVC) to prove persistence"
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: reader
  namespace: demo-storage
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh","-c","tail -n 20 /data/out.txt; sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: demo-pvc
YAML

echo "==> Wait for reader pod ready"
kubectl -n "${NS}" wait --for=condition=Ready pod/reader --timeout=120s || {
  echo "Reader pod not ready. Current status:"
  kubectl -n "${NS}" get pod reader -o wide || true
  exit 1
}

echo "==> Reader logs (should include prior lines)"
kubectl -n "${NS}" logs reader || true

echo "==> Demo complete. Cleanup with: kubectl delete ns ${NS}"
