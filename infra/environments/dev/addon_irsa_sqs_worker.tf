#############################################
# IRSA role for the SQS worker (default/sqs-worker)
#############################################

data "aws_iam_openid_connect_provider" "eks" {
  arn = module.eks.oidc_provider_arn
}

locals {
  oidc_issuer = replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")

  sqs_worker_namespace       = "default"
  sqs_worker_service_account = "sqs-worker"
  sqs_worker_subject         = "system:serviceaccount:${local.sqs_worker_namespace}:${local.sqs_worker_service_account}"
}

resource "aws_iam_policy" "sqs_worker" {
  name = "replicasafe-dev-sqs-worker"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = [
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility"
      ],
      Resource = aws_sqs_queue.keda_demo.arn
    }]
  })
}

resource "aws_iam_role" "sqs_worker" {
  name = "replicasafe-dev-sqs-worker"

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
          "${local.oidc_issuer}:sub" = local.sqs_worker_subject
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sqs_worker" {
  role       = aws_iam_role.sqs_worker.name
  policy_arn = aws_iam_policy.sqs_worker.arn
}
