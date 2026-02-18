###############################################################################
# Outputs — EKS Notes App HA Deployment
###############################################################################

# --- Networking ---

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, NAT)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (EKS nodes)"
  value       = aws_subnet.private[*].id
}

# --- EKS ---

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_arn" {
  description = "EKS cluster ARN"
  value       = aws_eks_cluster.main.arn
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = aws_iam_openid_connect_provider.eks.arn
}

# --- Load Balancers ---

output "alb_arn" {
  description = "Application Load Balancer ARN"
  value       = aws_lb.alb.arn
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.alb.dns_name
}

output "nlb_arn" {
  description = "Network Load Balancer ARN"
  value       = aws_lb.nlb.arn
}

output "nlb_dns_name" {
  description = "NLB DNS name"
  value       = aws_lb.nlb.dns_name
}

# --- Data Stores ---

output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.notes.name
}

output "s3_assets_bucket" {
  description = "S3 assets bucket name"
  value       = aws_s3_bucket.assets.id
}

output "sqs_queue_url" {
  description = "SQS queue URL"
  value       = aws_sqs_queue.events.url
}

# --- ECR ---

output "ecr_notes_app_url" {
  description = "ECR repository URL for notes-app"
  value       = aws_ecr_repository.notes_app.repository_url
}

output "ecr_notes_worker_url" {
  description = "ECR repository URL for notes-worker"
  value       = aws_ecr_repository.notes_worker.repository_url
}

# --- IAM Roles ---

output "notes_api_role_arn" {
  description = "IAM role ARN for notes-api pods (IRSA)"
  value       = aws_iam_role.notes_api.arn
}

output "notes_worker_role_arn" {
  description = "IAM role ARN for notes-worker pods (IRSA)"
  value       = aws_iam_role.notes_worker.arn
}

output "alb_controller_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller"
  value       = aws_iam_role.alb_controller.arn
}

# --- Frontend ---

output "frontend_bucket" {
  description = "S3 bucket for frontend SPA"
  value       = aws_s3_bucket.frontend.id
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID"
  value       = aws_cloudfront_distribution.frontend.id
}

output "cloudfront_domain_name" {
  description = "CloudFront domain name (access the app here)"
  value       = aws_cloudfront_distribution.frontend.domain_name
}

# --- Convenience ---

output "kubeconfig_command" {
  description = "Run this to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region}"
}

output "frontend_deploy_command" {
  description = "Run this to deploy frontend SPA to S3"
  value       = "aws s3 sync ./dist s3://${aws_s3_bucket.frontend.id} --delete && aws cloudfront create-invalidation --distribution-id ${aws_cloudfront_distribution.frontend.id} --paths '/*'"
}

output "test_commands" {
  description = "Commands to test the deployment"
  value = <<-EOT
    # Configure kubectl
    aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region}

    # Health check via ALB
    curl http://${aws_lb.alb.dns_name}/health

    # Health check via NLB
    curl http://${aws_lb.nlb.dns_name}/health

    # Health check via CloudFront
    curl https://${aws_cloudfront_distribution.frontend.domain_name}/health

    # Create a note via CloudFront
    curl -X POST https://${aws_cloudfront_distribution.frontend.domain_name}/api/notes \
      -H "Content-Type: application/json" \
      -d '{"userId":"testuser","title":"Test Note","content":"Hello from EKS!"}'

    # Check pods
    kubectl get pods -n ${var.environment}

    # Check services
    kubectl get svc -n ${var.environment}

    # Check ingress
    kubectl get ingress -n ${var.environment}

    # Deploy frontend
    aws s3 sync ./dist s3://${aws_s3_bucket.frontend.id} --delete
    aws cloudfront create-invalidation --distribution-id ${aws_cloudfront_distribution.frontend.id} --paths '/*'
  EOT
}
