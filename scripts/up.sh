#!/usr/bin/env bash
# up.sh — Full platform bring-up.
#
# Sequence:
#   1.  env            — terraform apply (VPC, EKS, IRSA, SQS, S3 backup bucket)
#   2.  metrics        — metrics-server (required for HPA)
#   3.  alb            — AWS Load Balancer Controller
#   4.  autoscaler     — Cluster Autoscaler
#   5.  observability  — kube-prometheus-stack (Prometheus, Grafana, Alertmanager)
#   6.  logging        — CloudWatch container insights
#   7.  cert-manager   — cert-manager
#   8.  external-dns   — external-dns (Route53 sync)
#   9.  kyverno        — Kyverno admission controller (install)
#  10.  apply-policies — Kyverno cluster policies (no-latest-tag, no-privileged, etc.)
#  11.  deploy         — demo-app stack: namespace, secrets, postgres, api, worker,
#                        HPA, KEDA ScaledObject, NetworkPolicies
#  12.  monitoring     — PrometheusRule (7 alerts) + AlertmanagerConfig (Slack routing)
#  13.  check          — cluster health sanity check
#
# Usage:
#   ./bin/rsedp up [--skip-infra] [--skip-deploy] [-h|--help]
#
# Options:
#   --skip-infra    Skip step 1 (terraform env). Use when the cluster already exists.
#   --skip-deploy   Skip steps 11-12 (demo-app + monitoring manifests).
#                   Use when ECR images have not been pushed yet.
#   -h, --help      Show this help
#
# Prerequisites:
#   - AWS credentials configured: ./bin/rsedp aws
#   - Tools installed (terraform, kubectl, helm, aws): ./bin/rsedp bootstrap
#   - ECR images pushed (api:dev, worker:dev) before running without --skip-deploy
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SKIP_INFRA="false"
SKIP_DEPLOY="false"

# ─── Arg parsing ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      sed -n '/^# up\.sh/,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p }; /^[^#]/q }' "$0"
      exit 0 ;;
    --skip-infra)   SKIP_INFRA="true";  shift ;;
    --skip-deploy)  SKIP_DEPLOY="true"; shift ;;
    *) echo "ERROR: Unknown argument: $1 (use --help)" >&2; exit 1 ;;
  esac
done

# ─── Helpers ────────────────────────────────────────────────────────────────
run() {
  local cmd="$1"; shift
  echo
  echo "════════════════════════════════════════"
  echo "  rsedp ${cmd}"
  echo "════════════════════════════════════════"
  "${ROOT_DIR}/bin/rsedp" "${cmd}" "$@"
}

banner() {
  echo
  echo "════════════════════════════════════════"
  echo "  $*"
  echo "════════════════════════════════════════"
}

# ─── Step 1: Infra ──────────────────────────────────────────────────────────
if [[ "${SKIP_INFRA}" == "true" ]]; then
  echo "[up] --skip-infra set — skipping terraform env"
else
  run env
fi

# ─── Steps 2-8: Platform add-ons ────────────────────────────────────────────
run metrics
run alb
run autoscaler
run observability
run logging
run cert-manager
run external-dns

# ─── Steps 9-10: Policy engine ──────────────────────────────────────────────
banner "kyverno (install)"
"${ROOT_DIR}/scripts/install-kyverno.sh"

run apply-policies

# ─── Steps 11-12: Application + monitoring ──────────────────────────────────
if [[ "${SKIP_DEPLOY}" == "true" ]]; then
  echo
  echo "[up] --skip-deploy set — skipping demo-app deploy and monitoring manifests"
  echo "     When images are ready, run:"
  echo "       ./scripts/demo-01-deploy.sh"
  echo "       kubectl apply -f manifests/monitoring/prometheusrule.yaml"
  echo "       kubectl apply -f manifests/monitoring/alertmanager-config.yaml"
else
  banner "demo-app stack (demo-01-deploy.sh)"
  "${ROOT_DIR}/scripts/demo-01-deploy.sh"

  banner "monitoring manifests (PrometheusRule + AlertmanagerConfig)"
  kubectl apply -f "${ROOT_DIR}/manifests/monitoring/prometheusrule.yaml"
  kubectl apply -f "${ROOT_DIR}/manifests/monitoring/alertmanager-config.yaml"
fi

# ─── Step 13: Health check ───────────────────────────────────────────────────
run check

echo
echo "════════════════════════════════════════"
echo "  rsedp up — complete"
echo "════════════════════════════════════════"
echo
echo "Next steps:"
echo "  Smoke test  : ./scripts/demo-02-smoke.sh"
echo "  Full demos  : see docs/demos.md"
echo "  Tear down   : ./bin/rsedp destroy --yes"
