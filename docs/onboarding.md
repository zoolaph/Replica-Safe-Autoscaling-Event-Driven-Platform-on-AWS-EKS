# Onboarding (dev)

This repo is driven by one entrypoint:

```bash
./bin/rsedp --help
````

Defaults:

* AWS_PROFILE=dev
* AWS_DEFAULT_REGION=eu-west-3
* Dev cluster name: replicasafe-dev

## Prereqs

* aws (CLI v2 + SSO)
* terraform
* kubectl
* helm

## Deploy (dev)

```bash
./bin/rsedp aws
./bin/rsedp bootstrap
./bin/rsedp env

./bin/rsedp metrics
./bin/rsedp alb
./bin/rsedp autoscaler
./bin/rsedp sqs

./bin/rsedp check
```

## Destroy

```bash
./bin/rsedp destroy
```

Note: `destroy` does NOT delete the Terraform backend (S3 state bucket + DynamoDB lock table).