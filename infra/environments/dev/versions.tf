terraform {
  required_version = ">= 1.7.5, < 2.0.0"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.23.0, < 7.0.0"
      # Why: EKS module requires aws >= 6.23, so root must allow that.
    }
  }
}
