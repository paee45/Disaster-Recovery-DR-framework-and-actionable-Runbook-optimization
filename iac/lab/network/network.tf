# Own VPC (not the default one) so the whole lab is created and destroyed by Terraform.
data "aws_availability_zones" "this" { state = "available" }

locals {
  azs = slice(data.aws_availability_zones.this.names, 0, 3)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for a publicly accessible RDS endpoint
  tags                 = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

# Public subnets: EKS nodes pull images from the internet without a NAT gateway (cheaper lab). Not a production layout.
resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  map_public_ip_on_launch = true
  tags = {
    Name                                    = "${var.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"                = "1"
    "kubernetes.io/cluster/${var.name}-eks" = "shared"
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
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
