````md
# Demo — Ingress baseline (AWS Load Balancer Controller)

This demo proves that your EKS cluster can expose an app via an **ALB Ingress** using the **AWS Load Balancer Controller**.

## What “success” means

- The controller is running in `kube-system`
- A demo `Ingress` gets an `ADDRESS` (ALB hostname)
- `curl http://<ALB_DNS>/` returns a 200 and the demo response

---

## Prerequisites

- EKS cluster exists and `kubectl get nodes` works
- Terraform applied for dev (`infra/environments/dev`)
- Helm is installed
- AWS SSO profile works (`AWS_PROFILE=dev`)

Recommended env defaults:

```bash
export AWS_PROFILE=dev
export AWS_REGION=eu-west-3
export TF_DIR=infra/environments/dev
export AWS_PAGER=""
````

---

## Install

### 1) Ensure the IAM role output exists (Terraform)

Your install script expects this Terraform output:

* `aws_load_balancer_controller_role_arn`

Confirm outputs:

```bash
terraform -chdir="$TF_DIR" output
```

If the output is missing, apply Terraform after adding the role/policy resources:

```bash
terraform -chdir="$TF_DIR" fmt
terraform -chdir="$TF_DIR" validate
terraform -chdir="$TF_DIR" apply
```

### 2) Install the controller (script)

This repository installs the controller via script so it’s reproducible after destroy/rebuild:

```bash
chmod +x scripts/install-alb-controller.sh
./scripts/install-alb-controller.sh
```

Expected: script ends with the controller deployed and ready.

---

## Verify

### 1) Controller health

```bash
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=180s
kubectl -n kube-system get pods | grep aws-load-balancer-controller
```

### 2) Deploy the demo app + Ingress

If you have the demo manifest:

```bash
kubectl apply -f platform/demos/alb-demo.yaml
```

Wait for ALB hostname:

```bash
kubectl -n demo-ingress get ingress web -w
```

When `ADDRESS` appears, fetch it:

```bash
ALB_DNS="$(kubectl -n demo-ingress get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "$ALB_DNS"
curl -i "http://$ALB_DNS/"
```

Expected response includes something like:

* `hello-from-alb`

### 3) Quick diagnosis if ALB does not appear

Check controller logs:

```bash
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=120
```

Describe the Ingress events:

```bash
kubectl -n demo-ingress describe ingress web | tail -n 120
```

---

## Teardown (IMPORTANT order)

The ALB and target groups are created by the controller in AWS.
To avoid orphan AWS resources, delete the Ingress/app **before** destroying the cluster.

### 1) Remove demo resources (triggers ALB cleanup)

```bash
kubectl delete ns demo-ingress --ignore-not-found=true
```

Wait a bit and confirm nothing remains:

```bash
kubectl get ingress -A | grep demo-ingress || true
kubectl get svc -A | grep demo-ingress || true
```

### 2) Optional: uninstall the controller (if you want a clean cluster before destroy)

```bash
helm uninstall aws-load-balancer-controller -n kube-system || true
```

(If you always destroy the whole cluster right after, this is optional — but uninstalling first reduces the chance of AWS leftovers.)
