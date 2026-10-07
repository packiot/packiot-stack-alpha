# Dev-seed image (ADR-0060 D4): pinned to staging's versions (PostgreSQL 15.17 + TimescaleDB 2.27.0, verified
# 2026-10-06). Build context = the extractor's $OUT/payload plus load.sh:
#   cp dev/seed/load.sh "$OUT/payload/" && docker build -f dev/seed/Dockerfile -t devdb-seed "$OUT/payload"
FROM timescale/timescaledb:2.27.0-pg15
COPY --chown=postgres:postgres . /seed/
RUN rm -f /seed/Dockerfile && mv /seed/load.sh /docker-entrypoint-initdb.d/50-devseed.sh
# no phoning home from developer laptops
CMD ["postgres", "-c", "timescaledb.telemetry_level=off"]
