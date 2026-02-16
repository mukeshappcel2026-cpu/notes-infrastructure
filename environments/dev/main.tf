terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # Backend configuration will be provided via backend config file
    # See backend-config-dev.hcl
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.app_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Repository  = "notes-infrastructure"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ------------------------------------------------------------------
# VPC Module
# EC2 is deployed in public subnets (no NAT needed)
# ------------------------------------------------------------------
module "vpc" {
  source = "../../modules/vpc"

  app_name           = var.app_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
}

# ------------------------------------------------------------------
# Security Group for EC2
# Removed: ALB SG reference. Now accepts traffic directly on port 3000.
# SSH removed (use SSM Session Manager instead).
# ------------------------------------------------------------------
resource "aws_security_group" "ec2" {
  name        = "${var.app_name}-${var.environment}-EC2-SG"
  description = "Security group for EC2 instances"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow app traffic from anywhere (API Gateway forwards here)"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-${var.environment}-EC2-SG"
  }
}

# ------------------------------------------------------------------
# DynamoDB Module
# ------------------------------------------------------------------
module "dynamodb" {
  source = "../../modules/dynamodb"

  app_name       = var.app_name
  environment    = var.environment
  table_name     = var.dynamodb_table_name
  read_capacity  = var.dynamodb_read_capacity
  write_capacity = var.dynamodb_write_capacity
}

# ------------------------------------------------------------------
# S3 Module for Deployment Artifacts
# ------------------------------------------------------------------
module "s3_deployment" {
  source = "../../modules/s3"

  app_name    = var.app_name
  environment = var.environment
  bucket_name = var.deployment_bucket_name
}

# ------------------------------------------------------------------
# ECR Module - container registry managed as IaC
# ------------------------------------------------------------------
module "ecr" {
  source = "../../modules/ecr"

  app_name              = var.app_name
  environment           = var.environment
  image_retention_count = 5
}

# ------------------------------------------------------------------
# User Data Script
# Log group names are computed here (not from cloudwatch module)
# to avoid circular dependency: user_data -> cloudwatch -> ec2 -> user_data
# ------------------------------------------------------------------
locals {
  app_log_group_name    = "/${var.app_name}/${var.environment}/application"
  system_log_group_name = "/${var.app_name}/${var.environment}/system"

  user_data = templatefile("${path.module}/user-data.sh", {
    aws_region     = var.aws_region
    dynamodb_table = module.dynamodb.table_name
    environment    = var.environment
    log_group_app  = local.app_log_group_name
    log_group_sys  = local.system_log_group_name
  })
}

# ------------------------------------------------------------------
# EC2 Module - deployed in public subnet (no NAT instance needed)
# ------------------------------------------------------------------
module "ec2" {
  source = "../../modules/ec2"

  app_name           = var.app_name
  environment        = var.environment
  instance_type      = var.instance_type
  subnet_id          = module.vpc.public_subnet_ids[0]
  security_group_id  = aws_security_group.ec2.id
  dynamodb_table_arn = module.dynamodb.table_arn
  user_data          = local.user_data
}

# ------------------------------------------------------------------
# API Gateway Module (replaces ALB - 1M free calls/month)
# ------------------------------------------------------------------
module "api_gateway" {
  source = "../../modules/api_gateway"

  app_name                = var.app_name
  environment             = var.environment
  aws_region              = var.aws_region
  ec2_instance_private_ip = module.ec2.instance_private_ip
  ec2_instance_public_ip  = module.ec2.instance_public_ip
  vpc_id                  = module.vpc.vpc_id
  app_port                = 3000
}

# ------------------------------------------------------------------
# CloudWatch Module - monitoring, alarms, logging (all free tier)
# ------------------------------------------------------------------
module "cloudwatch" {
  source = "../../modules/cloudwatch"

  app_name        = var.app_name
  environment     = var.environment
  ec2_instance_id = module.ec2.instance_id
  aws_region      = var.aws_region
  sns_email       = var.alert_email
}
