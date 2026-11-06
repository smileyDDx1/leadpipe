variable "region" {
  description = "AWS region for the environment."
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Prefix for resource names. The GitHub workflows and scripts assume leadpipe."
  type        = string
  default     = "leadpipe"
}

variable "github_repository" {
  description = "The repository allowed to deploy, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "Use the form owner/name."
  }
}

variable "environments" {
  description = "Deployment environments. Each one is a namespace and a GitHub Environment."
  type        = set(string)
  default     = ["staging", "production"]
}

variable "cluster_admin_principal_arns" {
  description = "Extra IAM users or roles to make cluster admins, such as your own for kubectl."
  type        = set(string)
  default     = []
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones."
  type        = number
  default     = 2
}

variable "single_nat_gateway" {
  description = "Share one NAT gateway across zones to save money."
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  description = "Kubernetes minor version. Matches the node image of the local kind cluster."
  type        = string
  default     = "1.37"
}

variable "cluster_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the cluster API. GitHub-hosted runners need it open."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "EC2 instance types for the nodes."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND, or SPOT to save money on a demo."
  type        = string
  default     = "ON_DEMAND"
}

variable "node_desired_size" {
  description = "Initial number of nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of nodes."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of nodes."
  type        = number
  default     = 3
}

variable "db_engine_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "RDS instance size."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage_gb" {
  description = "Database storage in GB."
  type        = number
  default     = 20
}

variable "db_multi_az" {
  description = "Run a database standby in a second zone. Doubles the database cost."
  type        = bool
  default     = false
}
