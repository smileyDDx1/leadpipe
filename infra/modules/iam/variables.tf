variable "project" {
  description = "Prefix for role names. Must match what the GitHub workflows expect."
  type        = string
}

variable "github_repository" {
  description = "The repository allowed to assume these roles, as owner/name."
  type        = string
}

variable "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider created by infra/bootstrap."
  type        = string
}

variable "environments" {
  description = "Deployment environments. Each one is a namespace and a GitHub Environment."
  type        = set(string)
}

variable "ecr_repository_arns" {
  description = "Repositories that GitHub Actions may push to."
  type        = list(string)
}

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "cluster_arn" {
  description = "ARN of the EKS cluster."
  type        = string
}

variable "db_instance_arn" {
  description = "ARN of the DB instance. Deploys read its endpoint and secret ARN from it."
  type        = string
}

variable "db_secret_arn" {
  description = "Secret holding the database master credentials."
  type        = string
}

variable "api_key_secret_arns" {
  description = "API key secret for each environment."
  type        = map(string)
}
