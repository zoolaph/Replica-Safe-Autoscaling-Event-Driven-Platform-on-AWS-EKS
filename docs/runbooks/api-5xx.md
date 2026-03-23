# Runbook: APIHighErrorRate / APIHighErrorRateCritical

**Alert**: `APIHighErrorRate` (warning > 5%) / `APIHighErrorRateCritical` (critical > 10%)
**SLO**: API availability 99.9% — 5xx rate must stay below 0.1% in steady state

---

## Symptom

Prometheus alert fires:
```
APIHighErrorRate: API 5xx rate above 5%
```
Users see HTTP 503 responses from `POST /events`.

---

## Diagnosis

### 1 — Check API pod health

```bash
kubectl -n demo-app get pods -l app=api
kubectl -n demo-app logs -l app=api --tail=50
```

Look for:
- `SQS unavailable:` — SQS connectivity or IRSA issue
- `OOMKilled` in describe — memory limit hit

### 2 — Check recent events

```bash
kubectl -n demo-app describe pod -l app=api | grep -A5 Events
```

### 3 — Check HPA / replica count

```bash
kubectl -n demo-app get hpa api
kubectl -n demo-app get deploy api
```

If replicas are maxed (10/10) and CPU is 100%, the pod may be overloaded.

### 4 — Check SQS / IRSA permissions

```bash
# Look for access denied errors
kubectl -n demo-app logs -l app=api | grep -i "access\|denied\|403"
```

---

## Likely Causes

| Cause | Indicator |
|-------|-----------|
| SQS IRSA role revoked / misconfigured | `SQS unavailable: AccessDeniedException` in logs |
| SQS queue deleted or URL changed | `SQS unavailable: AWS.SimpleQueueService.NonExistentQueue` |
| Pod OOMKilled, restarting mid-request | Repeated pod restarts, `OOMKilled` in describe |
| HPA maxed out, pod under severe load | `replicas: 10/10`, CPU 100% |

---

## Safe Mitigations

### IRSA / SQS permission issue
```bash
# Verify the SA has the correct IAM role annotation
kubectl -n demo-app describe sa demo-api

# Re-apply to pick up any Terraform changes
kubectl -n demo-app rollout restart deployment/api
```

### OOMKilled — raise memory limit temporarily
```bash
kubectl -n demo-app set resources deployment/api \
  --limits=memory=1Gi --requests=memory=256Mi
```

### Roll back a bad deployment
```bash
kubectl -n demo-app rollout undo deployment/api
kubectl -n demo-app rollout status deployment/api
```

---

## Stop the Bleeding

If the API is returning 100% errors and rollback doesn't help, route traffic away:
```bash
# Scale to zero if an ALB/Ingress is in front (stops new traffic hitting broken pods)
kubectl -n demo-app scale deployment/api --replicas=0
# Then investigate before scaling back up
```
