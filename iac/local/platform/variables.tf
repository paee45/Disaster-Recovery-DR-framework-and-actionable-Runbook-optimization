variable "docker_host" {
  type        = string
  default     = "unix:///var/run/docker.sock"
  description = "Docker provider endpoint. Must connect to a Linux engine."
}

variable "repository_path" {
  type        = string
  description = "Absolute HOST repository root in Docker bind-mount syntax (Windows: C:/path/dr-framework). Never /workspace."
  validation {
    condition     = can(regex("^(/|[A-Za-z]:/)", var.repository_path)) && !strcontains(var.repository_path, "\\")
    error_message = "repository_path must be an absolute host path using forward slashes."
  }
}

variable "tool_arch" {
  type        = string
  description = "Native Linux engine architecture: arm64 or amd64."
  validation {
    condition     = contains(["amd64", "arm64"], var.tool_arch)
    error_message = "tool_arch must be amd64 or arm64."
  }
}

variable "tools_image" {
  type        = string
  default     = "drtest-tools:terraform-1.15.2"
  description = "Tag for the tools image built by Terraform."
}

variable "expose_docker_socket" {
  type        = bool
  default     = false
  description = "SETUP ONLY: mounting this socket gives the runner control of the entire Docker engine, including host mounts."
}

variable "docker_socket_path" {
  type        = string
  default     = "/var/run/docker.sock"
  description = "Socket bind source on the Linux engine host; independent of the workstation provider endpoint."
}