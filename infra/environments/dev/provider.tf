provider "aws" {
  region = "eu-west-3"

    default_tags {
        tags = {
        Project   = "ReplicaSafeEKS"
        Env       = "main"
        Owner     = "admin-farouq"
        ManagedBy = "Terraform"      
        }
    }
}   
