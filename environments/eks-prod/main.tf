###############################################################################
# EKS Notes App — Highly Available Deployment on EC2 across 2 AZs
#
# Creates: VPC (public + private subnets × 2 AZs), IGW, 2 × NAT Gateways,
#          EKS Cluster + Managed Node Group (EC2), ALB + NLB, Target Groups,
#          DynamoDB, S3 (assets + frontend), SQS, ECR, CloudFront (frontend),
#          IAM Roles (IRSA for pods, node group, ALB controller),
#          Kubernetes: Deployment, Service, Ingress, HPA, ConfigMap, Secrets
#
# Topology:
#   ┌────────────────────────── VPC 10.0.0.0/16 ──────────────────────────┐
#   │  AZ-a                                      AZ-b                     │
#   │  ┌─────────────────┐  ┌──────────────────┐                         │
#   │  │ Public 10.0.1.0 │  │ Public 10.0.2.0  │  ← ALB, NLB, NAT GW   │
#   │  └────────┬────────┘  └────────┬─────────┘                         │
#   │  ┌────────┴────────┐  ┌────────┴─────────┐                         │
#   │  │Private 10.0.10.0│  │Private 10.0.11.0 │  ← EKS worker nodes    │
#   │  │  notes-api pods  │  │  notes-api pods  │                         │
#   │  │  notes-worker    │  │  notes-worker    │                         │
#   │  │  redis           │  │  redis           │                         │
#   │  └─────────────────┘  └──────────────────┘                         │
#   └─────────────────────────────────────────────────────────────────────┘
#
#   Frontend (S3 + CloudFront) ──→ ALB ──→ K8s Ingress ──→ notes-api pods
#                                   NLB ──→ K8s Service ──→ notes-api pods
###############################################################################

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    # Backend configuration will be provided via backend config file
    # See backend-config-eks-prod.hcl
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
      Cluster     = var.cluster_name
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  azs        = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = {
    Project     = var.app_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Repository  = "notes-infrastructure"
    Cluster     = var.cluster_name
  }
}

###############################################################################
# 1. NETWORKING — VPC, Subnets, IGW, NAT Gateways, Route Tables
###############################################################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name                                       = "${var.app_name}-${var.environment}-VPC"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# --- Internet Gateway ---

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.app_name}-${var.environment}-IGW"
  }
}

# --- Public Subnets (2 AZs) — ALB, NLB, NAT Gateways ---

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                       = "${var.app_name}-${var.environment}-PublicSubnet-${local.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.app_name}-${var.environment}-PublicRT"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- NAT Gateways (one per AZ for HA) ---

resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"

  tags = {
    Name = "${var.app_name}-${var.environment}-NAT-EIP-${local.azs[count.index]}"
  }
}

resource "aws_nat_gateway" "main" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.app_name}-${var.environment}-NAT-${local.azs[count.index]}"
  }

  depends_on = [aws_internet_gateway.main]
}

# --- Private Subnets (2 AZs) — EKS worker nodes ---

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name                                       = "${var.app_name}-${var.environment}-PrivateSubnet-${local.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name = "${var.app_name}-${var.environment}-PrivateRT-${local.azs[count.index]}"
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

###############################################################################
# 2. SECURITY GROUPS
###############################################################################

# --- ALB Security Group ---

resource "aws_security_group" "alb" {
  name        = "${var.app_name}-${var.environment}-ALB-SG"
  description = "Application Load Balancer - HTTP/HTTPS from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-${var.environment}-ALB-SG"
  }
}

# --- EKS Cluster Security Group ---

resource "aws_security_group" "eks_cluster" {
  name        = "${var.app_name}-${var.environment}-EKS-Cluster-SG"
  description = "EKS cluster control plane security group"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-${var.environment}-EKS-Cluster-SG"
  }
}

# --- EKS Node Security Group ---

resource "aws_security_group" "eks_nodes" {
  name        = "${var.app_name}-${var.environment}-EKS-Nodes-SG"
  description = "EKS worker node security group"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name                                       = "${var.app_name}-${var.environment}-EKS-Nodes-SG"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

# Node-to-node communication
resource "aws_security_group_rule" "nodes_internal" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  source_security_group_id = aws_security_group.eks_nodes.id
  security_group_id        = aws_security_group.eks_nodes.id
}

# Control plane → nodes
resource "aws_security_group_rule" "cluster_to_nodes" {
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.eks_cluster.id
  security_group_id        = aws_security_group.eks_nodes.id
}

resource "aws_security_group_rule" "cluster_to_nodes_443" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.eks_cluster.id
  security_group_id        = aws_security_group.eks_nodes.id
}

# Nodes → control plane
resource "aws_security_group_rule" "nodes_to_cluster" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.eks_nodes.id
  security_group_id        = aws_security_group.eks_cluster.id
}

# ALB → EKS nodes (app traffic via NodePort + health checks)
# Targets the EKS-managed cluster SG that nodes actually use
resource "aws_security_group_rule" "alb_to_nodes" {
  type                     = "ingress"
  from_port                = 30080
  to_port                  = 30080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

# NLB health checks (NLB preserves client IP, allow from VPC CIDR)
resource "aws_security_group_rule" "nlb_to_nodes" {
  type              = "ingress"
  from_port         = 30080
  to_port           = 30080
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

# Nodes egress to internet (via NAT)
resource "aws_security_group_rule" "nodes_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.eks_nodes.id
}

###############################################################################
# 3. EKS CLUSTER + MANAGED NODE GROUP
###############################################################################

# --- Cluster IAM Role ---

resource "aws_iam_role" "eks_cluster" {
  name = "${var.app_name}-${var.environment}-EKS-Cluster-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.app_name}-${var.environment}-EKS-Cluster-Role" }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSVPCResourceController"
}

# --- EKS Cluster ---

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions  = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  tags = { Name = var.cluster_name }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
  ]
}

# --- EKS Access Entry: Allow console IAM user to view K8s resources ---

resource "aws_eks_access_entry" "console_admin" {
  count         = var.console_admin_arn != "" ? 1 : 0
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.console_admin_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "console_admin" {
  count         = var.console_admin_arn != "" ? 1 : 0
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.console_admin[0].principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# --- OIDC Provider (for IRSA) ---

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = { Name = "${var.app_name}-${var.environment}-OIDC" }
}

locals {
  oidc_provider_arn = aws_iam_openid_connect_provider.eks.arn
  oidc_issuer       = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# --- Node Group IAM Role ---

resource "aws_iam_role" "eks_nodes" {
  name = "${var.app_name}-${var.environment}-EKS-Node-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.app_name}-${var.environment}-EKS-Node-Role" }
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# --- Managed Node Group (EC2 — spread across 2 AZs) ---

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.app_name}-${var.environment}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private[*].id

  instance_types = var.node_instance_types
  disk_size      = var.node_disk_size

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role        = "worker"
    environment = var.environment
  }

  tags = { Name = "${var.app_name}-${var.environment}-EKS-Node" }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_iam_role_policy_attachment.node_ssm,
  ]
}

# --- Attach EKS nodes to ALB/NLB target groups ---

resource "aws_autoscaling_attachment" "alb" {
  autoscaling_group_name = aws_eks_node_group.main.resources[0].autoscaling_groups[0].name
  lb_target_group_arn    = aws_lb_target_group.api.arn
}

resource "aws_autoscaling_attachment" "nlb" {
  autoscaling_group_name = aws_eks_node_group.main.resources[0].autoscaling_groups[0].name
  lb_target_group_arn    = aws_lb_target_group.nlb_api.arn
}

# --- CloudWatch Log Group for EKS ---

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 7

  tags = { Name = "${var.app_name}-${var.environment}-EKS-Logs" }
}

###############################################################################
# 4. IRSA — IAM Roles for Service Accounts
###############################################################################

# --- notes-api Pod Role ---

resource "aws_iam_role" "notes_api" {
  name = "${var.app_name}-api-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:${var.environment}:notes-api-sa"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { Name = "${var.app_name}-api-${var.environment}" }
}

resource "aws_iam_role_policy" "notes_api" {
  name = "${var.app_name}-api-data-access"
  role = aws_iam_role.notes_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DynamoDB"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:BatchGetItem", "dynamodb:BatchWriteItem"]
        Resource = [aws_dynamodb_table.notes.arn, "${aws_dynamodb_table.notes.arn}/index/*"]
      },
      {
        Sid      = "S3Assets"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.assets.arn, "${aws_s3_bucket.assets.arn}/*"]
      },
    ]
  })
}

# --- notes-worker Pod Role ---

resource "aws_iam_role" "notes_worker" {
  name = "${var.app_name}-worker-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:${var.environment}:notes-worker-sa"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { Name = "${var.app_name}-worker-${var.environment}" }
}

resource "aws_iam_role_policy" "notes_worker" {
  name = "${var.app_name}-worker-data-access"
  role = aws_iam_role.notes_worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DynamoDB"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query", "dynamodb:BatchWriteItem"]
        Resource = [aws_dynamodb_table.notes.arn, "${aws_dynamodb_table.notes.arn}/index/*"]
      },
      {
        Sid      = "S3Assets"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.assets.arn, "${aws_s3_bucket.assets.arn}/*"]
      },
      {
        Sid      = "SQS"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource = aws_sqs_queue.events.arn
      },
    ]
  })
}

# --- ALB Controller Role ---

resource "aws_iam_role" "alb_controller" {
  name = "${var.app_name}-${var.environment}-ALB-Controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { Name = "${var.app_name}-${var.environment}-ALB-Controller" }
}

resource "aws_iam_role_policy" "alb_controller" {
  name = "${var.app_name}-alb-controller-policy"
  role = aws_iam_role.alb_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:Describe*", "elasticloadbalancing:*",
        "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress",
        "ec2:CreateTags", "ec2:DeleteTags",
        "iam:CreateServiceLinkedRole",
        "cognito-idp:DescribeUserPoolClient",
        "acm:ListCertificates", "acm:DescribeCertificate",
        "waf-regional:*", "wafv2:*", "shield:*",
      ]
      Resource = "*"
    }]
  })
}

# --- EBS CSI Driver Role (required for PVC provisioning on EKS 1.23+) ---

resource "aws_iam_role" "ebs_csi" {
  name = "${var.app_name}-${var.environment}-EBS-CSI"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { Name = "${var.app_name}-${var.environment}-EBS-CSI" }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  depends_on = [aws_eks_node_group.main]
}

###############################################################################
# 5. LOAD BALANCERS — ALB + NLB
###############################################################################

# --- Application Load Balancer (internet-facing, 2 AZs) ---

resource "aws_lb" "alb" {
  name               = "${var.app_name}-${var.environment}-ALB"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false
  drop_invalid_header_fields = true

  tags = { Name = "${var.app_name}-${var.environment}-ALB" }
}

resource "aws_lb_target_group" "api" {
  name_prefix = "api-"
  port        = 30080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/health"
    port                = "30080"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.app_name}-${var.environment}-API-TG" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# --- Network Load Balancer (internet-facing, 2 AZs) ---

resource "aws_lb" "nlb" {
  name               = "${var.app_name}-${var.environment}-NLB"
  internal           = false
  load_balancer_type = "network"
  subnets            = aws_subnet.public[*].id

  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = false

  tags = { Name = "${var.app_name}-${var.environment}-NLB" }
}

resource "aws_lb_target_group" "nlb_api" {
  name_prefix = "nlb-"
  port        = 30080
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    protocol            = "HTTP"
    path                = "/health"
    port                = "30080"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.app_name}-${var.environment}-NLB-TG" }
}

resource "aws_lb_listener" "nlb_tcp" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_api.arn
  }
}

###############################################################################
# 6. DATA STORES — DynamoDB, S3 (assets), SQS, ECR
###############################################################################

resource "aws_dynamodb_table" "notes" {
  name         = "${var.dynamodb_table_name}-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userId"
  range_key    = "noteId"

  attribute {
    name = "noteId"
    type = "S"
  }

  attribute {
    name = "userId"
    type = "S"
  }

  attribute {
    name = "updatedAt"
    type = "S"
  }

  global_secondary_index {
    name            = "userId-updatedAt-index"
    hash_key        = "userId"
    range_key       = "updatedAt"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = { Name = "${var.dynamodb_table_name}-${var.environment}" }
}

resource "aws_s3_bucket" "assets" {
  bucket        = "${lower(var.app_name)}-assets-${var.environment}-${local.account_id}"
  force_destroy = true

  tags = { Name = "${var.app_name}-assets-${var.environment}" }
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_sqs_queue" "events" {
  name                       = "${lower(var.app_name)}-events-${var.environment}"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 1209600
  receive_wait_time_seconds  = 20

  tags = { Name = "${var.app_name}-events-${var.environment}" }
}

resource "aws_sqs_queue" "events_dlq" {
  name                      = "${lower(var.app_name)}-events-${var.environment}-dlq"
  message_retention_seconds = 1209600

  tags = { Name = "${var.app_name}-events-${var.environment}-DLQ" }
}

resource "aws_sqs_queue_redrive_policy" "events" {
  queue_url = aws_sqs_queue.events.id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.events_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_ecr_repository" "notes_app" {
  name                 = "${lower(var.app_name)}-app"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration { scan_on_push = true }
  tags = { Name = "${var.app_name}-app" }
}

resource "aws_ecr_repository" "notes_worker" {
  name                 = "${lower(var.app_name)}-worker"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration { scan_on_push = true }
  tags = { Name = "${var.app_name}-worker" }
}

###############################################################################
# 7. FRONTEND — S3 + CloudFront CDN → ALB API origin
###############################################################################

resource "aws_s3_bucket" "frontend" {
  bucket        = "${lower(var.app_name)}-frontend-${var.environment}-${local.account_id}"
  force_destroy = true

  tags = { Name = "${var.app_name}-frontend-${var.environment}" }
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.app_name}-frontend-oac"
  description                       = "OAC for Notes frontend S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn }
      }
    }]
  })
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  comment             = "${var.app_name} frontend - ${var.environment}"
  price_class         = "PriceClass_100"

  # S3 Origin (static assets)
  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # ALB Origin (API backend)
  origin {
    domain_name = aws_lb.alb.dns_name
    origin_id   = "alb-api"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Default: S3 SPA
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
    compress    = true
  }

  # /api/* → ALB backend (no caching)
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb-api"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Origin", "Accept", "Host"]
      cookies { forward = "all" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
    compress    = true
  }

  # /health → ALB backend
  ordered_cache_behavior {
    path_pattern           = "/health"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb-api"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # SPA: route 403/404 to index.html for client-side routing
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${var.app_name}-frontend-CDN" }
}
