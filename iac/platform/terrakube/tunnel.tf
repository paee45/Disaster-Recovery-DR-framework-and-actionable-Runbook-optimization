variable "bb3_tunnel_enabled" {
  description = "Temporary peering routes from this SSM host to the BB3 sandbox private DB subnets."
  type        = bool
  default     = false
}

variable "bb3_tunnel_env" {
  type    = string
  default = "uat"
  validation {
    condition     = contains(["dev", "uat"], var.bb3_tunnel_env)
    error_message = "The temporary tunnel is allowed only for sandbox dev/uat."
  }
}

data "aws_vpc_peering_connection" "bb3_tunnel" {
  count = var.bb3_tunnel_enabled ? 1 : 0
  filter {
    name   = "tag:Name"
    values = ["dr-platform-bb3-${var.bb3_tunnel_env}-tunnel"]
  }
  filter {
    name   = "accepter-vpc-info.vpc-id"
    values = [aws_vpc.this.id]
  }
  filter {
    name   = "status-code"
    values = ["active"]
  }
}

data "aws_db_subnet_group" "bb3_tunnel" {
  count = var.bb3_tunnel_enabled ? 1 : 0
  name  = "dr-sandbox-bb3-${var.bb3_tunnel_env}-private-subnets"
  lifecycle {
    postcondition {
      condition     = length(self.subnet_ids) == 2 && self.vpc_id == data.aws_vpc_peering_connection.bb3_tunnel[0].vpc_id
      error_message = "Expected exactly two BB3 private DB subnets in the peered RDS VPC."
    }
  }
}

data "aws_subnet" "bb3_tunnel" {
  for_each = var.bb3_tunnel_enabled ? toset(data.aws_db_subnet_group.bb3_tunnel[0].subnet_ids) : toset([])
  id       = each.value
}