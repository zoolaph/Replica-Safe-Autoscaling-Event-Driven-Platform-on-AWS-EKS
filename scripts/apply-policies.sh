#!/usr/bin/env bash
set -euo pipefail

DIR="${DIR:-platform/addons/policies/kyverno}"

kubectl apply -f "${DIR}"
kubectl get cpol
