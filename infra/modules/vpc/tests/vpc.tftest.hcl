# Runs offline against a mocked AWS provider. It creates nothing and needs no credentials.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
    }
  }
}

variables {
  name         = "leadpipe"
  cluster_name = "leadpipe"
}

run "builds_two_tiers_across_zones" {
  command = apply

  assert {
    condition     = length(aws_subnet.public) == 2 && length(aws_subnet.private) == 2
    error_message = "Expected a public and a private subnet in each of the 2 default zones."
  }
  assert {
    condition     = aws_subnet.public[0].availability_zone != aws_subnet.public[1].availability_zone
    error_message = "Subnets must span different availability zones."
  }
  assert {
    condition     = length(setintersection(aws_subnet.public[*].cidr_block, aws_subnet.private[*].cidr_block)) == 0
    error_message = "Public and private subnets must not overlap."
  }
}

run "subnets_carry_the_load_balancer_discovery_tags" {
  command = apply

  assert {
    condition     = alltrue([for subnet in aws_subnet.public : subnet.tags["kubernetes.io/role/elb"] == "1"])
    error_message = "Public subnets need the tag for internet-facing load balancers."
  }
  assert {
    condition     = alltrue([for subnet in aws_subnet.private : subnet.tags["kubernetes.io/role/internal-elb"] == "1"])
    error_message = "Private subnets need the tag for internal load balancers."
  }
}

run "private_subnets_never_get_public_addresses" {
  command = apply

  assert {
    condition     = alltrue([for subnet in aws_subnet.private : !subnet.map_public_ip_on_launch])
    error_message = "Nothing in a private subnet may receive a public IP."
  }
}

run "single_nat_gateway_is_the_cheap_default" {
  command = apply

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "The default should share one NAT gateway."
  }
}

run "one_nat_gateway_per_zone_when_asked" {
  command = apply

  variables {
    single_nat_gateway = false
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 2
    error_message = "Expected a NAT gateway in each zone."
  }
}

run "rejects_a_single_zone" {
  command = plan

  variables {
    az_count = 1
  }

  expect_failures = [var.az_count]
}
