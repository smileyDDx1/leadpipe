variable "repository_names" {
  description = "Repositories to create."
  type        = set(string)
}

variable "images_to_keep" {
  description = "Images kept in each repository before the oldest expire."
  type        = number
  default     = 30
}

variable "force_delete" {
  description = "Allow deleting a repository that still holds images."
  type        = bool
  default     = true
}
