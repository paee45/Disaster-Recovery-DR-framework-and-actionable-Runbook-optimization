resource "aws_iam_role" "this" {
  name = "${var.name}-terrakube"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # Session Manager (port-forward, shell) — no SSH
}

# Terrakube's executor builds the labs with the instance role (no access keys stored anywhere). Sandbox account only.
resource "aws_iam_role_policy_attachment" "executor_admin" {
  count      = var.executor_admin ? 1 : 0
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy" "boot" {
  name = "boot-config"
  role = aws_iam_role.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:ListBucket"], Resource = [aws_s3_bucket.config.arn, "${aws_s3_bucket.config.arn}/*"] },
      { Effect = "Allow", Action = ["ssm:GetParameter", "ssm:GetParameters"], Resource = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/${var.name}/terrakube/*" }
    ]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-terrakube"
  role = aws_iam_role.this.name
}
