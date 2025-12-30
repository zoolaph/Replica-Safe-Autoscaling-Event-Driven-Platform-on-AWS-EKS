output "state_bucket_name" {
    description = "The name of the S3 bucket used to store Terraform state"
    value       = aws_s3_bucket.tf_state.id
}

output "lock_table_name" {
    description = "The name of the DynamoDB table used for Terraform state locking"
    value       = aws_dynamodb_table.tf_lock.id
}

output "region" {
    description = "The AWS region where backend resources are deployed"
    value       = var.region
}

