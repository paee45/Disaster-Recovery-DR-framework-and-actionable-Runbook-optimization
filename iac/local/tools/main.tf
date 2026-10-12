resource "docker_image" "tools" {
  name = var.tools_image
  build {
    context = abspath(path.module)
    build_args = {
      TARGETARCH = var.tool_arch
    }
  }
  triggers = {
    dockerfile = filesha256("${path.module}/Dockerfile")
    tool_arch  = var.tool_arch
  }
}

output "image_id" {
  value = docker_image.tools.image_id
}

output "image_name" {
  value = docker_image.tools.name
}