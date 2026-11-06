variable "region" {
  description = "AWS region for the state bucket and all provider calls."
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Prefix for resource names."
  type        = string
  default     = "leadpipe"
}

variable "github_repository" {
  description = "The repository allowed to assume the Terraform roles, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "Use the form owner/name."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly cost limit that the budget alert watches."
  type        = string
  default     = "40"
}

variable "budget_alert_email" {
  description = "Email address that receives budget alerts."
  type        = string
}
