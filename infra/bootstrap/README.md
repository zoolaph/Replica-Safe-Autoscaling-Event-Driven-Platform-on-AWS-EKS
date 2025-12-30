# Terraform backend bootstrap (S3 + DynamoDB)

This Terraform root module creates the remote backend used by the rest of the repo:

- **S3 bucket** for Terraform state
  - versioning enabled (rollback safety)
  - encryption at rest (SSE-S3)
  - public access blocked
  - TLS-only bucket policy (deny insecure transport)
  - `prevent_destroy = true` (protects the state bucket from accidental deletion)

- **DynamoDB table** for Terraform state locking
  - `PAY_PER_REQUEST` billing mode (simple)
  - point-in-time recovery enabled

## Why a separate `bootstrap` stack?

Terraform can only use a remote backend **after** it exists.

So we create the backend first using a small independent Terraform stack (`infra/bootstrap`) with its own state.

This prevents a common failure mode:
- destroying the `dev` environment accidentally deleting the backend

## Apply

Set your AWS environment (SSO profile + region):

```bash
export AWS_PROFILE=dev
export AWS_REGION=eu-west-3
export AWS_DEFAULT_REGION=eu-west-3
