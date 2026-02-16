# AWS Configuration
aws_region = "us-east-1"

# Application Configuration
app_name    = "NotesApp"
environment = "dev"

# Network Configuration
vpc_cidr = "10.0.0.0/16"

# Compute Configuration
instance_type = "t3.micro"

# Database Configuration
dynamodb_table_name     = "Notes"
dynamodb_read_capacity  = 5
dynamodb_write_capacity = 5

# Deployment Configuration
# IMPORTANT: Replace with a globally unique bucket name
deployment_bucket_name = "notesapp-deployment-mukesh-20260215"

# Monitoring Configuration
# Set your email to receive CloudWatch alarm notifications
# Leave empty to skip email notifications
alert_email = ""
