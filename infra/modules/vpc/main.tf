# Public subnets hold the load balancers and NAT. Private subnets hold the nodes and the database.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs       = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  nat_count = var.single_nat_gateway ? 1 : var.az_count
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

# Removes the AWS default rules, so nothing can use this group by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = var.name }
}

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index)

  tags = {
    Name = "${var.name}-public-${local.azs[count.index]}"
    # The AWS Load Balancer Controller finds subnets for internet-facing ALBs by this tag.
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index + 8)
  # Stated explicitly, because this is the property that makes the subnet private.
  map_public_ip_on_launch = false

  tags = {
    Name                                        = "${var.name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"

  tags = { Name = "${var.name}-nat-${count.index}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${var.name}-${count.index}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    # With a single NAT gateway, every private subnet shares the first one.
    nat_gateway_id = aws_nat_gateway.this[min(count.index, local.nat_count - 1)].id
  }

  tags = { Name = "${var.name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
