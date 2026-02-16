#!/bin/bash

# AWS OIDC Setup for GitHub Actions
# This script creates the necessary AWS resources for GitHub Actions to authenticate via OIDC

set -e

echo "========================================"
echo "AWS OIDC Setup for GitHub Actions"
echo "========================================"
echo ""

# Get GitHub username
read -p "Enter your GitHub username (mukeshappcel2026-cpu): " GITHUB_USER
GITHUB_USER=${GITHUB_USER:-mukeshappcel2026-cpu}

# Get AWS Account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account ID: $AWS_ACCOUNT_ID"
echo ""

# Create OIDC Provider (if it doesn't exist)
echo "1. Creating OIDC Provider..."
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  2>/dev/null || echo "OIDC Provider already exists"

echo ""

# Create IAM Role for Application Deployment
echo "2. Creating IAM Role for Application Deployment..."

cat > trust-policy-app.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_USER}/notes-app:*"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name GitHubActions-App-Deploy \
  --assume-role-policy-document file://trust-policy-app.json \
  2>/dev/null || echo "Role already exists"

# Create policy for application deployment
cat > app-deploy-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "elbv2:DescribeLoadBalancers",
        "elbv2:DescribeTargetGroups",
        "elbv2:DescribeTargetHealth",
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
        "ssm:SendCommand",
        "ssm:GetCommandInvocation",
        "ssm:DescribeInstanceInformation",
        "ssm:StartSession"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name GitHubActions-App-Deploy \
  --policy-name AppDeploymentPolicy \
  --policy-document file://app-deploy-policy.json

echo ""

# Create IAM Role for Terraform
echo "3. Creating IAM Role for Terraform..."

cat > trust-policy-terraform.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_USER}/notes-infrastructure:*"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name GitHubActions-Terraform \
  --assume-role-policy-document file://trust-policy-terraform.json \
  2>/dev/null || echo "Role already exists"

# Attach AdministratorAccess for Terraform (or create more restrictive policy)
aws iam attach-role-policy \
  --role-name GitHubActions-Terraform \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

echo ""

# Create S3 bucket for Terraform state
echo "4. Creating S3 bucket for Terraform state..."

STATE_BUCKET="notesapp-terraform-state-${AWS_ACCOUNT_ID}"
aws s3 mb s3://${STATE_BUCKET} --region us-east-1 2>/dev/null || echo "Bucket already exists"

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket ${STATE_BUCKET} \
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket ${STATE_BUCKET} \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Block public access
aws s3api put-public-access-block \
  --bucket ${STATE_BUCKET} \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo ""

# Create DynamoDB table for state locking
echo "5. Creating DynamoDB table for state locking..."

aws dynamodb create-table \
  --table-name terraform-state-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1 \
  2>/dev/null || echo "Table already exists"

echo ""

# Create backend config file
echo "6. Creating Terraform backend config..."

cat > backend-config-dev.hcl << EOF
bucket         = "${STATE_BUCKET}"
key            = "dev/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "terraform-state-locks"
encrypt        = true
EOF

# Cleanup
rm -f trust-policy-app.json app-deploy-policy.json trust-policy-terraform.json

echo ""
echo "========================================"
echo "✅ AWS OIDC Setup Complete!"
echo "========================================"
echo ""
echo "📋 Summary:"
echo ""
echo "OIDC Provider:"
echo "  arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
echo ""
echo "IAM Roles Created:"
echo "  1. GitHubActions-App-Deploy (for notes-app repo)"
echo "     ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/GitHubActions-App-Deploy"
echo ""
echo "  2. GitHubActions-Terraform (for notes-infrastructure repo)"
echo "     ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/GitHubActions-Terraform"
echo ""
echo "Terraform State:"
echo "  S3 Bucket: ${STATE_BUCKET}"
echo "  DynamoDB Table: terraform-state-locks"
echo "  Backend Config: backend-config-dev.hcl"
echo ""
echo "========================================"
echo ""
echo "🔧 Next Steps:"
echo ""
echo "1. Add GitHub Secrets to notes-app repository:"
echo "   AWS_ROLE_ARN=arn:aws:iam::${AWS_ACCOUNT_ID}:role/GitHubActions-App-Deploy"
echo ""
echo "2. Add GitHub Secrets to notes-infrastructure repository:"
echo "   AWS_ROLE_ARN=arn:aws:iam::${AWS_ACCOUNT_ID}:role/GitHubActions-Terraform"
echo ""
echo "3. Add GitHub Variables to notes-app repository:"
echo "   AWS_REGION=us-east-1"
echo "   DEPLOYMENT_BUCKET=<your-deployment-bucket>"
echo ""
echo "4. Initialize Terraform with backend:"
echo "   cd environments/dev"
echo "   terraform init -backend-config=backend-config-dev.hcl"
echo ""
echo "========================================"
