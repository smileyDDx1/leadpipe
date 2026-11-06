output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "URL of the Kubernetes API server."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_security_group_id" {
  description = "Security group EKS attaches to the managed nodes and their pods."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
