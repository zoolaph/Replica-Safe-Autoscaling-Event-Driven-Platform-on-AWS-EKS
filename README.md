# Replica-Safe-Autoscaling-Event-Driven-Platform-on-AWS-EKS
Turn “Kubernetes deployed but not scalable” into a production-minded platform: safe horizontal scaling for Kafka consumers, HA across AZs, lag-based autoscaling (KEDA), network isolation, and backup/restore with defined RPO/RTO.
---
## Clear description (what problem this fixes)

Many teams “migrate to Kubernetes” but still run **1 replica** because scaling breaks correctness: duplicate Kafka processing, singleton jobs running twice, state stored in memory, unsafe shutdowns, noisy alerts, no recovery plan.

This project builds a **complete, reproducible reference system** that:

1. **Demonstrates the failure** (“before”: scaling causes duplicate processing / inconsistency)
2. **Fixes it properly** (“after”: replica-safe patterns)
3. **Proves it under load** (traffic + lag)
4. **Operates it like production** (SLOs, alerts, runbooks, network policies, backups & restore drills)

---

## What “finished” means (acceptance checklist)

The project is considered finished when you can do these demos end-to-end from the README:

1. `terraform apply` → EKS platform is created (multi-AZ)
2. `kubectl apply` / Helm → platform components installed
3. Deploy app stack → accessible via Ingress
4. **Before mode:** scaling worker to 2+ replicas causes duplicates (documented incident)
5. **After mode:** enable idempotency → scaling is safe (proof + tests)
6. Run load test → API scales with HPA
7. Run lag test → worker scales with **KEDA** based on Kafka lag (not CPU)
8. Alerts fire correctly (lag, 5xx, p95 latency) + runbooks exist
9. NetworkPolicies enforce default-deny and only allow required traffic
10. Backup & restore drill succeeds:

* Velero restores namespace/resources (and PV if used)
* Postgres restore from S3 succeeds

11. `docs/tradeoffs.md` explains the key design choices (cost/HA, ALB vs NGINX, etc.)

---

# Major steps (with what must be done)

## 1) Repo + documentation foundation

**Goal:** make the project readable like a real engineering artifact.

**Do:**

* Create a clean repo structure: `infra/`, `platform/`, `apps/`, `docs/`, `tests/`
* Write README sections:

  * Problem statement
  * Architecture diagram
  * Quickstart (deploy + demo)
  * “Before vs After” scenario
  * Reliability features (SLOs, alerts, backups)
* Add CI basics:

  * Terraform fmt/validate/plan on PR
  * Lint for YAML/Helm (optional but nice)

**Done when:** a stranger can understand the goal in 2 minutes.

---

## 2) AWS infrastructure with Terraform (multi-AZ EKS)

**Goal:** prove AWS fundamentals + repeatable infra provisioning.

**Do:**

* Terraform modules for:

  * VPC across **3 AZs** (public/private subnets, routing, NAT)
  * EKS cluster
  * Managed Node Groups
  * IAM/OIDC provider for **IRSA**
* Outputs for kubeconfig and cluster info
* Document cost-aware choices (NAT gateways, node sizes)

**Done when:** `terraform apply` brings a working EKS cluster consistently.

---

## 3) Kubernetes “platform layer”

**Goal:** make the cluster usable like a real platform.

**Do:**

* Install and configure:

  * **AWS Load Balancer Controller** (Ingress via ALB) using IRSA
  * **metrics-server** (HPA dependency)
  * **kube-prometheus-stack** (Prometheus/Grafana/Alertmanager)
* Provide Helm values and “platform install” instructions

**Done when:** you can deploy an app and view metrics in Grafana.

---

## 4) Build the demo application stack (fully yours)

**Goal:** create a small system that behaves like real event-driven microservices.

**Do:**

* Services (Go or Python, but consistent):

  * `api` (HTTP): creates events
  * `worker` (Kafka consumer): processes events and writes to Postgres
  * `postgres`
  * `kafka` (in-cluster for MVP; document tradeoffs)
  * `k6` load generator (Job)
* Kubernetes manifests/Helm chart for the stack
* Health checks, readiness/liveness, proper config via ConfigMaps/Secrets

**Done when:** one replica end-to-end flow works reliably.

---

## 5) “Before mode” — reproduce the scaling failure (incident)

**Goal:** show you understand why scaling breaks and how to prove it.

**Do:**

* Implement an intentionally **non-idempotent** worker path:

  * duplicates cause inconsistent DB state
* Run load test + scale worker replicas 1 → 2 → 5
* Capture evidence (logs/metrics) of duplicates

**Documentation required:**

* `docs/postmortems/INCIDENT-001-duplicate-processing.md`

  * impact, root cause, immediate fix, long-term fix
* `docs/runbooks/ALERT-kafka-lag.md` (initial version)

**Done when:** you can reliably reproduce the failure from README steps.

---

## 6) “After mode” — make the system replica-safe

**Goal:** demonstrate the pattern that unlocks horizontal scaling.

**Do:**

* Implement **idempotency** (recommended MVP pattern):

  * idempotency key per event
  * dedup table in Postgres (unique constraint)
  * safe retries + backoff
* Add graceful shutdown:

  * stop consuming, drain in-flight work, then exit
* Re-run the same test: scaling no longer breaks correctness

**Done when:** duplicates don’t change final state, even at 5+ replicas under load.

---

## 7) Autoscaling for high traffic

**Goal:** show “high traffic detection and scaling” in a meaningful way.

**Do:**

* **HPA for API** (CPU-based MVP)
* **Cluster Autoscaler** (MVP) to add nodes when pods can’t schedule
  *(Optional upgrade later: Karpenter)*

**Done when:** traffic spike → API replicas scale automatically and remain stable.

---

## 8) Kafka lag–based autoscaling (KEDA) — your “ooo” feature

**Goal:** scale workers by **backlog**, the correct signal for event systems.

**Do:**

* Install **KEDA**
* Create a `ScaledObject` for the worker based on Kafka consumer lag
* Tune:

  * min/max replicas
  * lag threshold
  * cooldown/scale-to-zero behavior (optional)
* Add dashboards + alerts:

  * lag rising
  * lag not recovering

**Done when:** you can demonstrate lag → worker scales → lag returns to normal.

---

## 9) Network security (default-deny + allow-list)

**Goal:** show production-minded segmentation and blast-radius reduction.

**Do:**

* Install a NetworkPolicy enforcement solution:

  * **Cilium** *or* **Calico**
* Apply:

  * default-deny for app namespace(s)
  * explicit allow rules for required flows only:

    * ingress → api
    * api → kafka/postgres
    * worker → kafka/postgres
    * monitoring namespace → scrape targets
    * DNS egress allowed (explicit)
* Add a matrix doc: “who talks to whom and why”

**Done when:** without allow rules the app breaks, with allow rules it works—proving policies are actually enforced.

---

## 10) Backup & recovery (with RPO/RTO)

**Goal:** prove survivability, not just uptime.

### 10A) Cluster resources & PV: Velero

**Do:**

* Install **Velero** with S3 backend (IRSA)
* Scheduled backups + on-demand backup
* Restore drill: delete namespace → restore → service back

### 10B) Postgres backup to S3 (WAL-G or pgBackRest)

**Do:**

* Configure backups to S3
* Restore drill: drop/corrupt a table → restore → verify data consistency

### Document RPO/RTO

* `docs/backup/rpo-rto.md` with realistic demo targets and assumptions

**Done when:** you can run a restore drill from docs and it works.

---

## 11) Observability, SLOs, alerts, runbooks (production ops layer)

**Goal:** show you can operate it, not just deploy it.

**Do:**

* Define 2–3 SLIs:

  * API: p95 latency, 5xx rate
  * Worker: lag, processing errors
* Create dashboards (RED/USE)
* Alert rules with runbooks:

  * `ALERT-High5xx.md`
  * `ALERT-HighLatencyP95.md`
  * `ALERT-KafkaLag.md`
  * `ALERT-NodePressure.md` (optional)

**Done when:** alerts fire during drills and your runbooks actually help resolve them.

---

## 12) Reliability drills + final packaging

**Goal:** provide “proof artifacts” a senior engineer respects.

**Do:**

* GameDay scripts (or documented steps):

  * kill pod
  * drain node
  * temporarily break Kafka
  * overload system to trigger scaling + alerts
* Write 1 more postmortem (example: mis-tuned KEDA or HPA thrash)
* Finish docs:

  * `docs/tradeoffs.md`
  * `docs/architecture.md` + diagram
  * `docs/demos/` (each demo step-by-step)

**Done when:** anyone can reproduce your claims with copy/paste steps.

---

# Final “finished project” deliverables list (what your repo must contain)

* ✅ Terraform infra for EKS multi-AZ + IRSA
* ✅ Platform install (ALB controller, metrics-server, Prometheus stack)
* ✅ App stack (API + Kafka + worker + Postgres + load tests)
* ✅ Before/After scaling correctness demo
* ✅ HPA + Cluster Autoscaler
* ✅ KEDA lag-based scaling
* ✅ Enforced NetworkPolicies + traffic matrix
* ✅ Velero backup/restore + Postgres backup/restore + RPO/RTO doc
* ✅ Dashboards, alerts, runbooks
* ✅ 2 postmortems + GameDay drills
* ✅ Tradeoffs doc
