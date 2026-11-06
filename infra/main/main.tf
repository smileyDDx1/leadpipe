# The whole AWS environment, composed from the reusable modules.
#
# Terraform manages AWS resources only. In-cluster components are installed by
# scripts/cluster-bootstrap.sh and scripts/deploy.sh. This keeps pull request plans read-only
# against AWS, and avoids configuring a Kubernetes provider from a cluster this config creates.

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  github_oidc_provider_arn = "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
  terraform_apply_role_arn = "arn:aws:iam::${local.account_id}:role/${var.project}-terraform-apply"

  repository_names = toset(["${var.project}/api", "${var.project}/worker"])
}

module "vpc" {
  source = "../modules/vpc"

  name               = var.project
  cluster_name       = var.project
  cidr_block         = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
}

module "eks" {
  source = "../modules/eks"

  cluster_name        = var.project
  kubernetes_version  = var.kubernetes_version
  subnet_ids          = module.vpc.private_subnet_ids
  public_access_cidrs = var.cluster_public_access_cidrs
  node_instance_types = var.node_instance_types
  node_capacity_type  = var.node_capacity_type
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size

  # The apply role always gets access, because the workflow bootstraps the cluster after apply.
  admin_principal_arns = setunion([local.terraform_apply_role_arn], var.cluster_admin_principal_arns)
}

module "rds" {
  source = "../modules/rds"

  identifier                = var.project
  vpc_id                    = module.vpc.vpc_id
  subnet_ids                = module.vpc.private_subnet_ids
  allowed_security_group_id = module.eks.cluster_security_group_id
  engine_version            = var.db_engine_version
  instance_class            = var.db_instance_class
  allocated_storage_gb      = var.db_allocated_storage_gb
  multi_az                  = var.db_multi_az
}

module "ecr" {
  source = "../modules/ecr"

  repository_names = local.repository_names
}

# Only the empty secret lives here. scripts/cluster-bootstrap.sh generates the value, so it is
# never in Terraform state.
resource "aws_secretsmanager_secret" "api_key" {
  for_each = var.environments

  name        = "${var.project}/${each.key}/api-key"
  description = "API key for the ${each.key} LeadPipe API"
  # Delete at once, so destroy then apply does not collide with a name awaiting deletion.
  recovery_window_in_days = 0
}

module "iam" {
  source = "../modules/iam"

  project                  = var.project
  github_repository        = var.github_repository
  github_oidc_provider_arn = local.github_oidc_provider_arn
  environments             = var.environments
  ecr_repository_arns      = module.ecr.repository_arns
  cluster_name             = module.eks.cluster_name
  cluster_arn              = module.eks.cluster_arn
  db_instance_arn          = module.rds.instance_arn
  db_secret_arn            = module.rds.master_user_secret_arn
  api_key_secret_arns      = { for name, secret in aws_secretsmanager_secret.api_key : name => secret.arn }
}
