# Who may do what:
#   - GitHub Actions gets one role to push images, and one role per environment to deploy.
#   - The AWS Load Balancer Controller gets its permissions through EKS Pod Identity.
# No long-lived AWS keys exist anywhere in this design.

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
  oidc_host = "token.actions.githubusercontent.com"
}

# ---- GitHub Actions: push images ----

resource "aws_iam_role" "ecr_push" {
  name = "${var.project}-gha-ecr-push"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.github_oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          # Only the main branch can publish images. Pull requests cannot.
          "${local.oidc_host}:sub" = "repo:${var.github_repository}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ecr_push" {
  name = "push-images"
  role = aws_iam_role.ecr_push.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # This action does not support resource-level restrictions.
        Sid      = "RegistryLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PushToLeadPipeRepositories"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = var.ecr_repository_arns
      },
    ]
  })
}

# ---- GitHub Actions: deploy, one role per environment ----

resource "aws_iam_role" "deploy" {
  for_each = var.environments

  name = "${var.project}-gha-deploy-${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.github_oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          # A job only receives this subject after passing that GitHub Environment's gate.
          "${local.oidc_host}:sub" = "repo:${var.github_repository}:environment:${each.key}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "deploy" {
  for_each = var.environments

  name = "deploy"
  role = aws_iam_role.deploy[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConnectToCluster"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = var.cluster_arn
      },
      {
        Sid      = "FindDatabase"
        Effect   = "Allow"
        Action   = "rds:DescribeDBInstances"
        Resource = var.db_instance_arn
      },
      {
        Sid    = "ReadThisEnvironmentsSecrets"
        Effect = "Allow"
        Action = "secretsmanager:GetSecretValue"
        Resource = [
          var.db_secret_arn,
          var.api_key_secret_arns[each.key],
        ]
      },
    ]
  })
}

resource "aws_eks_access_entry" "deploy" {
  for_each = var.environments

  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.deploy[each.key].arn
}

# Edit rights in its own namespace only. Staging's role cannot touch production.
resource "aws_eks_access_policy_association" "deploy" {
  for_each = var.environments

  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.deploy[each.key].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = [each.key]
  }

  depends_on = [aws_eks_access_entry.deploy]
}

# ---- AWS Load Balancer Controller: pod-level permissions through EKS Pod Identity ----

resource "aws_iam_policy" "load_balancer_controller" {
  name = "${var.project}-aws-load-balancer-controller"
  # The upstream policy for controller v3.6.2, from the project's docs/install/iam_policy.json.
  policy = file("${path.module}/policies/aws-load-balancer-controller.json")
}

resource "aws_iam_role" "load_balancer_controller" {
  name = "${var.project}-aws-load-balancer-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Principal = { Service = "pods.eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

resource "aws_eks_pod_identity_association" "load_balancer_controller" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.load_balancer_controller.arn
}
