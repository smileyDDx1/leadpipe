variable "name" {
  description = "Name prefix for the network resources."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name, used in the subnet discovery tags."
  type        = string
}

variable "cidr_block" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones. EKS and RDS subnet groups both need at least 2."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 8
    error_message = "Use between 2 and 8 availability zones."
  }
}

variable "single_nat_gateway" {
  description = "Share one NAT gateway across zones. Cheaper, but one zone failure cuts outbound traffic."
  type        = bool
  default     = true
}
