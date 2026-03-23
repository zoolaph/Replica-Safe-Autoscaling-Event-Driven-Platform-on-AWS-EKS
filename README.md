# Replica-Safe, Autoscaling Event-Driven Platform on AWS EKS

**A reproducible reference implementation that proves Kubernetes event-driven workloads can scale safely.**

Most "Kubernetes migrations" run **1 replica** for event consumers because scaling breaks correctness:
duplicate processing, phantom rows, state collisions. This project demonstrates the failure, fixes it
properly, and operates it like production — SLOs, alerts, runbooks, backup drills, and autoscaling
evidence under real load.

---

## What this project proves

| # | Claim | Evidence |
|---|-------|----------|
| 1 | Multi-AZ EKS cluster deployable from Terraform | `terraform apply` → cluster, VPC, IRSA, VPC endpoints |
| 2 | Scaling a naive consumer causes duplicates | `demo-05-incident-001.sh` → duplicate rows in DB |
| 3 | Idempotency + DB constraint eliminates duplicates | `demo-06-fix-idempotency.sh` → exactly N rows for N events |
| 4 | HPA scales the API under CPU load | `demo-03-scale-api-hpa.sh` → 1 → 3-4 replicas under k6 load |
| 5 | KEDA scales the worker based on queue depth | `demo-04-scale-worker-keda.sh` → 1 → 10 replicas as SQS fills |
| 6 | SLOs, alerts, and runbooks are in place | `manifests/monitoring/` + `docs/sre/slo.md` + `docs/runbooks/` |
| 7 | Design decisions are justified, not assumed | `docs/architecture/tradeoffs.md` |

---

## Architecture

```
                       Internet
                          │
                    (AWS ALB Ingress)
                          │
              ┌───────────▼───────────┐
              │   API (FastAPI)        │  HPA: CPU 70%, 1-10 replicas
              │   POST /events         │  Prometheus metrics via /metrics
              └───────────┬───────────┘
                          │ SQS send_message
                          ▼
              ┌───────────────────────┐
              │   Amazon SQS Queue    │  Fully managed, IRSA access
              │   (eu-west-3)         │
              └───────────┬───────────┘
                          │ receive_message / delete_message
              ┌───────────▼───────────┐
              │   Worker (Python)      │  KEDA: queueLength=5, 0-10 replicas
              │   ON CONFLICT DO NOTH  │  Prometheus counters: processed + deduped
              └───────────┬───────────┘
                          │ INSERT ... ON CONFLICT DO NOTHING
              ┌───────────▼───────────┐
              │   Postgres (in-cluster)│  PVC: gp3, Velero backup to S3
              │   UNIQUE(event_id)     │
              └───────────────────────┘

Observability layer (all namespaces):
  kube-prometheus-stack → Prometheus, Grafana, Alertmanager
  PrometheusRule: 7 alerts (API 5xx, latency, worker lag, crashloop, postgres down)
  AlertmanagerConfig: Slack routing (critical / warning channels)
  Runbooks: docs/runbooks/*.md

Platform layer (kube-system / dedicated namespaces):
  AWS Load Balancer Controller  — ALB Ingress
  KEDA                          — SQS-based worker autoscaling
  Cluster Autoscaler            — Node autoscaling
  Kyverno                       — Policy: no latest tag, no privileged, require resource limits
  Velero                        — Namespace backup/restore to S3
  cert-manager + external-dns   — TLS + Route53 DNS management
```

---

## Prerequisites

### Local tools (pinned in `mise.toml`)

| Tool | Version |
|------|---------|
| terraform | 1.7.5 |
| aws-cli | 2.15.57 |
| kubectl | 1.29.7 |
| helm | 3.14.4 |
| k6 | latest |

Install with [mise](https://mise.jdx.dev/): `mise install`

### AWS

- A dedicated AWS account (strongly recommended — this creates VPC, EKS, IAM roles, S3 buckets)
- AWS SSO or long-lived credentials configured in `~/.aws/config` under profile `dev`
- Budget alert configured on the account

### Before you start

```bash
# Authenticate to AWS (SSO or configured profile)
./bin/rsedp aws

# Verify tools are available
./bin/rsedp bootstrap
```

---

## Quickstart (end-to-end, ~20 minutes)

### 1 — Bootstrap Terraform backend (once per account)

```bash
cd infra/bootstrap
terraform init
terraform apply
# Creates S3 bucket + DynamoDB table for remote state
```

### 2 — Provision AWS infrastructure

```bash
./bin/rsedp env
# Runs terraform init/plan/apply in infra/environments/dev/
# Creates: VPC (3 AZs), EKS 1.29, node group (t3.medium x2),
#          IRSA roles, SQS queue, VPC endpoints, S3 bucket for backups
# Updates kubeconfig automatically.

kubectl get nodes   # verify 2 nodes are Ready
```

### 3 — Install platform add-ons

```bash
./bin/rsedp metrics       # metrics-server (required for HPA)
./bin/rsedp alb           # AWS Load Balancer Controller
./bin/rsedp autoscaler    # Cluster Autoscaler
./bin/rsedp observability # kube-prometheus-stack (Prometheus, Grafana, Alertmanager)
./bin/rsedp logging       # CloudWatch container insights
./bin/rsedp cert-manager  # cert-manager
./bin/rsedp external-dns  # external-dns (Route53)
./bin/rsedp apply-policies # Kyverno policies

# Verify everything is green
./bin/rsedp check
```

### 4 — Build and push application images

```bash
ECR_REGISTRY="$(terraform -chdir=infra/environments/dev output -raw ecr_registry)"
AWS_REGION=eu-west-3
AWS_PROFILE=dev

aws ecr get-login-password --region ${AWS_REGION} --profile ${AWS_PROFILE} \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

docker build -t "${ECR_REGISTRY}/api:dev"    apps/api/
docker build -t "${ECR_REGISTRY}/worker:dev" apps/worker/

docker push "${ECR_REGISTRY}/api:dev"
docker push "${ECR_REGISTRY}/worker:dev"
```

### 5 — Deploy the demo-app stack

```bash
./scripts/demo-01-deploy.sh
# Deploys: namespace, secrets, postgres, api, worker, hpa, keda-scaledobject
# Waits for all rollouts to complete.
# Prints pod status and API endpoint.

kubectl -n demo-app get pods   # all Running
```

### 6 — Apply monitoring

```bash
kubectl apply -f manifests/monitoring/prometheusrule.yaml
kubectl apply -f manifests/monitoring/alertmanager-config.yaml

# Create the Slack webhook secret (replace with your real URL)
kubectl -n demo-app create secret generic alertmanager-slack \
  --from-literal=url=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
```

### 7 — Smoke test

```bash
./scripts/demo-02-smoke.sh 20
# Sends 20 events, waits for worker to drain, asserts 20 rows in DB.
# Expected: [PASS] Row count matches — no duplicates, no lost events
```

---

## Demos

Run the demos in order. Each one builds on the previous.

### Demo 1 — Deploy (covered in Quickstart step 5)

```bash
./scripts/demo-01-deploy.sh
```

### Demo 2 — Smoke test

```bash
./scripts/demo-02-smoke.sh [count]
```

Asserts: events sent = DB rows. Proves end-to-end path is healthy.

### Demo 3 — HPA: API scales under traffic

```bash
./scripts/demo-03-scale-api-hpa.sh
```

Runs a 5-minute k6 load test (50 VUs). Watch HPA scale the API from 1 → 3-4 replicas.
Expected: k6 p95 < 2 s, error rate < 5%.

Full walkthrough: [docs/demo/hpa-api.md](docs/demo/hpa-api.md)

### Demo 4 — KEDA: Worker scales with queue depth

```bash
./scripts/demo-04-scale-worker-keda.sh [message-count]
```

Pumps 100 messages into SQS. Watch KEDA scale the worker from 1 → 10 replicas as the
queue fills, then back to 0 after it drains.

Full walkthrough: [docs/demo/keda-worker.md](docs/demo/keda-worker.md)

### Demo 5 — INCIDENT-001: Duplicate processing (the "before" state)

```bash
./scripts/demo-05-incident-001.sh [event-count]
```

Switches worker to `non-idempotent` mode, scales to 5 replicas, sends 50 events.
Result: 200+ rows in `processed_events` for 50 unique events — **data corruption**.

Postmortem: [docs/incidents/INCIDENT-001.md](docs/incidents/INCIDENT-001.md)

### Demo 6 — Fix: Idempotency eliminates duplicates (the "after" state)

```bash
./scripts/demo-06-fix-idempotency.sh [event-count]
```

Switches worker to `idempotent` mode, sends each event_id twice (simulating SQS re-delivery),
keeps 5 replicas. Result: exactly N rows in `events` table — **correct under any replica count**.

---

## SLOs and Alerts

Four SLOs are defined in [docs/sre/slo.md](docs/sre/slo.md):

| SLO | Target | Alert |
|-----|--------|-------|
| API Availability | 99.9% non-5xx / 30 days | `APIHighErrorRate` (warn), `APIHighErrorRateCritical` |
| API Latency | p95 < 500 ms | `APIHighLatency` (warn) |
| Worker Processing Lag | SQS depth < 50 for 5 min | `WorkerSQSBacklogCritical` |
| Postgres Availability | 99.9% pod ready | `PostgresDown` (critical) |

Runbooks: [docs/runbooks/](docs/runbooks/)

---

## Tradeoffs

Key design decisions are justified (not assumed) in [docs/architecture/tradeoffs.md](docs/architecture/tradeoffs.md):

- Karpenter vs Cluster Autoscaler
- SQS vs Kafka
- DB-level dedup vs application-level Redis SET NX
- IRSA vs node IAM roles
- VPC Endpoints vs NAT Gateway
- In-cluster Postgres vs RDS Multi-AZ
- Kyverno vs OPA/Gatekeeper

---

## Repo structure

```
.
├── apps/
│   ├── api/            FastAPI HTTP server — publishes to SQS
│   ├── worker/         SQS consumer — idempotent/non-idempotent modes
│   └── db/migrations/  Postgres schema (events + processed_events tables)
├── infra/
│   ├── bootstrap/      Terraform state backend (S3 + DynamoDB)
│   └── environments/
│       └── dev/        EKS cluster, VPC, IRSA, SQS queue, S3 backup bucket
├── platform/addons/    Helm values for: ALB controller, observability, KEDA, Velero, Kyverno...
├── manifests/
│   ├── demo-app/       K8s manifests: namespace, api, worker, postgres, hpa, keda-scaledobject
│   └── monitoring/     PrometheusRule (7 alerts), AlertmanagerConfig (Slack routing)
├── scripts/
│   ├── demo-01-deploy.sh          Deploy demo-app stack
│   ├── demo-02-smoke.sh           Send N events, assert N DB rows
│   ├── demo-03-scale-api-hpa.sh   k6 load test → HPA scale-out
│   ├── demo-04-scale-worker-keda.sh  Pump SQS → KEDA scale-out
│   ├── demo-05-incident-001.sh    Reproduce duplicate processing
│   ├── demo-06-fix-idempotency.sh Prove idempotency fix
│   └── ...                        Platform install helpers (rsedp targets)
├── tests/load/
│   ├── k6-api.js       5-min HPA load test (50 VUs)
│   └── k6-burst.js     Burst load test
├── docs/
│   ├── architecture/
│   │   └── tradeoffs.md           Design decisions with explicit alternatives
│   ├── incidents/
│   │   └── INCIDENT-001.md        Duplicate processing postmortem
│   ├── runbooks/                  Operational runbooks for every alert
│   ├── sre/slo.md                 SLO definitions with PromQL + error budgets
│   └── demo/                      HPA and KEDA demo walkthroughs
├── bin/rsedp           Command dispatcher
└── mise.toml           Tool version pinning
```

---

## Contributing / Working agreements

- Every feature includes: tests + observability + docs + demo steps
- Every operational change includes: failure modes + rollback plan + verification
- Small commits, readable history
- CI checks: `terraform fmt/validate/plan`, manifest lint, smoke test on merge
