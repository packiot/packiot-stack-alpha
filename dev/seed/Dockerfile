# dev seed image (ADR-0060 D4–D6). Built by .github/workflows/dev-seed-build.yml for linux/amd64 AND
# linux/arm64: the staging runner is arm64 (Graviton) but developer laptops are mostly amd64 — the first
# published image was arm64-only and failed with "exec format error" on an amd64 laptop (2026-10-07).
# No RUN step on purpose: COPY-only layers need no QEMU emulation to cross-build the other architecture.
# Build context = the anonymized payload/ + load.sh ONLY (never the extract's private/ dir).
FROM timescale/timescaledb:2.27.0-pg15
COPY --chown=postgres:postgres payload/ /seed/
COPY --chown=postgres:postgres --chmod=755 load.sh /docker-entrypoint-initdb.d/50-devseed.sh
CMD ["postgres", "-c", "timescaledb.telemetry_level=off"]
