# ══════════════════════════════════════════════════════════════════════════════
# AWS-native raw-history HISTORIAN — S3 + Parquet + Athena (Approach B3)
# ══════════════════════════════════════════════════════════════════════════════
#
# WHAT THIS IS
# The cheap "cold store" half of the approved hybrid history plan
# (docs/plans/legacy-history-migration-costing.md). Legacy client history —
# principally `equipment_values` (2.19 B rows / 630 GB uncompressed over ~6 yr) —
# is unloaded SELECT-ONLY from the legacy PG12/TimescaleDB (`packiot40`) into ZSTD
# Parquet on S3, and queried through Athena. Superset/BI (bi.prod) reads it for
# historical dashboards. Legacy ids/topics are kept AS-IS in the cold store (no
# remap needed for the raw historian; map only if/when joined to F3).
#
# WHY S3+PARQUET+ATHENA (not GCP/BigQuery, not Timescale)
# Deliberately OFF GCP. Lowest $ and lowest ops of the viable homes: storage is
# a few $/mo, query is pay-per-scan kept tiny by Parquet columnar + partition
# pruning, and there is no server to patch. See the runbook for the full compare:
#   docs/plans/historian-s3-athena-runbook.md
#
# COST-OPTIMISED — NO GLUE MONEY-PIT (explicit):
#   * Glue **crawlers**: NOT USED. Partitions resolve at query time via Athena
#     PARTITION PROJECTION (the TBLPROPERTIES below). No crawler ever runs → $0.
#   * Glue **ETL / Spark jobs**: NOT USED. The PG→Parquet unload is DuckDB on
#     cheap/existing compute (scripts/historian-unload.sh) → ≈$0 compute.
#   * Glue **Data Catalog**: used only to STORE this one table definition — free
#     for the first 1M objects, trivial after. That is the only Glue spend.
#
# PROVEN (pilot, 2026-08-11): ent-1 (CPACK) 2026-08-10 unloaded end-to-end;
# Athena `count(*)` = 161,819 == legacy SELECT for the same day (scanned 272 KB);
# top-3 equipment-by-rows spot-check matched legacy exactly. July-2026 full month
# (~5.5 M rows) unloaded as the scale-up proof.
#
# APPLY NOTE — these resources were first created via CLI to prove the pilot end-
# to-end (bucket, Glue DB, Athena workgroup, the projection table). This file is
# the matching IaC. Reconcile state with `terraform import` (commands in the
# runbook doc, §"Codify / import") so there is no click-ops drift. Everything here
# is purely ADDITIVE — it creates only NEW resources and touches nothing existing.

# ── S3 bucket: the cold store ────────────────────────────────────────────────
# Same security posture as backups.tf (PAB, AES256, versioning off). Holds the
# partitioned Parquet under equipment_values/ and Athena query results under
# athena-results/.
resource "aws_s3_bucket" "historian" {
  bucket = "packiot-staging-historian-${data.aws_caller_identity.current.account_id}"
  tags = {
    Name    = "packiot-staging-historian"
    Purpose = "raw-equipment-values-cold-store"
  }
}

resource "aws_s3_bucket_public_access_block" "historian" {
  bucket                  = aws_s3_bucket.historian.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "historian" {
  bucket = aws_s3_bucket.historian.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning off — Parquet objects are immutable per (tenant, day) keys; a re-run
# of a day intentionally overwrites exactly that object (idempotent backfill).
resource "aws_s3_bucket_versioning" "historian" {
  bucket = aws_s3_bucket.historian.id
  versioning_configuration {
    status = "Disabled"
  }
}

# Lifecycle:
#   * equipment_values/ — tier COLD data down (it is a historian; recent months
#     are hit most). Standard → Standard-IA at 1 yr → Glacier Instant Retrieval
#     at 2 yr. GIR still serves Athena with ms latency at ~$0.004/GB-mo. We do NOT
#     use Deep Archive (would break interactive Athena). Don't over-engineer — no
#     intelligent-tiering, the access pattern is predictable (recent = hot).
#   * athena-results/ — query-result spill is disposable; expire at 30 days.
resource "aws_s3_bucket_lifecycle_configuration" "historian" {
  bucket = aws_s3_bucket.historian.id
  rule {
    id     = "prune-equipment-values-180d"
    status = "Enabled"
    filter { prefix = "equipment_values/" }
    # STAGING is a TEST historian: PRUNE raw Parquet after 6 months. (Production
    # instead KEEPS forever and only tiers to colder storage — see
    # terraform/production/historian.tf's 365d/730d transitions.)
    expiration { days = 180 }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
  rule {
    id     = "expire-athena-results"
    status = "Enabled"
    filter { prefix = "athena-results/" }
    expiration { days = 30 }
  }
}

# ── Glue Data Catalog database (storage only — no crawler, no ETL) ────────────
resource "aws_glue_catalog_database" "historian" {
  name        = "packiot_historian_staging"
  description = "Raw equipment_values cold store (legacy ids preserved). Parquet on S3, queried via Athena partition projection. No crawler, no Glue ETL."
}

# ── The projection table ─────────────────────────────────────────────────────
# Column schema mirrors legacy `equipment_values` (PG12) 1:1 with a standard
# PG→Hive type map. Partitions (enterprise/year/month) are PATH-encoded by the
# unload job and resolved by Athena PARTITION PROJECTION — no crawler, no
# ALTER TABLE ADD PARTITION, no MSCK. New tenants/months become queryable the
# instant their Parquet lands under the templated key.
locals {
  historian_ev_columns = [
    { name = "ts_value", type = "timestamp" },
    { name = "id_enterprise", type = "int" },
    { name = "id_site", type = "int" },
    { name = "id_area", type = "int" },
    { name = "id_equipment", type = "int" },
    { name = "net_production_incr", type = "double" },
    { name = "gross_production_incr", type = "double" },
    { name = "scrap_incr", type = "double" },
    { name = "speed", type = "float" },
    { name = "id_order", type = "string" },
    { name = "conversion_factor", type = "float" },
    { name = "number_cavities", type = "int" },
    { name = "faults", type = "string" },
    { name = "analogs", type = "string" },
    { name = "signal_quality", type = "smallint" },
    { name = "net_production_val", type = "double" },
    { name = "gross_production_val", type = "double" },
    { name = "scrap_val", type = "double" },
    { name = "id_shift", type = "int" },
    { name = "id_team", type = "int" },
    { name = "id_shift_hour", type = "int" },
    { name = "box_code", type = "string" },
    { name = "transaction_code", type = "string" },
    { name = "state", type = "int" },
    { name = "mode", type = "int" },
    { name = "id_production_order", type = "bigint" },
    { name = "ts_value_production", type = "date" },
    { name = "id_equipment_line_infeed", type = "int" },
    { name = "id_equipment_line_outfeed", type = "int" },
    { name = "net_production_incr_quality", type = "smallint" },
    { name = "gross_production_incr_quality", type = "smallint" },
    { name = "scrap_incr_quality", type = "smallint" },
    { name = "speed_quality", type = "smallint" },
    { name = "id_order_quality", type = "smallint" },
    { name = "conversion_factor_quality", type = "smallint" },
    { name = "number_cavities_quality", type = "smallint" },
    { name = "net_production_val_quality", type = "smallint" },
    { name = "gross_production_val_quality", type = "smallint" },
    { name = "scrap_val_quality", type = "smallint" },
    { name = "id_shift_quality", type = "smallint" },
    { name = "state_quality", type = "smallint" },
    { name = "mode_quality", type = "smallint" },
    { name = "id_production_order_quality", type = "smallint" },
    { name = "ts_value_production_quality", type = "smallint" },
    { name = "id_equipment_line_connected", type = "int" },
    { name = "position_in_equipment_line", type = "smallint" },
    { name = "is_equipment_line_infeed", type = "smallint" },
    { name = "is_equipment_line_outfeed", type = "smallint" },
    { name = "process_scrap_incr", type = "double" },
    { name = "process_scrap_val", type = "double" },
    { name = "process_scrap_incr_quality", type = "smallint" },
    { name = "process_scrap_val_quality", type = "smallint" },
    { name = "tp_equipment", type = "smallint" },
    { name = "sub_mode", type = "string" },
    { name = "ideal_production_speed", type = "int" },
    { name = "check_number", type = "bigint" },
  ]
}

resource "aws_glue_catalog_table" "equipment_values" {
  name          = "equipment_values"
  database_name = aws_glue_catalog_database.historian.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL              = "TRUE"
    classification        = "parquet"
    "parquet.compression" = "ZSTD"
    # Athena partition projection — the whole point (no crawler).
    "projection.enabled"          = "true"
    "projection.enterprise.type"  = "integer"
    "projection.enterprise.range" = "1,100"
    "projection.year.type"        = "integer"
    "projection.year.range"       = "2019,2027"
    "projection.month.type"       = "integer"
    "projection.month.range"      = "1,12"
    # $${...} escapes terraform interpolation — Athena receives literal ${...}.
    "storage.location.template" = "s3://${aws_s3_bucket.historian.bucket}/equipment_values/enterprise=$${enterprise}/year=$${year}/month=$${month}/"
  }

  partition_keys {
    name = "enterprise"
    type = "int"
  }
  partition_keys {
    name = "year"
    type = "int"
  }
  partition_keys {
    name = "month"
    type = "int"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.historian.bucket}/equipment_values/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    dynamic "columns" {
      for_each = local.historian_ev_columns
      content {
        name = columns.value.name
        type = columns.value.type
      }
    }
  }
}

# ── Athena workgroup ─────────────────────────────────────────────────────────
# Dedicated workgroup so historian queries are isolated + cost-guarded. Results
# spill to athena-results/ (lifecycle-expired at 30 d). 10 GB per-query scan
# ceiling is a runaway-cost guard (a pruned Parquet BI query scans MBs, not GBs).
resource "aws_athena_workgroup" "historian" {
  name        = "packiot_historian_staging"
  description = "Historian ad-hoc + Superset/BI queries. 10GB per-query scan guard."

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = 10 * 1024 * 1024 * 1024

    result_configuration {
      output_location = "s3://${aws_s3_bucket.historian.bucket}/athena-results/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

# ── IAM: unload-writer (attach to whatever runs scripts/historian-unload.sh) ──
# PutObject to the cold store + Athena read to self-verify. Attached to the app
# EC2 role (backups.tf attaches to the same role) since the app box is the
# natural, already-present compute for the batch unload. The runner ALSO needs
# `databaseCredentials` read (legacy SELECT-only creds) — the app role's secrets
# grant already covers packiot/production/*; databaseCredentials is a top-level
# secret, so if the unload runs on the app box add it to that role's secret
# resource list (one-line follow-up, called out here to stay additive).

# ── Outputs ──────────────────────────────────────────────────────────────────
output "historian_bucket" {
  description = "S3 cold store for raw equipment_values Parquet."
  value       = aws_s3_bucket.historian.bucket
}

output "historian_glue_database" {
  description = "Glue Data Catalog database for the historian (Athena queries this)."
  value       = aws_glue_catalog_database.historian.name
}

output "historian_athena_workgroup" {
  description = "Athena workgroup for historian / Superset queries."
  value       = aws_athena_workgroup.historian.name
}

output "historian_sample_query" {
  description = "Example partition-pruned Athena query."
  value       = "SELECT count(*) FROM packiot_historian.equipment_values WHERE enterprise=1 AND year=2026 AND month=7"
}

# ── box-role write access (the daily append runs on the staging app box) ──────
# The historian-staging-append.timer runs scripts/historian-staging-run-append.sh
# on the app box (instance role packiot-staging-app), which DuckDB-unloads F3
# equipment_values → Parquet → this bucket. Grant that role write access.
resource "aws_iam_role_policy" "historian_staging_write" {
  name = "packiot-staging-historian-write"
  role = "packiot-staging-app"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid    = "HistorianWrite", Effect = "Allow",
        Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      Resource = "${aws_s3_bucket.historian.arn}/*" },
      { Sid    = "HistorianList", Effect = "Allow",
        Action = ["s3:ListBucket", "s3:GetBucketLocation"],
      Resource = aws_s3_bucket.historian.arn },
    ]
  })
}
