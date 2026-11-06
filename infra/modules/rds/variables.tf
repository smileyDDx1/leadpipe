variable "identifier" {
  description = "Name of the DB instance."
  type        = string
}

variable "vpc_id" {
  description = "VPC for the database security group."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the DB subnet group."
  type        = list(string)
}

variable "allowed_security_group_id" {
  description = "The only security group allowed to reach PostgreSQL."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL major version. Matches the local Compose and kind stacks."
  type        = string
  default     = "16"
}

variable "instance_class" {
  description = "RDS instance size."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage_gb" {
  description = "Storage size in GB."
  type        = number
  default     = 20
}

variable "master_username" {
  description = "Master user name. RDS generates the password."
  type        = string
  default     = "leadpipe"
}

variable "multi_az" {
  description = "Run a standby in a second zone. Doubles the cost."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Days of automated backups to keep."
  type        = number
  default     = 1
}

variable "deletion_protection" {
  description = "Refuse deletion. Keep this off for the destroy and rebuild demo."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the snapshot on deletion. Keep this on for the destroy and rebuild demo."
  type        = bool
  default     = true
}

variable "password_rotation_days" {
  description = "Days between master password rotations. Redeploy after each one."
  type        = number
  default     = 365
}
