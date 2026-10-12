output "network" {
  value = { name = docker_network.lab.name, subnet = "172.30.0.0/24" }
}

output "postgres" {
  value = {
    for key, database in local.databases : key => {
      container = docker_container.postgres[key].name
      host      = database.address
      port      = 5432
      database  = "app"
      volume    = docker_volume.postgres[key].name
    }
  }
}

output "endpoints" {
  value = {
    localstack = "http://172.30.0.10:4566"
    moto       = "http://127.0.0.1:5000"
    kubernetes = "https://127.0.0.1:6443"
  }
  description = "Linux engine/host-network runner addresses; not necessarily reachable from macOS or Windows."
}

output "runner" {
  value = {
    container       = docker_container.runner.name
    image           = module.tools.image_name
    workdir         = "/workspace"
    docker_socket   = var.expose_docker_socket
    aws_config      = "/workspace/tests/local/.state/aws-config"
    aws_credentials = "/workspace/tests/local/.state/aws-credentials"
    kubeconfig      = "/workspace/tests/local/.state/kubeconfig"
  }
}

output "k3s" {
  value = {
    container       = docker_container.k3s.name
    volume          = docker_volume.k3s.name
    kubeconfig_path = "/etc/rancher/k3s/k3s.yaml"
  }
}