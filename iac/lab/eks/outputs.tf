output "eks_cluster_name" { value = aws_eks_cluster.this.name }
output "eks_endpoint" { value = aws_eks_cluster.this.endpoint }
output "eks_ca" { value = aws_eks_cluster.this.certificate_authority[0].data }
output "kubeconfig_paths" { value = { for e, f in local_sensitive_file.kubeconfig : e => f.filename } }
output "kube_contexts" { value = { for e in var.envs : e => "dr-${e}" } }
