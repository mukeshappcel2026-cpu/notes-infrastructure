variable "app_name" {
  description = "Application name"
  type        = string
}

variable "environment" {
  description = "Environment (dev/staging/prod)"
  type        = string
}

variable "image_retention_count" {
  description = "Number of images to keep in the repository"
  type        = number
  default     = 5
}

# ------------------------------------------------------------------
# ECR Repository - managed via Terraform (free tier: 500MB storage)
# ------------------------------------------------------------------

resource "aws_ecr_repository" "app" {
  name                 = lower("${var.app_name}-${var.environment}")
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name        = "${var.app_name}-${var.environment}-ECR"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Lifecycle policy: keep only the latest N images to stay within free tier storage
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last ${var.image_retention_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.image_retention_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# ------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------

output "repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.app.repository_url
}

output "repository_arn" {
  description = "ECR repository ARN"
  value       = aws_ecr_repository.app.arn
}

output "repository_name" {
  description = "ECR repository name"
  value       = aws_ecr_repository.app.name
}

output "registry_id" {
  description = "ECR registry ID"
  value       = aws_ecr_repository.app.registry_id
}
