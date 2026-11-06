output "repository_arns" {
  description = "ARNs of the repositories."
  value       = [for repository in aws_ecr_repository.this : repository.arn]
}

output "repository_urls" {
  description = "Repository URLs, by name."
  value       = { for name, repository in aws_ecr_repository.this : name => repository.repository_url }
}
