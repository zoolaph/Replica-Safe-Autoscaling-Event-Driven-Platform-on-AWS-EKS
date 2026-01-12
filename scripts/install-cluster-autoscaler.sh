#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infra/environments/dev"

CLUSTER_NAME="$(terraform -chdir="${TF_DIR}" output -raw cluster_name)"
ROLE_ARN="$(terraform -chdir="${TF_DIR}" output -raw cluster_autoscaler_role_arn)"
AWS_REGION="$(terraform -chdir="${TF_DIR}" output -raw region)"

echo "Installing Cluster Autoscaler"
echo "  cluster: ${CLUSTER_NAME}"
echo "  region : ${AWS_REGION}"
echo "  role   : ${ROLE_ARN}"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cluster-autoscaler
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-autoscaler
rules:
  - apiGroups: [""]
    resources: ["events", "endpoints"]
    verbs: ["create", "patch"]

  - apiGroups: [""]
    resources: ["pods/eviction"]
    verbs: ["create"]

  - apiGroups: [""]
    resources: ["pods/status"]
    verbs: ["update"]

  - apiGroups: [""]
    resources:
      ["pods", "services", "replicationcontrollers", "persistentvolumeclaims", "persistentvolumes", "namespaces"]
    verbs: ["watch", "list", "get"]

  # ✅ FIX: CA must be able to taint/label nodes during scale-down
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["watch", "list", "get", "update", "patch"]

  - apiGroups: ["apps"]
    resources: ["statefulsets", "replicasets", "daemonsets", "deployments"]
    verbs: ["watch", "list", "get"]

  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["watch", "list", "get"]

  # ✅ add "get" (some CA code paths read PDB objects)
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["watch", "list", "get"]

  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses", "csinodes", "csidrivers", "csistoragecapacities", "volumeattachments"]
    verbs: ["watch", "list", "get"]

  # ✅ leader election: include watch + patch
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["create", "get", "list", "watch", "update", "patch"]

  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["volumeattachments"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-autoscaler
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-autoscaler
subjects:
  - kind: ServiceAccount
    name: cluster-autoscaler
    namespace: kube-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-autoscaler
  namespace: kube-system
  labels:
    app: cluster-autoscaler
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cluster-autoscaler
  template:
    metadata:
      labels:
        app: cluster-autoscaler
      annotations:
        cluster-autoscaler.kubernetes.io/safe-to-evict: "false"
    spec:
      serviceAccountName: cluster-autoscaler
      nodeSelector:
        kubernetes.io/os: linux
      containers:
        - name: cluster-autoscaler
          image: registry.k8s.io/autoscaling/cluster-autoscaler:v1.32.0
          command:
            - ./cluster-autoscaler
            - --cloud-provider=aws
            - --stderrthreshold=info
            - --v=4
            - --expander=least-waste
            - --balance-similar-node-groups
            - --skip-nodes-with-system-pods=false
            - --node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled,k8s.io/cluster-autoscaler/${CLUSTER_NAME}
          env:
            - name: AWS_REGION
              value: "${AWS_REGION}"
            - name: AWS_DEFAULT_REGION
              value: "${AWS_REGION}"
          resources:
            requests:
              cpu: 100m
              memory: 300Mi
EOF

echo "Done. Verify with:"
echo "  kubectl -n kube-system logs deploy/cluster-autoscaler --tail=200"
