locals {
  fluentbit_namespace      = "logging"
  fluentbit_sa_name        = "aws-for-fluent-bit"
  fluentbit_irsa_role_name = "rsedp-${var.env_name}-fluentbit-cloudwatch"
}

data "aws_iam_policy_document" "fluentbit_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider, "https://", "")}:sub"
      values   = ["system:serviceaccount:${local.fluentbit_namespace}:${local.fluentbit_sa_name}"]
    }
  }
}

resource "aws_iam_role" "fluentbit_cloudwatch" {
  name               = local.fluentbit_irsa_role_name
  assume_role_policy = data.aws_iam_policy_document.fluentbit_assume_role.json
}

data "aws_iam_policy_document" "fluentbit_cloudwatch" {
  statement {
    sid    = "CloudWatchLogsWrite"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "logs:DescribeLogGroups"
    ]

    resources = [
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${module.eks.cluster_name}/*",
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${module.eks.cluster_name}/*:*"
    ]
  }
}

resource "aws_iam_policy" "fluentbit_cloudwatch" {
  name   = "rsedp-${var.env_name}-fluentbit-cloudwatch"
  policy = data.aws_iam_policy_document.fluentbit_cloudwatch.json
}

resource "aws_iam_role_policy_attachment" "fluentbit_cloudwatch" {
  role       = aws_iam_role.fluentbit_cloudwatch.name
  policy_arn = aws_iam_policy.fluentbit_cloudwatch.arn
}

output "logging_cloudwatch_irsa_role_arn" {
  value       = aws_iam_role.fluentbit_cloudwatch.arn
  description = "IRSA role ARN for Fluent Bit to write to CloudWatch Logs"
}
