# Wires every module together against a mocked AWS provider. It creates nothing and needs no
# credentials. It proves the composition is valid, not that AWS would accept every value.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
    }
  }
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
  mock_resource "aws_eks_cluster" {
    defaults = {
      arn      = "arn:aws:eks:ap-south-1:123456789012:cluster/leadpipe"
      endpoint = "https://mock.eks.amazonaws.com"
      # A nested block, so the mock takes one object per block rather than a list.
      vpc_config = {
        cluster_security_group_id = "sg-cluster"
        vpc_id                    = "vpc-1"
      }
    }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      arn        = "arn:aws:rds:ap-south-1:123456789012:db:leadpipe"
      address    = "leadpipe.example.ap-south-1.rds.amazonaws.com"
      identifier = "leadpipe"
      port       = 5432
      master_user_secret = [{
        kms_key_id    = "arn:aws:kms:ap-south-1:123456789012:key/mock"
        secret_arn    = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:rds!db-mock"
        secret_status = "active"
      }]
    }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:mock"
    }
  }
}

variables {
  github_repository = "example/leadpipe"
}

run "the_whole_environment_composes" {
  command = apply

  assert {
    condition     = output.cluster_endpoint == "https://mock.eks.amazonaws.com"
    error_message = "The root must output the cluster endpoint."
  }
  assert {
    condition     = output.database_host == "leadpipe.example.ap-south-1.rds.amazonaws.com"
    error_message = "The root must output the database host."
  }
  assert {
    condition     = output.image_registry == "123456789012.dkr.ecr.ap-south-1.amazonaws.com"
    error_message = "The registry must match what the deploy workflow builds from its variables."
  }
}

run "each_environment_gets_a_deploy_role_and_an_api_key" {
  command = apply

  assert {
    condition     = toset(keys(output.deploy_role_arns)) == toset(["staging", "production"])
    error_message = "Expected a deploy role for staging and for production."
  }
  assert {
    condition     = aws_secretsmanager_secret.api_key["production"].name == "leadpipe/production/api-key"
    error_message = "The secret name must match what scripts/deploy.sh reads."
  }
}

run "destroy_then_apply_cannot_collide_on_secret_names" {
  command = apply

  assert {
    condition     = alltrue([for secret in aws_secretsmanager_secret.api_key : secret.recovery_window_in_days == 0])
    error_message = "Without a zero recovery window, a rebuild fails on the name still awaiting deletion."
  }
}

run "the_image_repositories_match_the_chart" {
  command = apply

  assert {
    condition     = toset(keys(output.ecr_repository_urls)) == toset(["leadpipe/api", "leadpipe/worker"])
    error_message = "Repository names must match api.repository and worker.repository in the chart."
  }
}
