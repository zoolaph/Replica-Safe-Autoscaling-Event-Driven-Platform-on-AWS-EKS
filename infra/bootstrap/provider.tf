provider "aws" {
  region = "eu-west-3"

  default_tags {
    tags = {
      Project   = "ReplicaSafeEKS"
      Env       = "dev"
      Owner     = "admin-farouq"
      ManagedBy = "Terraform"
      Scope     = "backend"
    }
  }
}
