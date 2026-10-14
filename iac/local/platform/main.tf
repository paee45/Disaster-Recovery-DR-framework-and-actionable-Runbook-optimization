locals {
  repository_path = trimsuffix(var.repository_path, "/")
  databases = {
    old      = { address = "172.30.0.21", orders = 100, payments = 50, app_pw = "apppw-current", hb_age = 0 }
    replica  = { address = "172.30.0.22", orders = 100, payments = 50, app_pw = "apppw-current", hb_age = 0 }
    restored = { address = "172.30.0.23", orders = 80, payments = 40, app_pw = "apppw-OLD", hb_age = 1020 }
  }
  runner_mounts = {
    automation                    = { target = "/workspace/automation", read_only = true }
    env                           = { target = "/workspace/env", read_only = true }
    "tests/local"                 = { target = "/workspace/tests/local", read_only = false }
    "tests/lint"                  = { target = "/workspace/tests/lint", read_only = true }
    "tests/local/.state/evidence" = { target = "/workspace/evidence", read_only = false }
    "iac/local"                   = { target = "/workspace/iac/local", read_only = false }
    runbooks                      = { target = "/workspace/runbooks", read_only = true }
    templates                     = { target = "/workspace/templates", read_only = true }
  }
}

module "tools" {
  source      = "../tools"
  tool_arch   = var.tool_arch
  tools_image = var.tools_image
}

resource "docker_network" "lab" {
  name   = "drtest"
  driver = "bridge"
  ipam_config {
    subnet = "172.30.0.0/24"
  }
  options = {
    "com.docker.network.bridge.gateway_mode_ipv4" = "nat-unprotected"
  }
}

resource "docker_image" "postgres" {
  name = "postgres:16-alpine"
}

resource "docker_volume" "postgres" {
  for_each = local.databases
  name     = "drtest-pg-${each.key}-data"
}

resource "docker_container" "postgres" {
  for_each = local.databases
  name     = "drtest-pg-${each.key}"
  image    = docker_image.postgres.image_id
  env      = ["POSTGRES_PASSWORD=masterpw"]
  networks_advanced {
    name         = docker_network.lab.name
    ipv4_address = each.value.address
  }
  volumes {
    volume_name    = docker_volume.postgres[each.key].name
    container_path = "/var/lib/postgresql/data"
  }
  upload {
    content = file("${path.module}/../../../tests/local/seed.sql")
    file    = "/opt/drtest/seed.sql"
  }
  upload {
    content = templatefile("${path.module}/postgres-init.sh.tftpl", each.value)
    file    = "/docker-entrypoint-initdb.d/10-drtest.sh"
  }
  healthcheck {
    test         = ["CMD-SHELL", "pg_isready -h 127.0.0.1 -U postgres -d app && PGPASSWORD=masterpw psql -h 127.0.0.1 -U postgres -d app -tAc 'SELECT count(*) FROM dr.heartbeat' | grep -x 1"]
    interval     = "5s"
    timeout      = "3s"
    start_period = "30s"
    retries      = 12
  }
  wait         = true
  wait_timeout = 120
}

resource "docker_image" "localstack" {
  name = "localstack/localstack:4.0"
}

resource "docker_container" "localstack" {
  name  = "drtest-localstack"
  image = docker_image.localstack.image_id
  env = [
    "SERVICES=secretsmanager,sts,s3,ssm,cloudwatch,logs,iam,kms",
    "EAGER_SERVICE_LOADING=1",
  ]
  networks_advanced {
    name         = docker_network.lab.name
    ipv4_address = "172.30.0.10"
  }
}

resource "docker_container" "moto" {
  name         = "drtest-moto"
  image        = module.tools.image_id
  network_mode = "host"
  env          = ["DR_MOTO_CODE_SHA256=${filesha256("${path.module}/../../../tests/local/moto_launcher.py")}"]
  command      = ["/opt/drtest-venv/bin/python", "/opt/drtest/moto_launcher.py", "-H", "127.0.0.1", "-p", "5000"]
  mounts {
    type      = "bind"
    source    = "${local.repository_path}/tests/local/moto_launcher.py"
    target    = "/opt/drtest/moto_launcher.py"
    read_only = true
  }
}

resource "docker_image" "k3s" {
  name = "rancher/k3s:v1.31.4-k3s1"
}

resource "docker_volume" "k3s" {
  name = "drtest-k3s-data"
}

resource "docker_container" "k3s" {
  name         = "drtest-k3s"
  image        = docker_image.k3s.image_id
  privileged   = true
  network_mode = "host"
  command      = ["server", "--disable", "traefik,metrics-server", "--write-kubeconfig-mode", "600"]
  volumes {
    volume_name    = docker_volume.k3s.name
    container_path = "/var/lib/rancher/k3s"
  }
}

resource "docker_container" "runner" {
  name         = "drtest-tools"
  image        = module.tools.image_id
  network_mode = "host"
  working_dir  = "/workspace"
  command      = ["sleep", "infinity"]
  dynamic "mounts" {
    for_each = local.runner_mounts
    content {
      type      = "bind"
      source    = "${local.repository_path}/${mounts.key}"
      target    = mounts.value.target
      read_only = mounts.value.read_only
    }
  }
  dynamic "mounts" {
    for_each = var.expose_docker_socket ? [var.docker_socket_path] : []
    content {
      type      = "bind"
      source    = mounts.value
      target    = "/var/run/docker.sock"
      read_only = false
    }
  }
}