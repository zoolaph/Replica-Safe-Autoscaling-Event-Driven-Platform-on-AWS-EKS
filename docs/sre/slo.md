# SLO Definitions — demo-app

This document defines the Service Level Objectives for the demo-app platform.
Each SLO has a corresponding Prometheus alert in `manifests/monitoring/prometheusrule.yaml`
and a runbook in `docs/runbooks/`.

---

## SLO 1 — API Availability

| Field | Value |
|-------|-------|
| **Target** | 99.9% of requests return non-5xx per 30-day window |
| **Error budget** | 0.1% ≈ 43 minutes/month |
| **SLI** | `1 - (5xx requests / total requests)` over 30 days |

**Prometheus expression (burn rate indicator):**
```promql
1 - (
  sum(rate(http_request_duration_seconds_count{namespace="demo-app",status_code=~"5.."}[30d]))
  /
  sum(rate(http_request_duration_seconds_count{namespace="demo-app"}[30d]))
)
```

**Alerting thresholds (fast-burn):**
- Warning: 5xx rate > 5% for 2 min → `APIHighErrorRate`
- Critical: 5xx rate > 10% for 1 min → `APIHighErrorRateCritical`

**Why these thresholds?**
At 10% error rate sustained for 1 minute you burn ~1.4 h of monthly error budget per hour.
That rate needs paging. At 5% you are burning fast but may self-correct (e.g., brief SQS hiccup).

---

## SLO 2 — API Latency

| Field | Value |
|-------|-------|
| **Target** | p95 request duration < 500 ms |
| **Window** | 5-minute rolling evaluation |
| **SLI** | `histogram_quantile(0.95, http_request_duration_seconds_bucket)` |

**Prometheus expression:**
```promql
histogram_quantile(0.95,
  sum(rate(http_request_duration_seconds_bucket{namespace="demo-app"}[5m])) by (le)
)
```

**Alerting threshold:**
- Warning: p95 > 500 ms for 5 min → `APIHighLatency`

**Why 500 ms?**
The API does two things: validate the payload and call `SQS.send_message`.
A healthy SQS send in `eu-west-3` completes in < 20 ms. Anything above 500 ms
indicates external pressure (load, throttling, or cold start after scale-out).

---

## SLO 3 — Worker Processing Lag

| Field | Value |
|-------|-------|
| **Target** | SQS queue depth < 50 messages during any load period |
| **Window** | 5-minute sustained breach |
| **SLI** | `keda_scaler_metrics_value{scaledObject="worker"}` (KEDA exposes raw SQS depth) |

**Prometheus expression:**
```promql
keda_scaler_metrics_value{scaledObject="worker", namespace="demo-app"}
```

**Alerting thresholds:**
- Warning (not consuming): `rate(worker_events_processed_total[5m]) == 0` for 5 min → `WorkerNotConsuming`
- Critical (backlog): queue depth > 50 for 5 min → `WorkerSQSBacklogCritical`

**Why 50 messages?**
With `queueLength: 5` and `maxReplicaCount: 10` the cluster can drain 10 × (batch of 10) = 100
messages per poll cycle (~15 s). A depth > 50 that persists 5 minutes means KEDA has maxed out
replicas and the worker is still falling behind — the root cause needs investigation.

---

## SLO 4 — Data Store (Postgres) Availability

| Field | Value |
|-------|-------|
| **Target** | Postgres pod ready 99.9% of time |
| **Error budget** | ~43 minutes/month |
| **SLI** | `kube_pod_container_status_ready{pod=~"postgres.*"}` (kube-state-metrics) |

**Alerting threshold:**
- Critical: postgres not ready for 2 min → `PostgresDown`

**Why 2 minutes?**
The worker reconnects immediately on `OperationalError`. A brief pod restart (< 30 s) does
not constitute an SLO event. 2 minutes indicates a hard failure (OOMKill, PVC issue, eviction)
that needs operator action.

---

## Alert → SLO → Runbook Map

| Alert | Severity | SLO | Runbook |
|-------|----------|-----|---------|
| `APIHighErrorRate` | warning | SLO 1 | [api-5xx.md](../runbooks/api-5xx.md) |
| `APIHighErrorRateCritical` | critical | SLO 1 | [api-5xx.md](../runbooks/api-5xx.md) |
| `APIHighLatency` | warning | SLO 2 | [api-latency.md](../runbooks/api-latency.md) |
| `WorkerNotConsuming` | warning | SLO 3 | [worker-lag.md](../runbooks/worker-lag.md) |
| `WorkerSQSBacklogCritical` | critical | SLO 3 | [worker-lag.md](../runbooks/worker-lag.md) |
| `PodCrashLooping` | critical | all | [crashlooping.md](../runbooks/crashlooping.md) |
| `PostgresDown` | critical | SLO 4 | [postgres-down.md](../runbooks/postgres-down.md) |
