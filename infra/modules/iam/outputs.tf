output "ecr_push_role_arn" {
  description = "Role that the deploy workflow assumes to push images."
  value       = aws_iam_role.ecr_push.arn
}

output "deploy_role_arns" {
  description = "Role that the deploy workflow assumes for each environment."
  value       = { for name, role in aws_iam_role.deploy : name => role.arn }
}

output "load_balancer_controller_role_arn" {
  description = "Role bound to the controller's service account through Pod Identity."
  value       = aws_iam_role.load_balancer_controller.arn
}
