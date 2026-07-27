# ADR-0041 offline lakehouse module — outputs. SCAFFOLD (see README): not wired to any root.

output "lake_bucket" {
  description = "S3 lake bucket name (feed into the export job + Glue DDL env substitution)."
  value       = aws_s3_bucket.lake.bucket
}

output "athena_workgroup" {
  description = "Athena workgroup name (ATHENA_WORKGROUP for cq-logs + parity harness)."
  value       = aws_athena_workgroup.lake.name
}

output "athena_results_s3" {
  description = "Governed Athena results prefix (ATHENA_RESULTS_S3 for pyathena connect)."
  value       = "s3://${aws_s3_bucket.lake.bucket}/athena-results/"
}

output "glue_databases" {
  description = "Glue catalog databases created (tables added via Athena DDL)."
  value       = [aws_glue_catalog_database.bronze.name, aws_glue_catalog_database.gold.name]
}
