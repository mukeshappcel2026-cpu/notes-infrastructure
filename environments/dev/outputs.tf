output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "api_gateway_url" {
  description = "API Gateway invoke URL (replaces ALB)"
  value       = module.api_gateway.api_gateway_url
}

output "ec2_instance_id" {
  description = "EC2 instance ID"
  value       = module.ec2.instance_id
}

output "ec2_public_ip" {
  description = "EC2 public IP address"
  value       = module.ec2.instance_public_ip
}

output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = module.dynamodb.table_name
}

output "deployment_bucket" {
  description = "S3 deployment bucket name"
  value       = module.s3_deployment.bucket_name
}

output "ecr_repository_url" {
  description = "ECR repository URL for Docker images"
  value       = module.ecr.repository_url
}

output "cloudwatch_sns_topic" {
  description = "SNS topic ARN for alarm notifications"
  value       = module.cloudwatch.sns_topic_arn
}

output "cloudwatch_app_log_group" {
  description = "CloudWatch log group for application logs"
  value       = module.cloudwatch.app_log_group_name
}

output "test_commands" {
  description = "Commands to test the deployment"
  value = <<-EOT
    # Health check via API Gateway
    curl ${module.api_gateway.api_gateway_url}/health

    # Create a note
    curl -X POST ${module.api_gateway.api_gateway_url}/notes \
      -H "Content-Type: application/json" \
      -d '{"userId":"testuser","title":"Test Note","content":"Hello from Terraform!"}'

    # Get notes
    curl ${module.api_gateway.api_gateway_url}/notes/testuser

    # SSH into instance via SSM (no SSH key needed)
    aws ssm start-session --target ${module.ec2.instance_id}
  EOT
}
