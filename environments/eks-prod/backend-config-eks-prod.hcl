# S3 backend configuration for EKS prod environment
# Usage: terraform init -backend-config=backend-config-eks-prod.hcl

bucket         = "notesapp-terraform-state"
key            = "eks-prod/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "terraform-locks"
encrypt        = true
