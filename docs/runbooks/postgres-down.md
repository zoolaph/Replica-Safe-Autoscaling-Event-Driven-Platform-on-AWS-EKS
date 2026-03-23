# Runbook: PostgresDown

**Alert**: `PostgresDown` (critical — postgres pod not ready for 2+ minutes)
**SLO**: Postgres available 99.9% of time — all workers and API fail without it

---

## Symptom

```
PostgresDown: Postgres pod is not ready
```

Worker pods will log `DB connection lost, reconnecting` on every message. API requests
succeed (they only talk to SQS) but events queue up without being processed.

---

## Diagnosis

### 1 — Check pod status

```bash
kubectl -n demo-app get pod -l app=postgres
kubectl -n demo-app describe pod -l app=postgres
```

Look at the `Events` section at the bottom of describe output.

### 2 — Check logs

```bash
kubectl -n demo-app logs -l app=postgres --tail=100
```

Common patterns:
- `data directory "/var/lib/postgresql/data/pgdata" has wrong ownership` — PVC permission issue
- `FATAL: role "app" does not exist` — init script failed
- `Out of memory: Kill process` — OOMKilled

### 3 — Check PVC

```bash
kubectl -n demo-app get pvc
kubectl -n demo-app describe pvc postgres-data
```

If the PVC is `Pending`, the StorageClass (`gp3`) could not provision a volume.

### 4 — Check recent restarts

```bash
kubectl -n demo-app get pod -l app=postgres \
  -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}'
```

---

## Likely Causes

| Cause | Indicator |
|-------|-----------|
| OOMKilled | `OOMKilled` in describe `Last State`, restart count incrementing |
| PVC unavailable / node rescheduled | PVC in Pending or pod stuck in Init |
| Init script failed on first run | `role "app" does not exist`, pod restarts once |
| Node pressure caused eviction | Events show `Evicted` |
| Config/secret mismatch | `password authentication failed for user "app"` in logs |

---

## Safe Mitigations

### OOMKilled — raise memory limit
```bash
kubectl -n demo-app set resources deployment/postgres \
  --limits=memory=1Gi --requests=memory=512Mi
```

### Pod stuck after node reschedule — restart
```bash
kubectl -n demo-app rollout restart deployment/postgres
kubectl -n demo-app rollout status deployment/postgres
```

### PVC lost (worst case) — check if data exists on the PV
```bash
kubectl -n demo-app get pv
kubectl describe pv <PV_NAME>
```

If the PV still exists but is `Released`, patch reclaim policy and re-bind:
```bash
kubectl patch pv <PV_NAME> -p '{"spec":{"claimRef":null}}'
# Then reapply the PVC manifest
kubectl apply -f manifests/demo-app/postgres.yaml
```

### Secret mismatch — verify PGPASSWORD
```bash
kubectl -n demo-app get secret demo-app-secrets \
  -o jsonpath='{.data.pg_password}' | base64 -d
```
Must match the password used when the Postgres data directory was initialised.

---

## Stop the Bleeding

Workers will auto-reconnect once Postgres is healthy (the `psycopg.OperationalError`
handler in `worker.py` loops on reconnect). No manual intervention needed on worker side.

Monitor recovery:
```bash
kubectl -n demo-app get pod -l app=postgres -w
# Once Running/Ready, watch worker logs:
kubectl -n demo-app logs -f -l app=worker
```
