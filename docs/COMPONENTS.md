# Component Reference

A guide to every entry point, script, and manifest in this repo — what each piece does, what AWS/Kubernetes resources it touches, and what you would change to modify its behaviour.

---

## `bin/rsedp` subcommands

The `rsedp` binary is a thin dispatcher — every subcommand delegates to the matching script in `scripts/`. Running `./bin/rsedp <cmd>` is equivalent to running `./scripts/<cmd>.sh` directly.

| Subcommand | What it does | AWS / K8s resources touched |
|---|---|---|
| `aws` | Ensures AWS SSO profile exists and logs in; prints caller identity | AWS STS (identity check only) |
| `bootstrap` | Creates the Terraform remote state backend on first use | S3 bucket (`replicasafeeks-tfstate-<account>-<region>`), DynamoDB table (`replicasafeeks-tflock`) |
| `up` | Full platform bring-up in the correct dependency order (infra → add-ons → app → check) | All resources below, sequentially |
| `down` | Full platform teardown: deletes K8s demo resources first, then runs `terraform destroy` | demo-app / demo-ingress / demo-storage namespaces, all Terraform-managed infra |
| `env` | Runs `terraform init/validate/plan/apply` in `infra/environments/dev`; updates kubeconfig | EKS cluster, VPC, IRSA roles, SQS queue, S3 backup bucket |
| `check` | Sanity-checks cluster readiness: nodes, metrics-server, EBS CSI, ALB controller, Cluster Autoscaler, KEDA | Read-only kubectl queries |
| `destroy` | Deletes K8s demo resources + runs `terraform destroy`; accepts `--yes` to skip confirmation | Same as `down`, but more configurable (dry-run, skip flags) |
| `metrics` | Applies `manifests/metrics.yaml` and waits for metrics-server rollout | `kube-system/deploy/metrics-server` |
| `alb` | Installs AWS Load Balancer Controller via Helm using Terraform outputs | `kube-system` Helm release, IRSA role for ALB |
| `demo-alb` | Applies `manifests/demo-alb.yaml`, waits for ALB hostname, and curls the endpoint | `demo-ingress` namespace, ALB via IngressClass `alb` |
| `autoscaler` | Renders `manifests/cluster-autoscaler.yaml.tmpl` with Terraform outputs and applies it | `kube-system/deploy/cluster-autoscaler`, EC2 Auto Scaling Groups |
| `demo-autoscaling` | Applies `manifests/demo-autoscaling.yaml` and scales `cpu-hog` to 5 replicas to trigger node scale-out | `cpu-hog` Deployment, Cluster Autoscaler, EC2 node group |
| `sqs` | Installs KEDA via Helm; renders and applies `manifests/sqs.yaml.tmpl` with SQS queue details | `keda` namespace, KEDA Helm release, `sqs-worker` Deployment + ScaledObject |
| `pump-sqs` | Sends N messages (default 20) to the demo SQS queue to trigger KEDA scale-out | SQS queue (`keda_demo_queue_url` from Terraform output) |
| `velero` | Installs Velero via Helm using the S3 backup bucket + IRSA role from Terraform | `velero` namespace, Helm release, S3 bucket, IRSA |
| `demo-velero` | Runs a full backup → delete → restore drill using `manifests/demo-velero.yaml` | `demo-velero` namespace, Velero Backup/Restore CRs, S3 bucket |
| `observability` | Installs `kube-prometheus-stack` (Prometheus, Grafana, Alertmanager) via Helm | `observability` namespace, Helm release, CRDs: PrometheusRule, AlertmanagerConfig |
| `logging` | Installs `aws-for-fluent-bit` via Helm to ship container logs to CloudWatch | `logging` namespace, Helm release, CloudWatch log groups, IRSA |
| `cert-manager` | Installs cert-manager via Helm (prerequisite for TLS ingress) | `cert-manager` namespace, Helm release, CRDs: Certificate, ClusterIssuer |
| `external-dns` | Installs external-dns via Helm to sync Ingress hostnames to Route 53 | `external-dns` namespace, Helm release, Route 53 hosted zone, IRSA |
| `apply-policies` | Applies all Kyverno ClusterPolicies from `platform/addons/policies/kyverno/` | Kyverno CRs: ClusterPolicy (no-latest-tag, no-privileged, etc.) |
| `audit` | Read-only cost/leak audit — lists remaining AWS resources by tag after a destroy | EC2, ELB, S3, RDS, EKS — read-only `aws` CLI queries |
| `all` | Convenience chain: `env → metrics → alb → autoscaler → sqs → check` (no demos) | Same as running those subcommands in sequence |
| `help` | Prints usage | — |

---

## `scripts/`

### Platform lifecycle

| Script | What it does | Expected output |
|---|---|---|
| `aws.sh` | AWS SSO login: checks if session is valid, runs `aws configure sso` once if profile is missing, then `aws sso login` | Caller identity printed to stdout |
| `bootstrap.sh` | Creates the S3 + DynamoDB Terraform backend via `terraform apply` in `infra/bootstrap/` | "Apply complete!" with bucket and table names |
| `up.sh` | Orchestrates full platform bring-up across 13 steps; supports `--skip-infra` and `--skip-deploy` flags | "Platform is up" with pod/node summary |
| `down.sh` | Deletes K8s demo namespaces (to let ALB controller clean up AWS resources), then runs `terraform destroy`; requires `--yes` or interactive confirmation | Terraform destroy output + "Teardown complete" summary |
| `env.sh` | `terraform init/validate/plan/apply` in `infra/environments/dev` then `aws eks update-kubeconfig` | "Apply complete!" + `kubectl get nodes` output |
| `check.sh` | Probes every platform component (metrics-server, EBS CSI, ALB, Cluster Autoscaler, KEDA) and prints `[PASS]`/`[FAIL]` per check | All `[PASS]` when platform is healthy |
| `destroy.sh` | Parameterised teardown: K8s cleanup + `terraform destroy`; supports `--dry-run`, `--skip-k8s`, `--yes` | Terraform destroy output |
| `all.sh` | Chains `env → metrics → alb → autoscaler → sqs → check` without demos | Same output as each step in sequence |
| `audit.sh` | Lists remaining AWS resources (EC2, ELB, S3, EKS) filtered by project tag; used to catch cost leaks after destroy | Per-resource summaries grouped by service |

### Platform add-on installers

| Script | What it does | Expected output |
|---|---|---|
| `metrics.sh` | `kubectl apply -f manifests/metrics.yaml`, waits for rollout, runs `kubectl top nodes` | `kubectl top nodes` showing CPU/memory per node |
| `alb.sh` | Reads Terraform outputs (cluster name, VPC, IRSA role), then `helm upgrade --install` the AWS Load Balancer Controller | Helm release status + controller pod running in `kube-system` |
| `autoscaler.sh` | Reads Terraform outputs, renders `manifests/cluster-autoscaler.yaml.tmpl`, applies it | `cluster-autoscaler` pod running in `kube-system` |
| `install-observability.sh` | `helm upgrade --install` `kube-prometheus-stack` into `observability` namespace | Prometheus, Grafana, Alertmanager pods running |
| `install-logging.sh` | `helm upgrade --install` `aws-for-fluent-bit` into `logging` namespace (requires `CLUSTER_NAME` and `CLOUDWATCH_ROLE_ARN`) | Fluent Bit DaemonSet running; logs appearing in CloudWatch |
| `install-cert-manager.sh` | `helm upgrade --install` cert-manager into `cert-manager` namespace (pinned to v1.15.3) | cert-manager pods running + CRDs registered |
| `install-external-dns.sh` | `helm upgrade --install` external-dns into `external-dns` namespace (requires `DOMAIN` and `HOSTED_ZONE_ID`) | external-dns pod running; Route 53 records syncing |
| `install-kyverno.sh` | `helm upgrade --install` Kyverno into `kyverno` namespace (pinned to 3.2.6) | Kyverno admission controller pods running |
| `apply-policies.sh` | `kubectl apply -f platform/addons/policies/kyverno/`; lists resulting ClusterPolicies | ClusterPolicy objects created/updated |
| `enable-pss.sh` | Labels namespaces with Pod Security Standards (`enforce=baseline`, `warn/audit=restricted`); skips system namespaces | Namespace labels set; non-compliant pods warned in events |
| `velero.sh` | Reads Terraform outputs, renders `platform/addons/velero/values.yaml.tmpl`, `helm upgrade --install` Velero | Velero pod running in `velero` namespace |
| `setup-dns-tls.sh` | Detects (or accepts) a Route 53 public hosted zone and prints next steps for TLS ingress setup | Hosted zone details + instructions for ClusterIssuer/Certificate |

### Demo scripts

Run these in order to prove each platform capability end-to-end.

| Script | What it proves | Expected output |
|---|---|---|
| `demo-01-deploy.sh` | Deploys the full `demo-app` stack (namespace, secrets, postgres, api, worker, HPA, KEDA ScaledObject) | All deployments Ready; API endpoint URL printed |
| `demo-02-smoke.sh` | Sends N events to the API, asserts N unique rows land in Postgres | `[PASS] N rows found in DB` |
| `demo-03-scale-api-hpa.sh` | Runs a k6 load test (50 VUs) and watches HPA scale the API from 1 → 3–4 replicas under CPU load | HPA replicas increase; scale-down after load stops |
| `demo-04-scale-worker-keda.sh` | Pumps 100 SQS messages; KEDA scales the worker from 0 → 10 replicas as queue depth rises | KEDA ScaledObject replica count shown increasing then draining |
| `demo-05-incident-001.sh` | Reproduces INCIDENT-001: switches worker to non-idempotent mode (no message deletion, 1 s visibility timeout) with 5 replicas → duplicate rows appear in Postgres | Row count exceeds event count; `worker_events_processed_total{mode="non-idempotent"}` inflated |
| `demo-06-fix-idempotency.sh` | Restores idempotent mode; reruns with 5 replicas; asserts exactly N rows despite duplicated deliveries | Row count equals event count; `deduped_total` counter increments |
| `demo-alb.sh` | Applies `manifests/demo-alb.yaml` (nginx + ALB Ingress), waits for hostname, curls the endpoint | HTTP 200 from ALB DNS name |
| `demo-autoscaling.sh` | Applies `manifests/demo-autoscaling.yaml`, scales `cpu-hog` to 5, shows pending pods triggering Cluster Autoscaler | New EC2 nodes joining; pending pods become Running |
| `demo-storage.sh` | Creates a PVC (gp3), writes data from a writer pod, deletes the writer, reads the same data from a reader pod | Reader logs show data written by the deleted writer |
| `demo-velero.sh` | Full backup → delete namespace → restore drill using Velero CRs | Restore phase=Completed; service responds after restore |
| `pump-sqs.sh` | Sends N messages (default 20) to the SQS queue from Terraform output | `N messages sent` confirmation per batch |
| `sqs.sh` | Installs KEDA + applies the SQS-triggered ScaledObject for the standalone SQS demo | KEDA pods running; `sqs-worker` Deployment scaling with queue depth |

---

## `manifests/`

### `manifests/demo-app/` — core application stack

| File | What it defines | Why it exists |
|---|---|---|
| `namespace.yaml` | `demo-app` Namespace | Isolates all application workloads from platform namespaces |
| `serviceaccounts.yaml` | `demo-api` and `sqs-worker` ServiceAccounts with IRSA annotations | Grants pods scoped AWS permissions (SQS send / receive) via pod identity — no static credentials |
| `secrets.yaml` | `demo-app-secrets` Secret template (pg_password, sqs_queue_url) | Supplies runtime config to api and worker containers; placeholder values are substituted by `demo-01-deploy.sh` |
| `postgres.yaml` | `postgres` StatefulSet + Service + PVC (gp3, 1 Gi) | In-cluster database; StatefulSet ensures stable pod identity and persistent volume binding across restarts |
| `api.yaml` | `api` Deployment + Service (FastAPI, port 8080) | HTTP entry point; publishes events to SQS; exposes `/metrics` for Prometheus scraping |
| `worker.yaml` | `worker` Deployment + `db-migrations` ConfigMap | SQS consumer; runs DB migrations on start; idempotent mode (`ON CONFLICT DO NOTHING`) is toggled via `IDEMPOTENT_MODE` env var |
| `hpa.yaml` | HorizontalPodAutoscaler targeting `api` (CPU 70%, 1–10 replicas) | Scales the API horizontally under load; requires metrics-server |
| `keda-scaledobject.yaml` | KEDA `ScaledObject` + `TriggerAuthentication` for `worker` (SQS queue depth, queueLength=5, 0–10 replicas) | Scales workers to zero when queue is empty (cost saving) and up to 10 under load; uses pod IRSA for SQS access |
| `network-policies.yaml` | `NetworkPolicy` default-deny + per-workload allow rules for `demo-app` | Enforces least-privilege network access: api → SQS, worker → postgres + SQS, Prometheus → api/worker metrics ports |

### `manifests/monitoring/` — alerting

| File | What it defines | Why it exists |
|---|---|---|
| `prometheusrule.yaml` | `PrometheusRule` with 7 alert rules (API error rate, latency, pod restarts, worker lag, queue depth, dedup rate, SLO burn rate) | Prometheus Operator picks this up automatically; alerts fire into Alertmanager without manual config |
| `alertmanager-config.yaml` | `AlertmanagerConfig` routing demo-app alerts to a Slack webhook | Namespace-scoped; Prometheus Operator merges it into the global Alertmanager config so platform and app alerts stay separated |

### `manifests/` — root-level

| File | What it defines | Why it exists |
|---|---|---|
| `metrics.yaml` | Full metrics-server manifest (rendered from upstream Helm chart) | Vendored so `./bin/rsedp metrics` works without Helm; required by HPA for CPU/memory metrics |
| `cluster-autoscaler.yaml.tmpl` | Cluster Autoscaler Deployment template with `__CLUSTER_NAME__` / `__REGION__` placeholders | Template is rendered at deploy time by `autoscaler.sh` from Terraform outputs; avoids hardcoded cluster names |
| `sqs.yaml.tmpl` | KEDA `ScaledObject` + `sqs-worker` Deployment template with `__QUEUE_URL__` / `__ROLE_ARN__` placeholders | Same pattern as above; rendered from Terraform outputs by `sqs.sh` |
| `demo-alb.yaml` | nginx Deployment + Service + Ingress (IngressClass: alb) in `demo-ingress` namespace | Proves the AWS Load Balancer Controller can provision an ALB from an Ingress resource |
| `demo-autoscaling.yaml` | `cpu-hog` Deployment (requests 450m CPU, 0 replicas by default) | Produces scheduling pressure when scaled up; triggers Cluster Autoscaler to add EC2 nodes |
| `demo-storage.yaml` | PVC (gp3, 1 Gi) + writer Pod in `demo-storage` namespace | Proves EBS CSI driver provisions persistent volumes and data survives pod deletion |
| `demo-tls-ingress.yaml` | `echo` Service + Ingress with TLS annotation in `demo-tls` namespace | Proves cert-manager + external-dns integration: automatic certificate issuance and Route 53 record creation |
| `demo-velero.yaml` | Simple HTTP server Deployment + Service in `demo-velero` namespace | Provides a stateful target for the Velero backup → delete → restore drill |
| `bad-pod.yaml` | Pod with `privileged: true` and `image: nginx:latest` in `demo-security` namespace | Used to prove Kyverno ClusterPolicies block non-compliant workloads (latest tag + privileged container) |
