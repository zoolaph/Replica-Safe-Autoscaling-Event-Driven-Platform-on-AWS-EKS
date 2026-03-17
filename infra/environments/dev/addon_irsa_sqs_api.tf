#############################################
# IRSA role for the demo API (demo-app/demo-api)
# Least-privilege: sqs:SendMessage only.
#############################################

locals {
  api_namespace       = "demo-app"
  api_service_account = "demo-api"
  api_subject         = "system:serviceaccount:${local.api_namespace}:${local.api_service_account}"
}

resource "aws_iam_policy" "sqs_api" {
  name = "replicasafe-dev-sqs-api"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = ["sqs:SendMessage"],
      Resource = aws_sqs_queue.keda_demo.arn
    }]
  })
}

resource "aws_iam_role" "sqs_api" {
  name = "replicasafe-dev-sqs-api"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.eks.arn
      },
      Action = "sts:AssumeRoleWithWebIdentity",
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com",
          "${local.oidc_issuer}:sub" = local.api_subject
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sqs_api" {
  role       = aws_iam_role.sqs_api.name
  policy_arn = aws_iam_policy.sqs_api.arn
}
