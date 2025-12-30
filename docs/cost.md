# Cost Controls (Dev Environment)

This repo provisions AWS infrastructure that can generate ongoing costs.
This document explains what costs money, how to shut everything down, and how to verify nothing is still running.

## What costs money (primary drivers)

### Always-on / hourly
- **EKS control plane**: billed while the cluster exists (even if nodes are 0).
- **NAT Gateway**: hourly + data processing (often the sneaky bill).
- **EC2 worker nodes**: hourly.
- **Load balancers** (ALB/NLB): hourly + usage (later).

### Usage-based / can grow
- **EBS volumes / snapshots**: storage billed.
- **CloudWatch Logs**: ingestion + retention (can surprise you).
- **S3**: storage + requests (state bucket is usually negligible).

## Resource tagging policy (required)
All resources created by Terraform MUST be tagged via provider `default_tags`:

- Project=ReplicaSafeEKS
- Env=dev
- Owner=admin-farouq
- ManagedBy=terraform

Rationale:
- Fast cleanup and filtering
- Cost attribution
- Professional hygiene signal

## OFF switch (end-of-session shutdown)

### Destroy dev environment
From repo root:
```bash
./scripts/destroy-dev.sh
```

## What remains after shutdown (expected)
- Terraform state backend (S3 bucket + dynamoDB lock table) - near-zero cost. Everything else should be destroyed.

## Verification checklist (prove nothing is running)
After destroy, verify in using a cronjob that these are gone:
- EKS cluster ( and node groups)
- VPC created for the project
- NAT Gateway(s)
- EC2 instances 
- load balancers
- EBS volumes created by the cluster (if any)

## Daily discipline checklist 
- Apply only when actively working
- Verfy and capture evidence 
- Destroy at end of session
- Check Billing / Cost Explorer weekly 