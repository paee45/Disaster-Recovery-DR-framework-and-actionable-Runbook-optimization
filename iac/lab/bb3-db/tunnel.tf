variable "bb3_tunnel_enabled" {
  description = "Temporary sandbox PostgreSQL access from the existing Terrakube SSM host."
  type        = bool
  default     = false
  validation {
    condition     = !var.bb3_tunnel_enabled || contains(["dev", "uat"], var.env)
    error_message = "The temporary tunnel is allowed only for sandbox dev/uat."
  }
}

data "aws_instance" "tunnel" {
  count = var.bb3_tunnel_enabled ? 1 : 0
  filter {
    name   = "tag:Name"
    values = ["dr-platform-terrakube"]
  }
  filter {
    name   = "tag:repo-path"
    values = ["iac/platform/terrakube"]
  }
  filter {
    name   = "instance-state-name"
    values = ["running", "stopped"]
  }
}

data "aws_subnet" "tunnel" {
  count = var.bb3_tunnel_enabled ? 1 : 0
  id    = data.aws_instance.tunnel[0].subnet_id
}

resource "aws_vpc_peering_connection" "tunnel" {
  count       = var.bb3_tunnel_enabled ? 1 : 0
  vpc_id      = local.net.vpc_id
  peer_vpc_id = data.aws_subnet.tunnel[0].vpc_id
  auto_accept = true
  tags        = { Name = "dr-platform-bb3-${var.env}-tunnel" }
  lifecycle {
    precondition {
      condition     = local.net.vpc_id != data.aws_subnet.tunnel[0].vpc_id
      error_message = "The tunnel host must be in the separate platform VPC."
    }
  }
}