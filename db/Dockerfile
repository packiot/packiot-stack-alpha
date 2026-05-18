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

WORKDIR /pg_cron
# PG15 bakes CLANG=clang-19 into Makefile.global; Alpine only ships clang≤16
# and clang-16 rejects GCC-only flags (-Wno-format-truncation) as errors.
# pg_cron is a background worker — JIT bitcode (.bc) files are never used.
# Stub clang-19 to create empty .bc output files and exit 0; only the .so matters.
RUN printf '#!/bin/sh\nn=0;for a;do [ "$n"=1 ]&&{ touch "$a";n=0; };[ "$a"="-o" ]&&n=1;done\n' \
        > /usr/local/bin/clang-19 \
    && chmod +x /usr/local/bin/clang-19 \
    && make && make install

# Stage 2 — clean runtime image with pg_cron extension copied in.
FROM timescale/timescaledb:latest-pg15

COPY --from=builder \
    /usr/lib/postgresql15/pg_cron.so \
    /usr/lib/postgresql15/pg_cron.so

COPY --from=builder \
    /usr/share/postgresql15/extension/pg_cron* \
    /usr/share/postgresql15/extension/

# Append pg_cron to shared_preload_libraries via a conf.d drop-in.
# timescaledb is already set by the base image; we extend it here.
RUN echo "shared_preload_libraries = 'timescaledb,pg_cron'" \
        > /etc/postgresql/postgresql.conf.d/pg_cron.conf && \
    echo "cron.database_name = 'packiot'" \
        >> /etc/postgresql/postgresql.conf.d/pg_cron.conf

COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/
