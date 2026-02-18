###############################################################################
# Variables — EKS Notes App HA Deployment
###############################################################################

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "Application name (used in resource naming)"
  type        = string
  default     = "NotesApp"
}

variable "environment" {
  description = "Environment name (prod or dev)"
  type        = string
  default     = "prod"
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

# ---------------------------------------------------------------------------
# EKS Cluster
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "notes-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.30"
}

variable "node_instance_types" {
  description = "EC2 instance types for worker nodes"
  type        = list(string)
  default     = ["t3.small"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 3
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 6
}

variable "node_disk_size" {
  description = "Root disk size for worker nodes (GB)"
  type        = number
  default     = 50
}

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

variable "api_image_tag" {
  description = "Container image tag for notes-api"
  type        = string
  default     = "latest"
}

variable "worker_image_tag" {
  description = "Container image tag for notes-worker"
  type        = string
  default     = "latest"
}

variable "api_replicas" {
  description = "Desired replica count for notes-api"
  type        = number
  default     = 3
}

variable "worker_replicas" {
  description = "Desired replica count for notes-worker"
  type        = number
  default     = 2
}

variable "domain_name" {
  description = "Public domain for the notes app (e.g., notes.example.com)"
  type        = string
  default     = "notes.example.com"
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

variable "dynamodb_table_name" {
  description = "DynamoDB table name"
  type        = string
  default     = "Notes"
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------

variable "alert_email" {
  description = "Email address for alarm notifications (leave empty to skip)"
  type        = string
  default     = ""
}
