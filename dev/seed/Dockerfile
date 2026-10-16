# dev seed image (ADR-0060 D4–D6). Built by .github/workflows/dev-seed-build.yml for linux/amd64 AND
# linux/arm64: the staging runner is arm64 (Graviton) but developer laptops are mostly amd64 — the first
# published image was arm64-only and failed with "exec format error" on an amd64 laptop (2026-10-07).
# No RUN step on purpose: COPY-only layers need no QEMU emulation to cross-build the other architecture.
# Build context = the anonymized payload/ + load.sh + sync-sequences.sql ONLY (never the extract's private/ dir).
# Same image as staging (db/Dockerfile), pinned by digest (ADR-0063 Phase A4).
FROM timescale/timescaledb:2.27.0-pg15@sha256:3f77046809de51aacf70719c3662f05e0bf9d29c0c7f9d8bda6bb57a0c6fe400
COPY --chown=postgres:postgres payload/ /seed/
# run by load.sh after load.sql (F11); also kept in the image so a consumer can re-run it (idempotent)
COPY --chown=postgres:postgres sync-sequences.sql /seed/sync-sequences.sql
COPY --chown=postgres:postgres --chmod=755 load.sh /docker-entrypoint-initdb.d/50-devseed.sh
# enable_job_execution_logging = staging's server flag since 2026-10-14 (ADR-0063 A5,
# terraform/staging/user_data/db_init.sh): job_history records every TimescaleDB job run, not only failures.
CMD ["postgres", "-c", "timescaledb.telemetry_level=off", "-c", "timescaledb.enable_job_execution_logging=on"]
