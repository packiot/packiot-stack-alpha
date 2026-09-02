# `terraform/modules/lakehouse` — ADR-0041 offline lakehouse (SCAFFOLD, NOT WIRED)

> **STATUS: SCAFFOLD / DESIGN ONLY. This module is not referenced by any root
> (`terraform/staging`, `terraform/production`), so `terraform apply` in either
> env does NOT create these resources.** It is the P0 deliverable of ADR-0041 —
> a reviewable, `terraform validate`-able shape for the S3 lake + Glue databases +
> Athena workgroup. **Do not apply until P1 is approved** (ADR-0041 §5, build plan
> §8). No infra is provisioned by merging this.

- **Decision:** [`docs/adr/0041-gcp-exit-lakehouse.md`](../../../docs/adr/0041-gcp-exit-lakehouse.md)
- **Build plan:** [`docs/adr/reference/designs/0041-lakehouse-build-plan.md`](../../../docs/adr/reference/designs/0041-lakehouse-build-plan.md)
- **Glue table DDL:** [`docs/adr/reference/migrations/0041-glue-catalog-ddl.sql`](../../../docs/adr/reference/migrations/0041-glue-catalog-ddl.sql) (run by hand at P2, not by this module)

## What it defines
| Resource | Purpose |
|---|---|
| `aws_s3_bucket packiot-lake-<env>` | the object-storage lake (bronze/silver/gold parquet) |
| Block-Public-Access + SSE + versioning + lifecycle | hardening (build plan §1) |
| `aws_glue_catalog_database bronze` / `gold` | Glue databases for the catalog (tables via DDL, §3) |
| `aws_athena_workgroup packiot-lake-<env>` | serverless SQL engine v3 + bytes-scanned cap + governed results |

The **Glue tables** themselves are created by the Athena DDL (partition projection is
cleaner to express in SQL `TBLPROPERTIES` than in `aws_glue_catalog_table`), not by
this module. The module provisions the *containers* (bucket, databases, workgroup).

## To activate (P1 — do not do at P0)
```hcl
# in terraform/staging/lakehouse.tf (create at P1):
module "lakehouse" {
  source = "../modules/lakehouse"
  env    = "staging"
}
```
Then `terraform plan` → review → `terraform apply` in `terraform/staging` only.
Prod is a separate, later, USER-gated step.
