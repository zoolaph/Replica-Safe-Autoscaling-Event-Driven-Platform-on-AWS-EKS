# Architecture Tradeoffs — Replica-Safe EDP on AWS EKS

This document justifies the key design decisions made in this project.
Each choice is framed as a concrete alternative comparison with explicit reasoning.

---

## 1 — Karpenter vs Cluster Autoscaler

**Decision: Cluster Autoscaler**

| | Cluster Autoscaler | Karpenter |
|--|--|--|
| Node provisioning | Scales existing node groups (ASGs) | Directly provisions EC2 instances via Fleet API |
| Speed | ~2–5 min to add a node | ~30–60 s to add a node |
| Bin packing | Limited — bound to pre-defined node groups | Aggressive — picks cheapest instance for pending pods |
| Spot support | Requires separate ASG per Spot pool | Native multi-pool Spot fallback |
| Maturity | Stable, years of production use | GA since 2023, rapid adoption |
| Complexity | Low — one `--node-group-auto-discovery` flag | Higher — `NodePool` + `EC2NodeClass` CRDs, IAM |

**Why Cluster Autoscaler here:**
The project uses a single `t3.medium` node group, which is the simplest starting point for a portfolio demo.
Karpenter's bin-packing advantage matters when you have heterogeneous workloads and want to minimize
instance count. For a two-node dev cluster demonstrating KEDA and HPA, the added IAM complexity of
Karpenter is not justified.

**When to switch:** When running mix of Spot + On-Demand, multiple instance families, or needing
sub-90-second node launch for real latency-sensitive scale-out.

---

## 2 — SQS vs Kafka / Redpanda

**Decision: Amazon SQS**

| | SQS | Kafka (MSK / self-hosted) |
|--|--|--|
| Ops burden | Zero — fully managed | High (MSK) or Very high (self-hosted) |
| Latency | ~10–20 ms | < 5 ms |
| Replay | No native replay (once deleted, gone) | Full log replay to any offset |
| Ordering | FIFO queue: per-message-group ordering | Per-partition ordering |
| Consumer groups | Not applicable — each message delivered once | Built-in consumer group rebalancing |
| Cost at low volume | ~$0.40/million msgs | MSK: $0.21/hour per broker minimum |
| KEDA integration | `aws-sqs-queue` scaler — depth-based | `kafka` scaler — consumer group lag-based |

**Why SQS here:**
The core thesis of the project is **idempotency** and **replica-safe processing**, not message ordering or
replay. SQS is sufficient to demonstrate the duplicate-processing failure (INCIDENT-001) and the fix.
The fully managed nature eliminates broker operations, letting the project focus on the Kubernetes
autoscaling story.

**What we lose:** Replay for debugging, partition-level ordering, consumer group lag as the native scaling
signal. The KEDA `aws-sqs-queue` scaler compensates for lag-based scaling using queue depth.

**When to switch:** When event sourcing, audit trail, or stream processing (Flink/Spark) is required.

---

## 3 — Idempotency: ON CONFLICT DO NOTHING vs application-level dedup

**Decision: Postgres `ON CONFLICT (event_id) DO NOTHING` in the `events` table**

| | DB-level dedup (UNIQUE + ON CONFLICT) | App-level dedup (Redis SET NX) |
|--|--|--|
| Atomic | Yes — insert + check are one operation | No — check-then-insert race possible |
| Durability | Postgres durability guarantees apply | Requires Redis persistence |
| Latency | One DB round-trip | One Redis + one DB round-trip |
| Correctness | Guaranteed even with N replicas | Requires TTL tuning; risk of eviction |
| Ops | No extra dependency | Redis added to infra |

**Why DB-level:**
Atomic by construction. A `UNIQUE` constraint on `event_id` means two concurrent replicas that
receive the same re-delivered message race to insert — one wins, one gets `rowcount=0` and counts it
as a deduplicated event. No external lock needed, no race condition.

The `processed_events` table (no UNIQUE constraint) was deliberately left in to power the **broken
mode** demo in INCIDENT-001, showing what happens without the constraint.

---

## 4 — IRSA (IAM Roles for Service Accounts) vs node-level IAM roles

**Decision: IRSA — per-pod IAM identity**

| | IRSA | Node IAM role |
|--|--|--|
| Blast radius | Pod can only call APIs in its role | Any pod on that node can call any API in the role |
| Auditability | CloudTrail shows which pod assumed which role | Only EC2 instance identity visible |
| Rotation | Token auto-rotated by EKS OIDC provider | Key rotation manual |
| Complexity | ServiceAccount annotation + IAM trust policy | Simpler — attach role to launch template |

**Why IRSA:**
Least-privilege by default. The worker pod gets `sqs:ReceiveMessage / DeleteMessage / GetQueueAttributes`
and nothing else. The Velero pod gets its own S3-scoped role. The ALB controller gets its controller
role. A compromised pod cannot escalate to write ECR images or access other queues.

**Node IAM role is still present** (EKS requires it for kubelet ECR pull), but it only has the minimum
permissions: `ecr:GetAuthorizationToken` and node registration policies.

---

## 5 — VPC Endpoints vs NAT Gateway for AWS API traffic

**Decision: VPC Interface Endpoints for ECR, STS; Gateway Endpoint for S3**

| | VPC Endpoints | NAT Gateway |
|--|--|--|
| ECR pull cost | Free (traffic stays in AWS network) | $0.045/GB (Paris region) |
| STS calls cost | Free | $0.045/GB |
| S3 (backups) cost | Free (Gateway endpoint) | $0.045/GB |
| Setup | 4 endpoints, ~3 min Terraform | 1 NAT Gateway, simpler |
| Fixed cost | ~$7.20/month per Interface endpoint | $32.40/month per NAT Gateway (+ data) |

**Why Endpoints for a dev cluster:**
ECR image pulls are the dominant data transfer cost in a K8s cluster. Every pod start pulls layers.
With a NAT Gateway, a 1 GB image pull costs $0.045 per node that pulls it. Interface endpoints
eliminate this at $0/GB. For S3 (Velero backups, Terraform state), the Gateway endpoint is free.

**Trade-off:** Four endpoints at $0.01/hr each = $7.20/month fixed overhead vs pay-per-GB NAT.
At typical dev cluster image pull volumes (few GB/day), endpoints break even in days.

---

## 6 — HPA for API vs KEDA for API

**Decision: HPA (CPU-based) for API; KEDA (SQS depth) for Worker**

The API is a stateless HTTP server — its load is directly correlated with CPU. HPA with a 70% CPU
target is the idiomatic choice. No external metric needed.

The Worker is an SQS consumer — its load is the queue depth, which is invisible to CPU until the
queue is already deep. If the queue fills faster than CPU rises (e.g., producer burst), CPU-based HPA
would react too slowly. KEDA's `aws-sqs-queue` scaler triggers scale-out at `queueLength: 5` messages
per replica, meaning a depth of 50 → 10 replicas before CPU pressure builds.

**Why not KEDA for everything:** KEDA requires IRSA permissions to read the queue. The API does not
touch SQS from a consumer perspective — it only produces. Adding KEDA for the API would add complexity
with no correctness benefit.

---

## 7 — Single-AZ Postgres vs Multi-AZ RDS

**Decision: Single-pod Postgres in EKS with a PVC (gp3)**

| | Self-managed Postgres on EKS | RDS Multi-AZ |
|--|--|--|
| HA | No — pod on one node; restart ~30 s | Automatic failover ~60 s |
| Ops | Manual backup (Velero + pgBackRest) | Automated backups, point-in-time recovery |
| Cost | $0 (runs on existing node) | ~$100–400/month (db.t3.medium Multi-AZ) |
| Complexity | PVC, init scripts, password in Secret | Terraform RDS module, security group |

**Why in-cluster Postgres:**
Cost. A Multi-AZ RDS instance would dominate the monthly bill of a portfolio demo cluster. The goal is
to demonstrate **backup/restore procedures and SLO definitions**, not production database HA. The
`PostgresDown` alert and runbook demonstrate the operational response to a database failure.

**SLO implication:** The 99.9% Postgres availability SLO is aspirational in this configuration —
a node failure or PVC issue will breach it. This is documented explicitly in `docs/sre/slo.md` to
show awareness of the limitation, not to hide it.

**When to switch:** Any real production workload. Use RDS with `deletion_protection = true` and
automated minor version upgrades.

---

## 8 — Alertmanager Slack routing vs PagerDuty

**Decision: Slack via `AlertmanagerConfig` CRD**

The demo uses Slack as the notification channel because it requires no paid subscription and the
`AlertmanagerConfig` CRD pattern is identical whether the receiver is Slack, PagerDuty, or OpsGenie.
The important part of the implementation is the routing tree (critical → 1 h repeat, warning → 4 h
repeat, groupWait tiering) — not the specific receiver.

To swap in PagerDuty: replace `slackConfigs` with `pagerdutyConfigs` in
`manifests/monitoring/alertmanager-config.yaml`.

---

## 9 — Kyverno vs OPA/Gatekeeper for Policy

**Decision: Kyverno**

| | Kyverno | OPA/Gatekeeper |
|--|--|--|
| Policy language | YAML/CEL | Rego |
| Learning curve | Low — K8s-native syntax | High — Rego is a niche DSL |
| Mutation support | First-class | Requires separate MutatingWebhook |
| Community | CNCF incubating | CNCF graduated |
| Audit mode | Built-in | Built-in |

**Why Kyverno:** The three policies in this project (`block-latest-tag`, `disallow-privileged`,
`require-resources`) map naturally to Kyverno's validation rules without any Rego knowledge. The
declarative YAML syntax means the policy file is self-documenting to anyone who reads a Kubernetes
manifest.

---

## Summary

| Decision | Choice | Main Reason |
|----------|--------|-------------|
| Node autoscaler | Cluster Autoscaler | Simpler for single node group |
| Message broker | SQS | Zero ops, sufficient for idempotency demo |
| Dedup mechanism | DB UNIQUE + ON CONFLICT | Atomic, no extra dependency |
| Pod IAM | IRSA | Least-privilege per workload |
| Egress cost | VPC Endpoints | Cheaper than NAT at typical ECR pull volumes |
| API scaling | HPA (CPU) | Stateless HTTP — CPU is the right signal |
| Worker scaling | KEDA (SQS depth) | Queue depth precedes CPU pressure |
| Database | In-cluster Postgres | Cost — demo doesn't need RDS HA |
| Alerting sink | Slack | No subscription required; pattern is portable |
| Policy engine | Kyverno | YAML-native, lower barrier to read |
