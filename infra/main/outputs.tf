output "region" {
  description = "AWS region of the environment."
  value       = var.region
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "URL of the Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "database_host" {
  description = "Hostname of the RDS instance."
  value       = module.rds.address
}

output "ecr_repository_urls" {
  description = "Repository URLs for the images."
  value       = module.ecr.repository_urls
}

output "image_registry" {
  description = "Registry host, passed to scripts/deploy.sh as IMAGE_REGISTRY."
  value       = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_push_role_arn" {
  description = "Role the deploy workflow assumes to push images."
  value       = module.iam.ecr_push_role_arn
}

output "deploy_role_arns" {
  description = "Role the deploy workflow assumes for each environment."
  value       = module.iam.deploy_role_arns
}
