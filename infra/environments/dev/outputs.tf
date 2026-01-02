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