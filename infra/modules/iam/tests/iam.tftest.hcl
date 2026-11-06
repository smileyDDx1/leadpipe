# Runs offline against a mocked AWS provider. It creates nothing and needs no credentials.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/mock"
    }
  }
}

variables {
  project                  = "leadpipe"
  github_repository        = "example/leadpipe"
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  environments             = ["staging", "production"]
  ecr_repository_arns      = ["arn:aws:ecr:ap-south-1:123456789012:repository/leadpipe/api"]
  cluster_name             = "leadpipe"
  cluster_arn              = "arn:aws:eks:ap-south-1:123456789012:cluster/leadpipe"
  db_instance_arn          = "arn:aws:rds:ap-south-1:123456789012:db:leadpipe"
  db_secret_arn            = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:rds-db"
  api_key_secret_arns = {
    staging    = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:staging-key"
    production = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:production-key"
  }
}

run "production_role_only_trusts_the_gated_production_environment" {
  command = apply

  assert {
    condition = (
      jsondecode(aws_iam_role.deploy["production"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"]
      == "repo:example/leadpipe:environment:production"
    )
    error_message = "Only the approval-gated production environment may assume this role."
  }
}

run "only_main_can_publish_images" {
  command = apply

  assert {
    condition = (
      jsondecode(aws_iam_role.ecr_push.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"]
      == "repo:example/leadpipe:ref:refs/heads/main"
    )
    error_message = "Pull requests must not be able to push images."
  }
}

run "staging_cannot_read_the_production_api_key" {
  command = apply

  assert {
    condition     = !strcontains(aws_iam_role_policy.deploy["staging"].policy, "production-key")
    error_message = "The staging role must not reach production's API key."
  }
  assert {
    condition     = strcontains(aws_iam_role_policy.deploy["staging"].policy, "staging-key")
    error_message = "The staging role needs its own API key."
  }
}

run "deploy_roles_are_scoped_to_their_own_namespace" {
  command = apply

  assert {
    condition = alltrue([
      for name, association in aws_eks_access_policy_association.deploy :
      association.access_scope[0].type == "namespace" && tolist(association.access_scope[0].namespaces) == tolist([name])
    ])
    error_message = "Each deploy role must be limited to the namespace of the same name."
  }
}

run "only_the_controller_service_account_gets_load_balancer_rights" {
  command = apply

  assert {
    condition = (
      aws_eks_pod_identity_association.load_balancer_controller.namespace == "kube-system"
      && aws_eks_pod_identity_association.load_balancer_controller.service_account == "aws-load-balancer-controller"
    )
    error_message = "The association must match the service account in scripts/cluster-bootstrap.sh."
  }
}
