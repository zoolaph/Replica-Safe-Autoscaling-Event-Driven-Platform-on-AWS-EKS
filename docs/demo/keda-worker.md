# KEDA Demo — Worker Autoscaling by SQS Backlog

Shows the worker Deployment scaling from **0 → N replicas** as SQS queue depth
rises above the threshold, then scaling back to 0 once the backlog drains.

**Why SQS depth, not CPU?**
CPU only rises *after* a worker is already processing messages. Queue depth is
a leading signal — it tells you work is waiting *before* a pod even exists.

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| `kubectl` (with cluster access) | watch ScaledObject / pods |
| `k6` | generate event burst |
| API reachable at a known URL | port-forward or Ingress |
| KEDA installed in cluster | `kubectl get crd scaledobjects.keda.sh` |

---

## Step 1 — Verify starting state (0 replicas)

```bash
kubectl -n demo-app get deploy worker
# NAME     READY   UP-TO-DATE   AVAILABLE
# worker   0/0     0            0

kubectl -n demo-app get scaledobject worker
# NAME     SCALETARGETKIND      SCALETARGETNAME   MIN   MAX   TRIGGERS         READY   ACTIVE
# worker   apps/v1.Deployment   worker            0     10    aws-sqs-queue    True    False
```

ACTIVE=False means the queue is empty and the worker is correctly at 0.

---

## Step 2 — Open three watch terminals

**Terminal A — watch ScaledObject:**
```bash
kubectl -n demo-app get scaledobject worker -w
```

**Terminal B — watch Deployment replicas:**
```bash
kubectl -n demo-app get deploy worker -w
```

**Terminal C — watch individual pods:**
```bash
kubectl -n demo-app get pods -l app=worker -w
```

---

## Step 3 — Expose the API

```bash
kubectl -n demo-app port-forward svc/api 8080:80
```

---

## Step 4 — Generate backlog

Scale worker to 0 first (KEDA may have already done this), then burst events
faster than the worker can drain them:

```bash
# ensure worker is at 0
kubectl -n demo-app scale deploy worker --replicas=0

# in a new terminal, fire the burst (3 minutes total)
k6 run -e BASE_URL=http://localhost:8080 tests/load/k6-burst.js
```

The burst sends ~100 VUs with no sleep — queue depth will exceed the
`activationThreshold: 5` within seconds.

---

## Expected results

### During burst (0–2 min)

`kubectl get scaledobject worker -w` output:
```
NAME     ...   READY   ACTIVE
worker   ...   True    False
worker   ...   True    True      ← queue crossed activationThreshold (5)
```

`kubectl get deploy worker -w` output:
```
NAME     READY   UP-TO-DATE   AVAILABLE
worker   0/0     0            0
worker   0/3     3            0          ← KEDA requested replicas
worker   3/3     3            3          ← pods ready, draining queue
worker   0/0     0            0          ← queue empty, scaled back to 0
```

### k6 summary (expected)

```
http_req_duration.............: p(95)=600ms
http_req_failed...............: 0.00%
checks........................: 100.00%
```

---

## KEDA configuration reference

```yaml
# manifests/demo-app/keda-scaledobject.yaml
spec:
  minReplicaCount: 0        # scale to zero when queue is empty
  maxReplicaCount: 10
  pollingInterval: 15       # KEDA checks SQS every 15 seconds
  cooldownPeriod: 60        # wait 60s idle before scaling to 0
  triggers:
  - type: aws-sqs-queue
    metadata:
      queueLength: "5"          # target: 5 messages per replica
      activationThreshold: "5"  # don't activate until depth > 5
```

**Scale-out formula:** `desiredReplicas = ceil(queueDepth / queueLength)`

| Queue depth | Replicas |
|---|---|
| 0–5 | 0 (below activationThreshold) |
| 6–10 | 2 |
| 11–25 | 3–5 |
| 50 | 10 (max) |
