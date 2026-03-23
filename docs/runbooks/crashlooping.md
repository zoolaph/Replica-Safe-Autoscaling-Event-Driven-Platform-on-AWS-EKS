# Runbook: PodCrashLooping

**Alert**: `PodCrashLooping` (critical — any pod in demo-app is in CrashLoopBackOff for 5+ minutes)

---

## Symptom

```
PodCrashLooping: Pod worker-abc123 / worker is crash-looping
```

The pod is in `CrashLoopBackOff` — Kubernetes is restarting it with exponential backoff
because the container exits immediately after starting.

---

## Diagnosis

### 1 — Identify which pod and container

```bash
kubectl -n demo-app get pods
# Look for STATUS=CrashLoopBackOff or high RESTARTS count
```

### 2 — Read current and previous logs

```bash
POD=<pod-name>
kubectl -n demo-app logs $POD
kubectl -n demo-app logs $POD --previous   # logs from the last crash
```

The crash message is almost always in the last few lines of `--previous`.

### 3 — Describe the pod for exit codes and events

```bash
kubectl -n demo-app describe pod $POD
```

Key fields:
- `Exit Code` — 1 = application error, 137 = OOMKilled, 139 = segfault
- `Reason: OOMKilled` — memory limit hit
- `Events:` section — shows if it was evicted or a liveness probe killed it

### 4 — Check recent config/secret changes

```bash
kubectl -n demo-app get events --sort-by='.lastTimestamp' | tail -20
git log --oneline -10   # check if a deployment happened recently
```

---

## Likely Causes by Exit Code

| Exit Code | Meaning | Common Cause |
|-----------|---------|--------------|
| 1 | Application error | Missing env var, bad config, startup validation failed |
| 137 | OOMKilled | Memory limit too low |
| 139 | Segfault | Rare in Python — usually a C extension issue |

### Application startup failures (exit 1) — worker
The worker validates environment on start:
```python
if not SQS_QUEUE_URL: raise SystemExit("SQS_QUEUE_URL not set")
if not PGPASSWORD: raise SystemExit("PGPASSWORD not set")
if WORKER_MODE not in ("idempotent", "non-idempotent"): raise SystemExit(...)
```
Check the Secret:
```bash
kubectl -n demo-app get secret demo-app-secrets -o yaml
```

### Application startup failures (exit 1) — API
```python
if not SQS_QUEUE_URL: raise SystemExit("SQS_QUEUE_URL not set")
```

---

## Safe Mitigations

### Bad env var / secret — fix the Secret and rollout
```bash
# Edit the secret (base64-encode values)
kubectl -n demo-app edit secret demo-app-secrets

# Restart deployment to pick up new secret
kubectl -n demo-app rollout restart deployment/<name>
kubectl -n demo-app rollout status deployment/<name>
```

### OOMKilled — raise memory limit
```bash
kubectl -n demo-app set resources deployment/<name> \
  --limits=memory=1Gi
```

### Bad deployment — rollback
```bash
kubectl -n demo-app rollout undo deployment/<name>
kubectl -n demo-app rollout status deployment/<name>
```

---

## Stop the Bleeding

While the pod is in backoff, Kubernetes will keep retrying. To prevent resource churn
while you diagnose:
```bash
# Scale to 0, fix the issue, scale back
kubectl -n demo-app scale deployment/<name> --replicas=0
# ... fix ...
kubectl -n demo-app scale deployment/<name> --replicas=1
```
