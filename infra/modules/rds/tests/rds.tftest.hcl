# Runs offline against a mocked AWS provider. It creates nothing and needs no credentials.

mock_provider "aws" {
  mock_resource "aws_db_instance" {
    defaults = {
      arn     = "arn:aws:rds:ap-south-1:123456789012:db:leadpipe"
      address = "leadpipe.example.ap-south-1.rds.amazonaws.com"
      port    = 5432
      master_user_secret = [{
        kms_key_id    = "arn:aws:kms:ap-south-1:123456789012:key/mock"
        secret_arn    = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:rds!db-mock"
        secret_status = "active"
      }]
    }
  }
}

variables {
  identifier                = "leadpipe"
  vpc_id                    = "vpc-1"
  subnet_ids                = ["subnet-1", "subnet-2"]
  allowed_security_group_id = "sg-cluster"
}

run "database_is_private_and_encrypted" {
  command = apply

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false
    error_message = "The database must never be publicly accessible."
  }
  assert {
    condition     = aws_db_instance.this.storage_encrypted == true
    error_message = "Storage must be encrypted."
  }
}

run "only_the_cluster_can_reach_postgres" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.from_cluster.referenced_security_group_id == "sg-cluster"
    error_message = "Access must come from the cluster's security group."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.from_cluster.cidr_ipv4 == null
    error_message = "There must be no CIDR-based access."
  }
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.from_cluster.from_port == 5432
      && aws_vpc_security_group_ingress_rule.from_cluster.to_port == 5432
    )
    error_message = "Only the PostgreSQL port may be open."
  }
}

run "password_stays_out_of_terraform" {
  command = apply

  assert {
    condition     = aws_db_instance.this.manage_master_user_password == true
    error_message = "RDS must own the password, so it never appears in state or plans."
  }
  assert {
    condition     = aws_db_instance.this.password == null
    error_message = "No password may be set through Terraform."
  }
}

run "default_rotation_does_not_break_running_pods" {
  command = apply

  assert {
    condition     = aws_secretsmanager_secret_rotation.master.rotation_rules[0].automatically_after_days == 365
    error_message = "The 7 day RDS default would break pods holding the old password."
  }
  assert {
    condition     = aws_secretsmanager_secret_rotation.master.rotate_immediately == false
    error_message = "Applying must not rotate the password as a side effect."
  }
}

run "defaults_allow_the_rebuild_demo" {
  command = apply

  assert {
    condition     = aws_db_instance.this.skip_final_snapshot && !aws_db_instance.this.deletion_protection
    error_message = "terraform destroy must work without manual steps."
  }
}

run "a_final_snapshot_is_named_when_requested" {
  command = apply

  variables {
    skip_final_snapshot = false
  }

  assert {
    condition     = aws_db_instance.this.final_snapshot_identifier == "leadpipe-final"
    error_message = "A final snapshot needs an identifier, or deletion fails."
  }
}
