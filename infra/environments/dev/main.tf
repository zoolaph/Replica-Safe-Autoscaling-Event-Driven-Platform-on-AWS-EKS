###############################################
# EKS baseline (private nodes + 1 NAT)
#
# 1) VPC (network foundation)
# 2) EKS control plane (cluster brain)
# 3) Managed node group (workers)
# 4) Core add-ons (networking + DNS)
#
###############################################

data "aws_availability_zones" "available" {
    state = "available"
}

locals {
    azs = slice(data.aws_availability_zones.available.names, 0, 2) 

    cluster_name = var.name

    public_subnets = ["10.0.101.0/24", "10.0.102.0/24" ]
    private_subnets = ["10.0.1.0/24", "10.0.2.0/24" ]

    common_tags = {
        Project   = "ReplicaSafeEKS"
        Env       = "dev"
        Owner     = "admin-farouq"
        ManagedBy = "Terraform"      
    }

}



# 1) VPC 
################################################

module "vpc" {
    source = "terraform--aws-modules/vpc/aws"
    version = "6.5.1"   

    name = var.name 
    cidr = var.vpc_cidr

    azs            = local.azs
    public_subnets  = local.public_subnets
    private_subnets = local.private_subnets

    enable_dns_support = true
    enable_dns_hostnames = true 

    enable_nat_gateway = true
    single_nat_gateway = true

    public_subnets_tags = {
        "kubernetes.io/cluster/${local.cluster_name}" = "shared"
        "kubernetes.io/role/elb" = "1"
    }

    private_subnets_tags = {
        "kubernetes.io/cluster/${local.cluster_name}" = "shared"
        "kubernetes.io/role/internal-elb" = "1"
    }
    tags = local.common_tags
}