# Stage 1 — compile pg_cron from source against the timescale image headers.
# timescale/timescaledb:latest-pg15 is Alpine-based (no apk pg_cron package).
FROM timescale/timescaledb:latest-pg15 AS builder

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
FROM timescale/timescaledb:latest-pg15

COPY --from=builder \
    /usr/local/lib/postgresql/pg_cron.so \
    /usr/local/lib/postgresql/pg_cron.so

COPY --from=builder \
    /usr/local/share/postgresql/extension/ \
    /usr/local/share/postgresql/extension/

# Append pg_cron to shared_preload_libraries via a conf.d drop-in.
# timescaledb is already set by the base image; we extend it here.
RUN mkdir -p /etc/postgresql/postgresql.conf.d && \
    echo "shared_preload_libraries = 'timescaledb,pg_cron'" \
        > /etc/postgresql/postgresql.conf.d/pg_cron.conf && \
    echo "cron.database_name = 'packiot'" \
        >> /etc/postgresql/postgresql.conf.d/pg_cron.conf

COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/
