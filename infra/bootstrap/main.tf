###############################################
# Bootstrap stack: Terraform remote backend
#
# Creates:
# - S3 bucket for Terraform state (secure, versioned)
# - DynamoDB table for state locking
#
# Design goals:
# - safe by default
# - minimal operational overhead
# - enterprise-standard pattern
###############################################

variable "region" {
  description = "AWS region for backend resources"
  type        = string
  default     = "eu-west-3"
}

variable "project" {
  description = "Project tag"
  type        = string
  default     = "ReplicaSafeEKS"
}

variable "env" {
  description = "Environment tag"
  type        = string
  default     = "dev"
}

variable "lock_table_name" {
  description = "DynamoDB table name used for Terraform state locking"
  type        = string
  default     = "replicasafeeks-tf-lock"
}

variable "state_bucket_name" {
  description = "global unique s3 bucket name used to store Terraform state"
  type        = string
}


locals {
  tags = {
    Project   = "ReplicaSafeEKS"
    Env       = "dev"
    Owner     = "admin-farouq"
    ManagedBy = "Terraform"
    Scope     = "backend"
  }
}

# S3 Terraform state bucket
############################

resource "aws_s3_bucket" "tf_state" {
  bucket = var.state_bucket_name
  tags   = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

# versioning for state bucket
resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

#Encrypt objects at rest by default no MKS overhead for MVP
resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access 
resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#Enforce modern owner enforced bucket policies
resource "aws_s3_bucket_ownership_controls" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Deny HTTP / enforce TLS
resource "aws_s3_bucket_policy" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedConnections"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.tf_state.arn,
          "${aws_s3_bucket.tf_state.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# DynamoDB: state locking
###############################################

resource "aws_dynamodb_table" "tf_lock" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
  tags = local.tags
}