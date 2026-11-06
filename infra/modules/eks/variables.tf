variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version. Check it is still in EKS standard support."
  type        = string
  default     = "1.37"
}

variable "subnet_ids" {
  description = "Private subnets for the control plane network interfaces and the nodes."
  type        = list(string)
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public API endpoint. IAM authentication still applies."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND, or SPOT to save money on a demo cluster."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "Use ON_DEMAND or SPOT."
  }
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

variable "admin_principal_arns" {
  description = "IAM roles and users that get cluster-admin through EKS access entries."
  type        = set(string)
  default     = []
}
