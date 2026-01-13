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

output "keda_demo_queue_url" { value = aws_sqs_queue.keda_demo.url }
output "keda_demo_queue_arn" { value = aws_sqs_queue.keda_demo.arn }
output "sqs_worker_role_arn" { value = aws_iam_role.sqs_worker.arn }