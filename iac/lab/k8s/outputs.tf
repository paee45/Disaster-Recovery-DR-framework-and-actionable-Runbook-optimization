resource "local_file" "env" {
  filename        = abspath("${path.module}/${var.env_file}")
  file_permission = "0600"
  content = templatefile("${path.module}/uat.env.tftpl", {
    aws_profile   = local.a.aws_profile
    region        = local.a.region
    account_id    = local.a.account_id
    kubeconfig    = local.a.kubeconfig_path
    context       = local.a.kube_context
    cluster       = local.a.eks_cluster_name
    db            = local.a.db_identifier
    namespace     = var.namespace
    secret        = var.secret_name
    quarantine_sg = local.a.quarantine_sg
    master_secret = local.a.master_secret_arn
    bucket        = local.a.evidence_bucket
    snapshot      = aws_db_snapshot.seed.db_snapshot_identifier
  })
}

output "env_file" { value = local_file.env.filename }
output "snapshot_id" { value = aws_db_snapshot.seed.db_snapshot_identifier }
output "next" { value = "source ${local_file.env.filename} && tests/aws/sandbox-test.sh readonly" }
