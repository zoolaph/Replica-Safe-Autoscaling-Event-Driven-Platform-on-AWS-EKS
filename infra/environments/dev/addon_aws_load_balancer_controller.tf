# AWS Load Balancer Controller - IAM policy + IRSA role 
###########################################################

resource "aws_iam_policy" "aws_load_balancer_controller" {
  name   = "${module.eks.cluster_name}-aws-load-balancer-controller-policy"
  policy = file("${path.module}/../../_templates/iam/aws-load-balancer-controller-iam-policy.json")
}

module "irsa_aws_load_balancer_controller" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "~> 5.0"
  role_name = "${module.eks.cluster_name}-aws-load-balancer-controller-role"
  role_policy_arns = {
    lbc = aws_iam_policy.aws_load_balancer_controller.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

output "aws_load_balancer_controller_role_arn" {
  value = module.irsa_aws_load_balancer_controller.iam_role_arn
}

