# ADR-0041 offline lakehouse module — variables. SCAFFOLD (see README): not wired to any root.

variable "env" {
  description = "Environment name; drives bucket/workgroup naming (packiot-lake-<env>)."
  type        = string
  validation {
    condition     = contains(["staging", "production"], var.env)
    error_message = "env must be 'staging' or 'production'."
  }
}

variable "bytes_scanned_cutoff_per_query" {
  description = "Athena per-query hard cap (bytes). Guardrail against a runaway full-scan bill (build plan §5)."
  type        = number
  default     = 21474836480 # 20 GiB
}

variable "athena_results_expiry_days" {
  description = "Lifecycle expiry for the athena-results/ prefix."
  type        = number
  default     = 30
}

variable "noncurrent_version_expiry_days" {
  description = "Lifecycle expiry for noncurrent object versions (idempotent partition overwrite audit trail, build plan §4.4)."
  type        = number
  default     = 90
}
