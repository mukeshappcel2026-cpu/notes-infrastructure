output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "alb_dns_name" {
  description = "Application Load Balancer DNS name"
  value       = module.alb.alb_dns_name
}

output "alb_url" {
  description = "Application Load Balancer URL"
  value       = "http://${module.alb.alb_dns_name}"
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

output "test_commands" {
  description = "Commands to test the deployment"
  value = <<-EOT
    # Health check
    curl http://${module.alb.alb_dns_name}/health
    
    # Create a note
    curl -X POST http://${module.alb.alb_dns_name}/notes \
      -H "Content-Type: application/json" \
      -d '{"userId":"testuser","title":"Test Note","content":"Hello from Terraform!"}'
    
    # Get notes
    curl http://${module.alb.alb_dns_name}/notes/testuser
    
    # SSH into instance (if needed)
    aws ssm start-session --target ${module.ec2.instance_id}
  EOT
}
