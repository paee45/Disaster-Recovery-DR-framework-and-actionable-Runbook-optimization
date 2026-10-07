output "account_id" { value = var.account_id }
output "aws_profile" { value = var.aws_profile == null ? "" : var.aws_profile }
output "region" { value = var.region }
output "db_identifier" { value = aws_db_instance.primary.identifier }
output "db_address" { value = aws_db_instance.primary.address }
output "db_port" { value = aws_db_instance.primary.port }
output "master_secret_arn" { value = aws_db_instance.primary.master_user_secret[0].secret_arn }
output "quarantine_sg" { value = aws_security_group.quarantine.id }
output "eks_cluster_name" { value = aws_eks_cluster.this.name }
output "eks_endpoint" { value = aws_eks_cluster.this.endpoint }
output "eks_ca" { value = aws_eks_cluster.this.certificate_authority[0].data }
output "kubeconfig_path" { value = pathexpand(var.kubeconfig_path) }
output "kube_context" { value = var.kube_context }
output "evidence_bucket" { value = aws_s3_bucket.evidence.bucket }
output "vpc_cidr" { value = var.vpc_cidr }
