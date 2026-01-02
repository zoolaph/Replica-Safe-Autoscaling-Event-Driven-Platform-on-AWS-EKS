terraform {
  required_version = ">= 1.7.5, < 2.0.0"

  # Backend settings are injected via backend.hcl during init
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}