locals {
  ca_node_group_key = "default"

  ca_asg_name = module.eks.eks_managed_node_groups[local.ca_node_group_key].node_group_resources[0].autoscaling_groups[0].name
}

resource "aws_autoscaling_group_tag" "ca_enabled" {
  autoscaling_group_name = local.ca_asg_name

  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_group_tag" "ca_cluster" {
  autoscaling_group_name = local.ca_asg_name

  tag {
    key                 = "k8s.io/cluster-autoscaler/${local.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }
}