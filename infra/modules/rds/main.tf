# PostgreSQL in private subnets, reachable only from the cluster's security group.
#
# RDS generates the master password and keeps it in Secrets Manager (manage_master_user_password).
# The password never passes through Terraform, so it is not in the state file or in any plan.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }
}

resource "aws_db_subnet_group" "this" {
  name       = var.identifier
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "this" {
  name        = "${var.identifier}-rds"
  description = "PostgreSQL access from the EKS cluster only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.identifier}-rds" }
}

resource "aws_vpc_security_group_ingress_rule" "from_cluster" {
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = var.allowed_security_group_id
  description                  = "PostgreSQL from EKS nodes and pods"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_instance" "this" {
  identifier     = var.identifier
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage_gb
  storage_type      = "gp3"
  storage_encrypted = true

  username                    = var.master_username
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period    = var.backup_retention_days
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  apply_immediately          = true

  # Variables, so a real production database can turn these protections on. The defaults let
  # the demo run `terraform destroy` and rebuild everything from code.
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.identifier}-final"
}

# RDS rotates this secret every 7 days by default. Pods read the password when they start, so
# rotation has to be followed by a redeploy. A long interval keeps that a planned event.
resource "aws_secretsmanager_secret_rotation" "master" {
  secret_id          = aws_db_instance.this.master_user_secret[0].secret_arn
  rotate_immediately = false

  rotation_rules {
    automatically_after_days = var.password_rotation_days
  }
}
