# Replica-Safe, Autoscaling Event-Driven Platform on AWS EKS

**Subtitle:** Turn “Kubernetes deployed but not scalable” into a production-minded platform: safe horizontal scaling for Kafka consumers, HA across AZs, lag-based autoscaling (KEDA), network isolation, observability, and backup/restore with defined RPO/RTO.

## Why this exists (problem statement)

A lot of “Kubernetes migrations” end up running **1 replica** for stateful/event-driven workloads because scaling breaks correctness:
- duplicate Kafka processing
- singleton jobs running twice
- state stored in memory
- unsafe shutdowns and rebalances
- noisy alerts and no recovery plan

This project is a **reproducible reference implementation** that:
1) Demonstrates the failure (“before”: scaling causes duplicates / inconsistency)  
2) Fixes it properly (“after”: replica-safe patterns)  
3) Proves it under load (traffic + lag)  
4) Operates it like production (SLOs, alerts, runbooks, backup/restore drills, network policies)

---

## High-level architecture

```

```
                     ┌───────────────────────────────┐
                     │            Internet           │
                     └───────────────┬───────────────┘
                                     │
                               (AWS ALB Ingress)
                                     │
                           ┌─────────▼─────────┐
                           │        API        │
                           │  HTTP: create evt │
                           └─────────┬─────────┘
                                     │ produce
                                     ▼
                            ┌───────────────────┐
                            │       Kafka       │
                            │ topics + consumer │
                            └─────────┬─────────┘
                                      │ consume
                                      ▼
                           ┌────────────────────┐
                           │       Worker       │
                           │ Kafka consumer grp │
                           │ replica-safe logic │
                           └─────────┬──────────┘
                                     │ write
                                     ▼
                              ┌─────────────┐
                              │  Postgres   │
                              │ dedup + data│
                              └─────────────┘
```

Observability:

* Prometheus/Grafana/Alertmanager (kube-prometheus-stack)
* Dashboards + alerts + runbooks

Autoscaling:

* HPA for API (CPU-based)
* KEDA for Worker (Kafka lag-based)
* Cluster Autoscaler (nodes)

Security:

* NetworkPolicies (default-deny + allowlist)
* IRSA for AWS access (Velero S3, ALB controller, etc.)

Backup/Restore:

* Velero (K8s resources + PVs if applicable) to S3
* Postgres backups to S3 (pgBackRest or WAL-G) + restore drills

````

---

## Repo structure

- `infra/`  
  Terraform for AWS: VPC (multi-AZ), EKS, node groups, IRSA/OIDC, S3 buckets for backups, etc.

- `platform/`  
  Cluster add-ons (Helm/Manifests): AWS Load Balancer Controller, metrics-server, kube-prometheus-stack, KEDA, network policy engine (Cilium/Calico), Velero.

- `apps/`  
  Demo application stack (manifests or Helm): `api`, `worker`, `kafka`, `postgres`, `k6` jobs.

- `tests/`  
  Load & correctness tests: k6 scripts, integration checks, idempotency verification.

- `docs/`  
  Architecture, tradeoffs, demos, runbooks, postmortems, backup RPO/RTO.

---

## Quality bar (what “finished” means)

This project is “done” when the README steps can reproduce all of the following:

1. `terraform apply` → multi-AZ EKS platform exists
2. Platform components installed (ALB controller, metrics-server, monitoring)
3. App stack deployed and reachable via Ingress
4. **Before mode:** scaling `worker` to 2+ replicas causes duplicates (documented incident)
5. **After mode:** idempotency makes scaling safe (proof + tests)
6. Load test → `api` scales with HPA
7. Lag test → `worker` scales with KEDA based on Kafka lag
8. Alerts fire correctly + runbooks exist
9. NetworkPolicies enforce default-deny and only allow required traffic
10. Backup & restore drill succeeds:
   - Velero restores namespace/resources (and PVs if used)
   - Postgres restore from S3 succeeds
11. `docs/tradeoffs.md` explains key design choices and costs

---

## Requirements

### Local tools
- `terraform` (pinned)
- `awscli` (pinned)
- `kubectl` (pinned)
- `helm` (pinned)

See: `tools/versions.md` (or `.tool-versions` / `mise.toml`)

### AWS
- Dedicated AWS account strongly recommended
- Do NOT use root credentials for daily work
- Budget alerts enabled

---

## Quickstart (end-to-end)

> NOTE: These commands are the target interface. Replace paths/names based on your repo conventions.

### 1) Provision AWS infra (Terraform)
```bash
cd infra
terraform init
terraform plan
terraform apply
````

Expected outputs:

* EKS cluster name/endpoint
* kubeconfig command or `aws eks update-kubeconfig ...`

### 2) Configure kubectl

```bash
aws eks update-kubeconfig --region <REGION> --name <CLUSTER_NAME>
kubectl get nodes
```

### 3) Install platform add-ons

```bash
# Example (actual install scripts live in platform/)
cd platform

# ALB Controller (IRSA), metrics-server, kube-prometheus-stack
./install_platform.sh
```

Verify:

```bash
kubectl get pods -A
kubectl get ingress -A
```

### 4) Deploy the app stack

```bash
cd apps
./deploy_apps.sh
```

Verify:

```bash
kubectl get pods -n apps
kubectl get svc -n apps
kubectl get ingress -n apps
```

---

## Demos (proof the system works)

Each demo has step-by-step instructions and expected evidence under `docs/demos/`.

### Demo 1 — BEFORE mode: scaling breaks correctness (duplicate processing)

Goal: show why naive scaling is unsafe.

Steps:

* Deploy worker in “before” mode (non-idempotent path)
* Run load/produce events
* Scale worker 1 → 2 → 5 replicas
* Capture evidence of duplicates / inconsistent DB state

Artifacts:

* `docs/postmortems/INCIDENT-001-duplicate-processing.md`

### Demo 2 — AFTER mode: replica-safe processing

Goal: scaling is safe under retries and concurrency.

Implementation expectation (MVP):

* Idempotency key per event
* Dedup table in Postgres (`UNIQUE(event_id)`)
* Safe retries + backoff
* Graceful shutdown (drain in-flight, then exit)

Evidence:

* Same test as Demo 1 produces correct final state at 5+ replicas
* `tests/` include an automated correctness check

### Demo 3 — HPA traffic scaling (API)

Goal: traffic spike → API scales and remains stable.

Evidence:

* HPA events
* p95 latency + 5xx dashboards show stable service

### Demo 4 — KEDA lag-based autoscaling (Worker)

Goal: backlog (Kafka lag) is the scaling signal.

Evidence:

* Lag increases
* KEDA scales worker
* Lag returns to normal
* Cooldown behaves sanely (no thrash)

### Demo 5 — Network isolation (default-deny + allowlist)

Goal: prove policies are enforced, not just present.

Evidence:

* Default-deny breaks the app
* Allow rules restore only required flows
* `docs/security/traffic-matrix.md` documents “who talks to whom and why”

### Demo 6 — Backup & restore drill (RPO/RTO)

Goal: survivability, not vibes.

Velero:

* Scheduled backup to S3
* Restore drill: delete namespace → restore → service returns

Postgres:

* Backups to S3 (pgBackRest/WAL-G)
* Restore drill: drop/corrupt table → restore → verify data

Evidence:

* `docs/backup/rpo-rto.md` with realistic targets and assumptions

### Demo 7 — Observability, SLOs, alerts, runbooks

Goal: operate like production.

Minimum:

* SLIs: API p95 latency, 5xx rate; Worker lag, processing errors
* Alerts + runbooks:

  * `docs/runbooks/ALERT-High5xx.md`
  * `docs/runbooks/ALERT-HighLatencyP95.md`
  * `docs/runbooks/ALERT-KafkaLag.md`

---

## CI expectations (non-negotiable)

* Terraform: `fmt`, `validate`, `plan` on merge requests
* Kubernetes manifests/Helm: lint (as applicable)
* Tests: at least one automated correctness test and one load test entrypoint
* Every milestone updates docs + includes a demo procedure

---

## Tradeoffs * justify decisions *

See `docs/tradeoffs.md`:

* Kafka in-cluster vs managed MSK
* ALB vs NGINX ingress
* Cluster Autoscaler vs Karpenter
* NetworkPolicy engine choice (Cilium vs Calico)
* Backup tooling and cost implications

---

## Contributing / Working agreements

* Small commits, readable history
* Every feature includes: tests + observability + docs + demo steps
* Any operational feature must include: failure modes + rollback plan + verification steps
