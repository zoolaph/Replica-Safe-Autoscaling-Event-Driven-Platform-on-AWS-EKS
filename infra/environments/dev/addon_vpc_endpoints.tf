data "aws_region" "current" {}

# Interface endpoints need an SG to allow HTTPS from inside the VPC
resource "aws_security_group" "vpc_endpoints" {
  name        = "rsedp-${var.env_name}-vpc-endpoints"
  description = "Allow HTTPS to VPC interface endpoints from inside the VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = "rsedp"
    Env     = var.env_name
  }
}

# S3 = Gateway endpoint (route-table based)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  vpc_endpoint_type = "Gateway"
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"

  # Attach to private route tables so private subnets hit S3 without NAT
  route_table_ids = module.vpc.private_route_table_ids

  tags = {
    Name    = "rsedp-${var.env_name}-s3"
    Project = "rsedp"
    Env     = var.env_name
  }
}

# Interface endpoints = ENIs in your private subnets
locals {
  interface_endpoints = toset([
    "ecr.api",
    "ecr.dkr",
    "sts",
  ])
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = module.vpc.vpc_id
  vpc_endpoint_type   = "Interface"
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  subnet_ids          = module.vpc.private_subnets
  private_dns_enabled = true

  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = {
    Name    = "rsedp-${var.env_name}-${each.value}"
    Project = "rsedp"
    Env     = var.env_name
  }
}
