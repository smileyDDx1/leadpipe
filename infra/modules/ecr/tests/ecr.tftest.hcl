# Runs offline against a mocked AWS provider. It creates nothing and needs no credentials.

mock_provider "aws" {}

variables {
  repository_names = ["leadpipe/api", "leadpipe/worker"]
}

run "tags_are_immutable_and_images_are_scanned" {
  command = apply

  assert {
    condition     = alltrue([for repository in aws_ecr_repository.this : repository.image_tag_mutability == "IMMUTABLE"])
    error_message = "A commit SHA tag must never be overwritten."
  }
  assert {
    condition     = alltrue([for repository in aws_ecr_repository.this : repository.image_scanning_configuration[0].scan_on_push])
    error_message = "ECR must scan every pushed image."
  }
}

run "old_images_expire_but_rollback_targets_remain" {
  command = apply

  assert {
    condition = alltrue([
      for policy in aws_ecr_lifecycle_policy.this :
      jsondecode(policy.policy).rules[0].selection.countNumber == 30
    ])
    error_message = "Keep 30 images, so storage stays bounded and rollbacks stay possible."
  }
}
