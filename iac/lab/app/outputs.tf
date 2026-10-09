locals {
  snapshot_id = var.seed_snapshot_id != "" ? var.seed_snapshot_id : "dr-lab-${var.env}-seed"
  env_file    = var.env_file != "" ? var.env_file : "${path.module}/../../../env/${var.env}.env"
}

resource "local_file" "env" {
  count           = var.write_env_file ? 1 : 0
  filename        = abspath(local.env_file)
  file_permission = "0600"
  content = templatefile("${path.module}/env.tftpl", {
    env              = var.env
    aws_profile      = var.aws_profile == null ? "" : var.aws_profile
    region           = var.region
    account_id       = var.account_id
    kubeconfig       = local.eks.kubeconfig_paths[var.env]
    context          = local.eks.kube_contexts[var.env]
    cluster          = local.eks.eks_cluster_name
    require_identity = var.env == var.cluster_identity_env
    db               = local.db.db_identifier
    multi_az         = local.db.multi_az
    namespace        = local.namespace
    secret           = var.secret_name
    quarantine_sg    = local.db.quarantine_sg
    master_secret    = local.db.master_secret_arn
    bucket           = local.db.evidence_bucket
    snapshot         = aws_db_snapshot.seed.db_snapshot_identifier
  })
}

output "env_file" { value = one(local_file.env[*].filename) }
output "snapshot_id" { value = aws_db_snapshot.seed.db_snapshot_identifier }
output "next" { value = "source ${local.env_file} && tests/aws/sandbox-test.sh readonly   (env file: written by iac/tf.sh on the Mac; elsewhere run automation/scripts/dr-env-discover.sh ${var.env})" }
