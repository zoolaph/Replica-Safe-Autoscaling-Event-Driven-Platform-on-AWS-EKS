output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "vpc_id" {
  description = "VPC id"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private subnet ids (where nodes live)"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "Public subnet ids (where NAT lives)"
  value       = module.vpc.public_subnets
}

output "cluster_autoscaler_role_arn" {
  value = aws_iam_role.cluster_autoscaler.arn
}

output "region" {
  value = var.region
}
