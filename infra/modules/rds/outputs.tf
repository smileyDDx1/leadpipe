output "identifier" {
  description = "Name of the DB instance."
  value       = aws_db_instance.this.identifier
}

output "instance_arn" {
  description = "ARN of the DB instance."
  value       = aws_db_instance.this.arn
}

output "address" {
  description = "Hostname of the database."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Port of the database."
  value       = aws_db_instance.this.port
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret that RDS keeps the master credentials in."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
