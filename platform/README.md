# Platform layer

This folder contains Kubernetes “platform add-ons” that make the EKS cluster usable for real workloads
(storage, ingress, autoscaling, observability, backups, etc.).

## Conventions

- Each addon lives in: `platform/addons/<addon-name>/`
- Each addon must have:
  - `README.md` (install / verify / uninstall)
  - `values.yaml` (if Helm is used)
  - `manifests/` (if raw YAML is used)
- Install and verify should be runnable from repo scripts:
  - `bash scripts/platform-install.sh`
  - `bash scripts/platform-verify.sh`

## Environment

Expected environment variables:
- `AWS_PROFILE` (e.g. `dev`)
- `AWS_REGION` (e.g. `eu-west-3`)
- `TF_DIR` (default: `infra/environments/dev`)
- `CLUSTER_NAME` (derived from Terraform output)
