# Runbook: WorkerNotConsuming / WorkerSQSBacklogCritical

**Alerts**:
- `WorkerNotConsuming` (warning — 0 events processed for 5 minutes)
- `WorkerSQSBacklogCritical` (critical — SQS depth > 50 for 5 minutes)

**SLO**: SQS backlog < 50 messages at all times during load

---

## Symptom

```
WorkerNotConsuming: Worker processed 0 events in the last 5 minutes
WorkerSQSBacklogCritical: SQS backlog above 50 messages for 5+ minutes
```

Events are queuing in SQS but not being written to the `events` DB table.

---

## Diagnosis

### 1 — Check worker pods

```bash
kubectl -n demo-app get pods -l app=worker
kubectl -n demo-app logs -l app=worker --tail=50
```

Look for:
- `DB connection lost, reconnecting` — Postgres down
- `ERROR processing message` — deserialization or constraint failure
- `AccessDeniedException` — IRSA role issue

### 2 — Check KEDA ScaledObject

```bash
kubectl -n demo-app get scaledobject worker
kubectl -n demo-app describe scaledobject worker
```

If `READY: False`, KEDA cannot read the queue depth — likely an IRSA issue.

### 3 — Check SQS queue depth directly

```bash
aws sqs get-queue-attributes \
  --queue-url "$(kubectl -n demo-app get secret demo-app-secrets \
    -o jsonpath='{.data.sqs_queue_url}' | base64 -d)" \
  --attribute-names ApproximateNumberOfMessages \
  --region eu-west-3
```

### 4 — Check Prometheus metric

```promql
rate(worker_events_processed_total{namespace="demo-app"}[5m])
```

If this is 0 with pods running, the worker loop is stuck (DB issue or SQS read blocking).

### 5 — Check worker replicas vs maxReplicaCount

```bash
kubectl -n demo-app get deploy worker
```

If replicas = 10 (maxReplicaCount) and queue keeps growing, the worker is genuinely
overwhelmed — `maxReplicaCount` may need raising or `queueLength` tuning.

---

## Likely Causes

| Cause | Indicator |
|-------|-----------|
| Postgres down | `DB connection lost` in logs, `PostgresDown` alert co-fires |
| IRSA role revoked (sqs-worker SA) | `AccessDeniedException` in logs, ScaledObject READY=False |
| Worker in `non-idempotent` mode (WORKER_MODE env changed) | Logs show `BROKEN processed` |
| maxReplicaCount hit, queue growing faster than workers drain | 10 replicas, queue depth increasing |
| Worker pod stuck / deadlocked | Pods Running but 0 processed_total rate |

---

## Safe Mitigations

### Postgres is down — see `postgres-down.md` runbook first

### IRSA issue — restart pods to refresh credentials
```bash
kubectl -n demo-app rollout restart deployment/worker
kubectl -n demo-app rollout status deployment/worker
```

### Worker mode accidentally set to non-idempotent
```bash
kubectl -n demo-app set env deployment/worker WORKER_MODE=idempotent
```

### Temporarily raise maxReplicaCount to drain the backlog
```bash
kubectl -n demo-app patch scaledobject worker \
  --type=merge -p '{"spec":{"maxReplicaCount":20}}'
# Revert after backlog clears:
kubectl apply -f manifests/demo-app/keda-scaledobject.yaml
```

---

## Stop the Bleeding

If the queue is growing uncontrollably, pause the producer (API) temporarily:
```bash
kubectl -n demo-app scale deployment/api --replicas=0
```
Fix the worker issue, drain the queue, then restore:
```bash
kubectl -n demo-app scale deployment/api --replicas=1
```
