# Runs offline against a mocked AWS provider. It creates nothing and needs no credentials.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }
  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::leadpipe-tfstate-123456789012"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }
}

variables {
  github_repository  = "example/leadpipe"
  budget_alert_email = "alerts@example.com"
}

run "state_bucket_is_private_encrypted_and_versioned" {
  command = apply

  assert {
    condition     = aws_s3_bucket.state.bucket == "leadpipe-tfstate-123456789012"
    error_message = "The bucket name must include the account ID, so it is globally unique."
  }
  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "Versioning must be on, so a bad state write can be recovered."
  }
  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.state.block_public_acls,
      aws_s3_bucket_public_access_block.state.block_public_policy,
      aws_s3_bucket_public_access_block.state.ignore_public_acls,
      aws_s3_bucket_public_access_block.state.restrict_public_buckets,
    ])
    error_message = "All public access must be blocked."
  }
  assert {
    condition     = strcontains(aws_s3_bucket_policy.state.policy, "aws:SecureTransport")
    error_message = "The bucket must refuse unencrypted connections."
  }
}

run "github_roles_trust_one_exact_context" {
  command = apply

  assert {
    condition = (
      jsondecode(aws_iam_role.terraform["plan"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"]
      == "repo:example/leadpipe:pull_request"
    )
    error_message = "The plan role must trust only this repository's pull requests."
  }
  assert {
    condition = (
      jsondecode(aws_iam_role.terraform["apply"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"]
      == "repo:example/leadpipe:environment:infrastructure"
    )
    error_message = "The apply role must trust only the approval-gated environment."
  }
  assert {
    condition     = strcontains(aws_iam_role_policy.plan_limits.policy, "NeverReadSecretValues")
    error_message = "The plan role must be explicitly denied secret values."
  }
}

run "budget_alert_goes_to_the_owner" {
  command = apply

  assert {
    condition     = length(aws_budgets_budget.monthly.notification) == 2
    error_message = "The budget needs an actual-spend alert and a forecast alert."
  }
}

run "repository_format_is_validated" {
  command = plan

  variables {
    github_repository = "not-a-repository"
  }

  expect_failures = [var.github_repository]
}
