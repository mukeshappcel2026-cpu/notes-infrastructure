variable "app_name" {
  description = "Application name"
  type        = string
}

variable "environment" {
  description = "Environment (dev/staging/prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "ec2_instance_private_ip" {
  description = "Private IP of the EC2 instance"
  type        = string
}

variable "ec2_instance_public_ip" {
  description = "Public IP of the EC2 instance"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for VPC Link"
  type        = string
}

variable "app_port" {
  description = "Port the application listens on"
  type        = number
  default     = 3000
}

# ------------------------------------------------------------------
# REST API Gateway (v1) - 1M free calls/month for 12 months
# Routes all traffic directly to EC2 public IP, no ALB needed
# ------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "main" {
  name        = "${var.app_name}-${var.environment}-API"
  description = "API Gateway for ${var.app_name} (${var.environment})"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name        = "${var.app_name}-${var.environment}-API"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Catch-all proxy resource: {proxy+}
resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "{proxy+}"
}

# ANY method on /{proxy+}
resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

# Integration: forward to EC2 public IP
resource "aws_api_gateway_integration" "proxy" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  uri                     = "http://${var.ec2_instance_public_ip}:${var.app_port}/{proxy}"

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }

  timeout_milliseconds = 29000
}

# Root resource (/) - ANY method
resource "aws_api_gateway_method" "root" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_rest_api.main.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "root" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_rest_api.main.root_resource_id
  http_method             = aws_api_gateway_method.root.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  uri                     = "http://${var.ec2_instance_public_ip}:${var.app_port}/"

  timeout_milliseconds = 29000
}

# Deploy the API
resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.proxy.id,
      aws_api_gateway_method.proxy.id,
      aws_api_gateway_integration.proxy.id,
      aws_api_gateway_method.root.id,
      aws_api_gateway_integration.root.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Stage
resource "aws_api_gateway_stage" "main" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = var.environment

  tags = {
    Name        = "${var.app_name}-${var.environment}-Stage"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ------------------------------------------------------------------
# Throttling / Usage Plan - stay within free tier (1M calls/month)
# Default: 100 req/sec burst, 50 req/sec steady
# Monthly quota: 900,000 (safety margin below 1M free tier limit)
# ------------------------------------------------------------------

resource "aws_api_gateway_usage_plan" "main" {
  name        = "${var.app_name}-${var.environment}-UsagePlan"
  description = "Rate limiting to stay within AWS free tier"

  api_stages {
    api_id = aws_api_gateway_rest_api.main.id
    stage  = aws_api_gateway_stage.main.stage_name
  }

  throttle_settings {
    burst_limit = 100
    rate_limit  = 50
  }

  quota_settings {
    limit  = 900000
    period = "MONTH"
  }

  tags = {
    Name        = "${var.app_name}-${var.environment}-UsagePlan"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------

output "api_gateway_url" {
  description = "API Gateway invoke URL"
  value       = aws_api_gateway_stage.main.invoke_url
}

output "api_gateway_id" {
  description = "API Gateway REST API ID"
  value       = aws_api_gateway_rest_api.main.id
}

output "api_gateway_stage_name" {
  description = "API Gateway stage name"
  value       = aws_api_gateway_stage.main.stage_name
}
