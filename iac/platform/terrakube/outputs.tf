output "instance_id" { value = aws_instance.this.id }
output "admin_login" { value = "admin@example.com  (password: iac/tf.sh platform/terrakube output -raw admin_password)" }
output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}
output "hosts_line" { value = "127.0.0.1 terrakube.platform.local terrakube-api.platform.local terrakube-registry.platform.local terrakube-dex.platform.local" }
output "tunnel" {
  value = "aws ssm start-session --profile ${var.aws_profile} --region ${var.region} --target ${aws_instance.this.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=443,localPortNumber=443"
}
output "url" { value = "https://terrakube.platform.local" }
