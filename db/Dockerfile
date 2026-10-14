# Base image PINNED (ADR-0063 Phase A4, 2026-10-14) to the exact image staging runs:
# timescale/timescaledb:2.27.0-pg15 (PostgreSQL 15.17, Alpine 3.22). The digest is the
# multi-arch index that `docker images --digests` shows for the base on the staging DB
# host (built 2026-05-18 from `latest-pg15`, which then pointed here). `latest-pg15` has
# since moved to TimescaleDB 2.28.3 / PostgreSQL 15.18, so an unpinned rebuild would
# have upgraded the extension silently. Change this only together with an
# `ALTER EXTENSION timescaledb UPDATE` plan (ADR-0063 "Version alignment").
ARG TIMESCALE_IMAGE=timescale/timescaledb:2.27.0-pg15@sha256:3f77046809de51aacf70719c3662f05e0bf9d29c0c7f9d8bda6bb57a0c6fe400

# Stage 1 — compile pg_cron from source against the timescale image headers.
# The timescale image is Alpine-based (no apk pg_cron package).
FROM ${TIMESCALE_IMAGE} AS builder

RUN apk add --no-cache \
        build-base \
        postgresql15-dev \
        git

ARG PGCRON_VERSION=v1.6.5
RUN git clone --depth 1 --branch ${PGCRON_VERSION} \
        https://github.com/citusdata/pg_cron.git /pg_cron

COPY clang-19-stub.sh /usr/local/bin/clang-19
WORKDIR /pg_cron
# PG15 bakes CLANG=clang-19 into Makefile.global; Alpine only ships clang≤16
# and clang-16 rejects GCC-only flags as errors. pg_cron is a background
# worker — JIT bitcode (.bc) files are never used at runtime. The stub
# creates empty .bc output files so pgxs completes; only the .so matters.
RUN chmod +x /usr/local/bin/clang-19 \
    && mkdir -p /usr/lib/llvm19/bin \
    && printf '#!/bin/sh\nexit 0\n' > /usr/lib/llvm19/bin/llvm-lto \
    && chmod +x /usr/lib/llvm19/bin/llvm-lto \
    && make && make install

# Stage 2 — clean runtime image with pg_cron extension copied in.
FROM ${TIMESCALE_IMAGE}

COPY --from=builder \
    /usr/local/lib/postgresql/pg_cron.so \
    /usr/local/lib/postgresql/pg_cron.so

COPY --from=builder \
    /usr/local/share/postgresql/extension/ \
    /usr/local/share/postgresql/extension/

# shared_preload_libraries (timescaledb,pg_cron,pg_stat_statements — timescaledb
# MUST stay first) and cron.database_name are passed via the docker run -c "..."
# flags in db_init.sh / compose, NOT baked into the image. The timescale base
# image reads only $PGDATA/postgresql.conf, not /etc/postgresql/postgresql.conf.d,
# so conf.d drop-ins are ignored. Because -c is the postmaster command line, it
# overrides postgresql.conf and postgresql.auto.conf — ALTER SYSTEM cannot change
# the preload set on a running cluster; edit db_init.sh and recreate the container.

COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/
