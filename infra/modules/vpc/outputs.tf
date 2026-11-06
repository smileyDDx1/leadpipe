output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Subnets for internet-facing load balancers."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Subnets for the nodes and the database."
  value       = aws_subnet.private[*].id
}
