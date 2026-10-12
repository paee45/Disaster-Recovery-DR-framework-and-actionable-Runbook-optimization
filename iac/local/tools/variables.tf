variable "tool_arch" {
  type        = string
  description = "Architecture of the Linux Docker engine, not the workstation."
  validation {
    condition     = contains(["amd64", "arm64"], var.tool_arch)
    error_message = "tool_arch must be amd64 or arm64."
  }
}

variable "tools_image" {
  type        = string
  default     = "drtest-tools:terraform-1.15.2"
  description = "Tag for the locally built tools image."
}