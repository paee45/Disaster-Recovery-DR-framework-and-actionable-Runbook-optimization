variable "restored_db_id" {
  type        = string
  description = "Existing local Moto DB instance created by the S3/S4 DR run."
  validation {
    condition     = can(regex("^app-pg-local-p[0-9]{12}$", var.restored_db_id))
    error_message = "Use the restored local DEV instance identifier app-pg-local-p<YYYYMMDDHHMM>."
  }
}

variable "baseline_file" {
  type        = string
  description = "Captured pre-restore describe-db-instances baseline used to declare the imported primary."
  validation {
    condition     = fileexists(var.baseline_file)
    error_message = "The captured DR baseline file must exist inside the local tools runner."
  }
}

variable "dr_id" {
  type        = string
  description = "DR run identifier used for the restored instance tag."
  validation {
    condition     = can(regex("^DR-[A-Za-z0-9][A-Za-z0-9._-]{0,100}$", var.dr_id))
    error_message = "Use the recorded DR- run identifier."
  }
}

variable "restore_time" {
  type        = string
  description = "Restore point recorded by the S4 run."
  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.restore_time))
    error_message = "Use an ISO-8601 UTC restore time, for example 2026-10-13T14:42:01Z."
  }
}
