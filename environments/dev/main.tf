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

# VPC Module
module "vpc" {
  source = "../../modules/vpc"

  app_name           = var.app_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
}

# Security Group for EC2
resource "aws_security_group" "ec2" {
  name        = "${var.app_name}-${var.environment}-EC2-SG"
  description = "Security group for EC2 instances"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Allow traffic from ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [module.alb.alb_security_group_id]
  }

  ingress {
    description = "Allow SSH (remove in production)"
    from_port   = 22
    to_port     = 22
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

# DynamoDB Module
module "dynamodb" {
  source = "../../modules/dynamodb"

  app_name       = var.app_name
  environment    = var.environment
  table_name     = var.dynamodb_table_name
  read_capacity  = var.dynamodb_read_capacity
  write_capacity = var.dynamodb_write_capacity
}

# S3 Module for Deployments
module "s3_deployment" {
  source = "../../modules/s3"

  app_name    = var.app_name
  environment = var.environment
  bucket_name = var.deployment_bucket_name
}

# User Data Script

# User Data Script

# User Data Script
locals {
  user_data = templatefile("${path.module}/user-data.sh", {
    aws_region     = var.aws_region
    dynamodb_table = module.dynamodb.table_name
    environment    = var.environment
  })
}

# EC2 Module
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

# ALB Module
module "alb" {
  source = "../../modules/alb"

  app_name           = var.app_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.public_subnet_ids
  target_instance_id = module.ec2.instance_id
}
