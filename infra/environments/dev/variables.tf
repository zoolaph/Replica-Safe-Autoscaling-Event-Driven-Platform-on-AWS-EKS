variable "name" {
  description = "Base name for resources"
  type        = string
  default     = "replicasafe-dev"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-3"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "node_instance_types" {
  description = "Instance types for the managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired" {
  description = "Desired node count"
  type        = number
  default     = 1
}

variable "node_min" {
  description = "Min node count"
  type        = number
  default     = 1
}

variable "node_max" {
  description = "Max node count"
  type        = number
  default     = 2
}

variable "cluster_public_access_cidrs" {
  description = "Who can reach the EKS API from the internet (dev default is open; tighten later)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}