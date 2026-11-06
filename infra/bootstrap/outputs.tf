output "state_bucket" {
  description = "Pass this to `terraform init -backend-config` in infra/main."
  value       = aws_s3_bucket.state.bucket
}

output "terraform_plan_role_arn" {
  description = "Assumed by pull request workflows."
  value       = aws_iam_role.terraform["plan"].arn
}

output "terraform_apply_role_arn" {
  description = "Assumed by the approval-gated apply workflow."
  value       = aws_iam_role.terraform["apply"].arn
}

output "github_oidc_provider_arn" {
  description = "The account's GitHub OIDC identity provider."
  value       = aws_iam_openid_connect_provider.github.arn
}
