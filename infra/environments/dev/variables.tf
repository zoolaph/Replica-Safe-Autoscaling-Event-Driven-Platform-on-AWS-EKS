variable "name" {
    description = "Base name for resources"
    type       = string
    default   = "replicasafe-dev"
}

variable "vpc_cidr" {
    description = "VPC CIDR block"
    type       = string
    default   = "10.0.0.0/16"
}

variable "azs"