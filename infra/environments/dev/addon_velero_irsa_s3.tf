data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  velero_namespace = "velero"
  velero_sa_name   = "velero"
  velero_bucket    = lower("rsedp-velero-${var.env_name}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}")
}

resource "aws_s3_bucket" "velero" {
  bucket        = local.velero_bucket
  force_destroy = true # dev only
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket                  = aws_s3_bucket.velero.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "velero" {
  statement {
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject"
    ]
    resources = [
      aws_s3_bucket.velero.arn,
      "${aws_s3_bucket.velero.arn}/*"
    ]
  }

  # keep these for later PV snapshot support
  statement {
    actions = [
      "ec2:CreateSnapshot",
      "ec2:DeleteSnapshot",
      "ec2:DescribeSnapshots",
      "ec2:DescribeVolumes",
      "ec2:CreateTags"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "velero" {
  name   = "rsedp-velero-${var.env_name}"
  policy = data.aws_iam_policy_document.velero.json
}

# Trust policy MUST lock to the velero SA subject
data "aws_iam_policy_document" "velero_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider, "https://", "")}:sub"
      values   = ["system:serviceaccount:${local.velero_namespace}:${local.velero_sa_name}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "velero" {
  name               = "rsedp-velero-${var.env_name}"
  assume_role_policy = data.aws_iam_policy_document.velero_assume.json
}

resource "aws_iam_role_policy_attachment" "velero" {
  role       = aws_iam_role.velero.name
  policy_arn = aws_iam_policy.velero.arn
}

# If your env already manages namespaces/SAs via Terraform, do it here too.
resource "kubernetes_namespace_v1" "velero" {
  metadata { name = local.velero_namespace }
}

resource "kubernetes_service_account" "velero" {
  metadata {
    name      = local.velero_sa_name
    namespace = kubernetes_namespace.velero.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.velero.arn
    }
  }
}

output "velero_bucket_name" { value = aws_s3_bucket.velero.bucket }
output "velero_role_arn"    { value = aws_iam_role.velero.arn }
