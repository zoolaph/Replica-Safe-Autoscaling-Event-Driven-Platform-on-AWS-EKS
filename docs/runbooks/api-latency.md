# Runbook: APIHighLatency

**Alert**: `APIHighLatency` (warning — p95 > 500 ms for 5 minutes)
**SLO**: API p95 latency < 500 ms

---

## Symptom

Prometheus alert fires:
```
APIHighLatency: API p95 latency above 500 ms
```
Users may experience slow responses on `POST /events`.

---

## Diagnosis

### 1 — Check current latency in Grafana / Prometheus

```promql
histogram_quantile(0.95,
  sum(rate(http_request_duration_seconds_bucket{namespace="demo-app"}[5m])) by (le)
)
```

### 2 — Check replica count and CPU

```bash
kubectl -n demo-app get hpa api
kubectl -n demo-app top pods -n demo-app -l app=api
```

If HPA has not yet scaled up, CPU may be near the threshold (70% of 50m = 35m).

### 3 — Check SQS send latency

```bash
kubectl -n demo-app logs -l app=api --tail=100 | grep -i "sqs\|send"
```

Long SQS `send_message` calls increase overall request duration.

### 4 — Check for GC / memory pressure

```bash
kubectl -n demo-app describe pods -l app=api | grep -E "OOM|Killed|Memory"
```

---

## Likely Causes

| Cause | Indicator |
|-------|-----------|
| Single replica under load before HPA fires | 1 replica, CPU near 35m, HPA `TARGETS` near 70% |
| SQS SDK retrying due to throttling | Slow SQS calls in logs, AWS throttle errors |
| Python GIL / uvicorn worker queue backup | Increasing memory, slow fan-out |
| Cold start after scale-out | Latency spike during `AVAILABLE: 1/4` phase |

---

## Safe Mitigations

### HPA has not fired yet — scale manually to unblock
```bash
kubectl -n demo-app scale deployment/api --replicas=3
```
(HPA will take control back once metrics normalise.)

### SQS throttling — check if queue is saturated
```bash
aws sqs get-queue-attributes \
  --queue-url "$SQS_QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --region eu-west-3
```
If queue is very large, the worker side may be the real problem — see `worker-lag.md`.

### Roll back if the regression followed a deployment
```bash
kubectl -n demo-app rollout history deployment/api
kubectl -n demo-app rollout undo deployment/api
```

---

## Stop the Bleeding

```bash
# Temporarily raise maxReplicas in hpa.yaml and apply:
kubectl -n demo-app patch hpa api \
  --type=merge -p '{"spec":{"maxReplicas":20}}'
```
Revert after the incident with `kubectl apply -f manifests/demo-app/hpa.yaml`.
