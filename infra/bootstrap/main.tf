# Run this once, by hand, before anything else. It creates what the other configs depend on:
# the budget alert, the state bucket, and the roles GitHub Actions uses to run Terraform.
#
# It keeps its own state locally, because the bucket for remote state does not exist yet.
# `terraform destroy` in infra/main never touches any of this.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
  oidc_host   = "token.actions.githubusercontent.com"
}

# ---- Cost guard: the first thing to exist ----

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}

# ---- Remote state ----

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---- GitHub OIDC: no long-lived AWS keys are stored in GitHub ----

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  # Each role trusts one exact GitHub context, so a workflow elsewhere cannot assume it.
  terraform_roles = {
    plan  = "repo:${var.github_repository}:pull_request"
    apply = "repo:${var.github_repository}:environment:infrastructure"
  }
}

resource "aws_iam_role" "terraform" {
  for_each = local.terraform_roles

  name = "${var.project}-terraform-${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = each.value
        }
      }
    }]
  })
}

# Plan runs on pull requests, so it can read the account's configuration and nothing more.
resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.terraform["plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_limits" {
  name = "state-lock-and-secret-limits"
  role = aws_iam_role.terraform["plan"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StateLockFile"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.state.arn}/*.tflock"
      },
      {
        # An explicit deny, so a pull request can never read a secret value.
        Sid      = "NeverReadSecretValues"
        Effect   = "Deny"
        Action   = "secretsmanager:GetSecretValue"
        Resource = "*"
      },
    ]
  })
}

# Apply creates IAM roles, a VPC, a cluster and a database, so it needs broad rights. They are
# only reachable through the `infrastructure` GitHub Environment, which has an approval gate.
resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.terraform["apply"].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
