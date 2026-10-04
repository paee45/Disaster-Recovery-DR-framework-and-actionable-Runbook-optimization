locals {
  arm = can(regex("^[a-z]+[0-9]+g[a-z]*\\.", var.instance_type)) # t4g., m7g., c7gd. … = Graviton
}

data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${local.arm ? "arm64" : "x86_64"}"
}

resource "aws_instance" "this" {
  ami                    = nonsensitive(data.aws_ssm_parameter.ami.value)
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # containers (Terrakube executor) can use the instance role
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  user_data = templatefile("${path.module}/bootstrap.sh.tftpl", {
    region       = var.region
    bucket       = aws_s3_bucket.config.id
    param_prefix = "/${var.name}/terrakube"
    tk_version   = var.terrakube_version
    silo_version = var.silo_version
    swap_gb      = var.swap_gb
    config_hash  = sha1(join("", [for o in aws_s3_object.compose : o.etag]))
  })
  user_data_replace_on_change = true # changed compose/ or versions → a fresh instance (Terrakube data lives on it: export first)

  tags = { Name = "${var.name}-terrakube" }

  depends_on = [aws_ssm_parameter.this, aws_s3_object.compose, aws_iam_role_policy.boot]

  lifecycle { ignore_changes = [ami] } # a newer AMI must not replace the running instance
}
