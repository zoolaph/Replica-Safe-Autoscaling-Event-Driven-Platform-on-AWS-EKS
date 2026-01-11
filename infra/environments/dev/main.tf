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

  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

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
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.1"


  name = var.name
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_dns_support   = true
  enable_dns_hostnames = true

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
  tags = local.common_tags
}


# 1) EKS
################################################


module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.10.1"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.cluster_public_access_cidrs

  enable_cluster_creator_admin_permissions = true

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  addons = {
    vpc-cni = {
      before_compute = true
    }
    coredns    = {}
    kube-proxy = {}

    eks-pod-identity-agent = {
      before_compute = true
    }
  }
  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD" # modern default; module docs mention AL2023 defaults. :contentReference[oaicite:10]{index=10}
      instance_types = var.node_instance_types

      min_size     = var.node_min
      max_size     = var.node_max
      desired_size = var.node_desired
      autoscaling_group_tags = {
        "k8s.io/cluster-autoscaler/enabled"                 = "true"
        "k8s.io/cluster-autoscaler/${local.cluster_name}"   = "owned"
      }
    }
  }

  tags = local.common_tags
}
