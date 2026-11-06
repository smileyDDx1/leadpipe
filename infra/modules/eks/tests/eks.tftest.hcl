# Runs offline against a mocked AWS provider. It creates nothing and needs no credentials.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }
}

variables {
  cluster_name         = "leadpipe"
  subnet_ids           = ["subnet-1", "subnet-2"]
  admin_principal_arns = ["arn:aws:iam::123456789012:role/admin"]
}

run "access_is_declared_in_code" {
  command = apply

  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API"
    error_message = "Use access entries, not the legacy aws-auth ConfigMap."
  }
  assert {
    condition     = aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == false
    error_message = "Admin access must not depend on who happened to run apply."
  }
  assert {
    condition     = length(aws_eks_access_policy_association.admin) == 1
    error_message = "Each admin principal needs a policy association."
  }
}

run "extended_support_charges_cannot_start_silently" {
  command = apply

  assert {
    condition     = aws_eks_cluster.this.upgrade_policy[0].support_type == "STANDARD"
    error_message = "Extended support costs several times more per hour."
  }
}

run "all_required_addons_are_installed" {
  command = apply

  assert {
    condition = (
      toset(keys(aws_eks_addon.before_nodes)) == toset(["vpc-cni", "kube-proxy", "eks-pod-identity-agent"])
      && toset(keys(aws_eks_addon.after_nodes)) == toset(["coredns", "metrics-server"])
    )
    error_message = "Networking, DNS, Pod Identity and metrics (for the HPA) must all be installed."
  }
}

run "defaults_to_a_managed_node_group_of_two" {
  command = apply

  assert {
    condition     = aws_eks_node_group.default.scaling_config[0].desired_size == 2
    error_message = "Expected 2 nodes by default."
  }
}

run "rejects_an_unknown_capacity_type" {
  command = plan

  variables {
    node_capacity_type = "RESERVED"
  }

  expect_failures = [var.node_capacity_type]
}
