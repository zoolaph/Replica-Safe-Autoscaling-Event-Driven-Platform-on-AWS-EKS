resource "aws_sqs_queue" "keda_demo" {
  name = "replicasafe-dev-keda-demo"
}

output "keda_demo_queue_url" {
  value = aws_sqs_queue.keda_demo.url
}

output "keda_demo_queue_arn" {
  value = aws_sqs_queue.keda_demo.arn
}
