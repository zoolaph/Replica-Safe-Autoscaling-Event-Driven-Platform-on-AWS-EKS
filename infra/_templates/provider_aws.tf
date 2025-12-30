terraform {
    required_version = ">= 1.7.5, < 2.0.0"
    required_providers {
        aws = {
            source = "hashicorp/aws"
            version = "~> 5.0"
        }
    }
}

provider "aws" {
    region = "eu-west-3"

    default_tags {
        tags = {
            Project ="ReplicaSafeEKS"
            Env = "dev"
            Owner = "admin-farouq"
            ManagedBy = "Terraform"
        }
    }
}