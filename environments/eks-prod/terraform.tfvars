# AWS Configuration
aws_region = "us-east-1"

# Application Configuration
app_name    = "NotesApp"
environment = "prod"

# Network Configuration
vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]

# EKS Cluster Configuration
cluster_name        = "notes-cluster"
cluster_version     = "1.32"
node_instance_types = ["t3.small"]
node_desired_size   = 3
node_min_size       = 2
node_max_size       = 6
node_disk_size      = 50

# Application Configuration
api_image_tag   = "latest"
worker_image_tag = "latest"
api_replicas    = 3
worker_replicas = 2
domain_name     = "notes.example.com"

# Database Configuration
dynamodb_table_name = "Notes"

# Monitoring Configuration
# Set your email to receive alarm notifications
alert_email = ""
