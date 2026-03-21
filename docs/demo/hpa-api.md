# HPA Demo — API Autoscaling Under Load

Shows the API Deployment scaling from 1 → N replicas under sustained traffic,
then scaling back down after the load test finishes.

## Prerequisites

| Tool | Purpose |
|------|---------|
| `kubectl` (with cluster access) | watch HPA / pods |
| `k6` | generate load |
| API reachable at a known URL | port-forward or Ingress |

---

## Step 1 — Verify starting state (1 replica)

```bash
kubectl -n demo-app get deploy api
# NAME   READY   UP-TO-DATE   AVAILABLE
# api    1/1     1            1

kubectl -n demo-app get hpa api
# NAME   REFERENCE         TARGETS   MINPODS   MAXPODS   REPLICAS
# api    Deployment/api    2%/70%    1         10        1
```

---

## Step 2 — Open two watch terminals

**Terminal A — watch HPA:**
```bash
kubectl -n demo-app get hpa api -w
```

**Terminal B — watch Deployment replicas:**
```bash
kubectl -n demo-app get deploy api -w
```

---

## Step 3 — Expose the API

If no Ingress is configured, use port-forward:

```bash
kubectl -n demo-app port-forward svc/api 8080:80
```

---

## Step 4 — Run the load test

```bash
k6 run -e BASE_URL=http://localhost:8080 tests/load/k6-api.js
```

Duration: **5 minutes total** (1m ramp-up → 3m sustained → 1m ramp-down).

---

## Expected results

### During sustained load (minutes 1–4)

`kubectl get hpa api -w` output:
```
NAME   REFERENCE         TARGETS    MINPODS   MAXPODS   REPLICAS
api    Deployment/api    12%/70%    1         10        1
api    Deployment/api    84%/70%    1         10        1
api    Deployment/api    84%/70%    1         10        3
api    Deployment/api    71%/70%    1         10        4
api    Deployment/api    52%/70%    1         10        4
```

`kubectl get deploy api -w` output:
```
NAME   READY   UP-TO-DATE   AVAILABLE
api    1/1     1            1
api    1/4     4            1
api    4/4     4            4
```

### After load (minute 4–5 + ~5m cooldown)

Replicas return to 1 within the HPA default scale-down stabilisation window:
```
api    Deployment/api    4%/70%    1    10    4
api    Deployment/api    2%/70%    1    10    1
```

### k6 summary (expected)

```
http_req_duration.............: p(95)=450ms
http_req_failed...............: 0.00%
checks........................: 100.00%
```

---

## HPA configuration reference

```yaml
# manifests/demo-app/hpa.yaml
spec:
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70   # scale when avg CPU > 70% of request (50m)
```

Trigger threshold: **70% × 50m = 35m CPU per pod**.
At 50 VUs each sending ~10 req/s, a single FastAPI pod exceeds this within ~60s.
