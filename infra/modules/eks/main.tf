# EKS control plane, one managed node group, and the add-ons the cluster needs to work.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }
}

locals {
  eks_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
  ec2_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  node_policies = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ])
  # These run as DaemonSets and must exist before nodes can become Ready.
  addons_before_nodes = toset(["vpc-cni", "kube-proxy", "eks-pod-identity-agent"])
  # These are Deployments, so they only become healthy once nodes exist.
  addons_after_nodes = toset(["coredns", "metrics-server"])
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-eks-cluster"
  assume_role_policy = local.eks_trust
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  # The add-ons below are managed by EKS instead of being installed unmanaged at creation.
  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode = "API"
    # Access is declared in code through access entries, rather than depending on who ran apply.
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    # GitHub-hosted runners have no fixed IP, so the endpoint stays public behind IAM auth.
    endpoint_public_access = true
    public_access_cidrs    = var.public_access_cidrs
  }

  # Extended support costs several times more per hour, so never slide into it unnoticed.
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_eks_addon" "before_nodes" {
  for_each = local.addons_before_nodes

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-eks-node"
  assume_role_policy = local.ec2_trust
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = local.node_policies

  role       = aws_iam_role.node.name
  policy_arn = each.key
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  version         = var.kubernetes_version
  instance_types  = var.node_instance_types
  capacity_type   = var.node_capacity_type

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  lifecycle {
    # Left free so a cluster autoscaler could change it without Terraform undoing the change.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.before_nodes,
  ]
}

resource "aws_eks_addon" "after_nodes" {
  for_each = local.addons_after_nodes

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.default]
}

resource "aws_eks_access_entry" "admin" {
  for_each = var.admin_principal_arns

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.key
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = var.admin_principal_arns

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.key
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
