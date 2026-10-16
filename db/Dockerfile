# Plain PostgreSQL + pg_cron (ADR-0063 end state, 2026-10-15): staging has no TimescaleDB objects left, so the
# base is the official image, pinned to the SAME PostgreSQL 15.17 on Alpine 3.22 (musl) the timescale image ran —
# same major version (the data directory is reused as is), same libc (collation behaviour unchanged), same
# postgres uid (70). The digest is the multi-arch index of postgres:15.17-alpine3.22 (2026-10-15).
# Every extension the databases use besides pg_cron is contrib and ships in this image:
# btree_gist, dblink, pg_stat_statements, unaccent, pgcrypto (auto_explain is a contrib module too).
ARG PG_IMAGE=postgres:15.17-alpine3.22@sha256:7af9362ab71f1909fd7ab33e1bb29609aea9b2ff91dbf9ffb354ea88385bd3de

# Stage 1 — compile pg_cron against this image's own server headers (pg_config in /usr/local/bin).
FROM ${PG_IMAGE} AS builder

RUN apk add --no-cache build-base git

ARG PGCRON_VERSION=v1.6.5
RUN git clone --depth 1 --branch ${PGCRON_VERSION} \
        https://github.com/citusdata/pg_cron.git /pg_cron

COPY clang-19-stub.sh /usr/local/bin/clang-19
WORKDIR /pg_cron
# PG15 bakes CLANG=clang-19 into Makefile.global for JIT bitcode; pg_cron is a background worker and its .bc
# files are never used at runtime. The stub creates empty .bc outputs so pgxs completes; only the .so matters.
RUN chmod +x /usr/local/bin/clang-19 \
    && mkdir -p /usr/lib/llvm19/bin \
    && printf '#!/bin/sh\nexit 0\n' > /usr/lib/llvm19/bin/llvm-lto \
    && chmod +x /usr/lib/llvm19/bin/llvm-lto \
    && make PG_CONFIG=/usr/local/bin/pg_config && make PG_CONFIG=/usr/local/bin/pg_config install

# Stage 2 — the official image plus pg_cron's library, control and SQL files only.
FROM ${PG_IMAGE}

COPY --from=builder /usr/local/lib/postgresql/pg_cron.so /usr/local/lib/postgresql/pg_cron.so
COPY --from=builder /usr/local/share/postgresql/extension/pg_cron* /usr/local/share/postgresql/extension/

# shared_preload_libraries (pg_cron,pg_stat_statements,auto_explain) and cron.database_name=postgres are passed
# via the docker run -c "..." flags in terraform/staging/user_data/db_init.sh, NOT baked into the image. -c is the
# postmaster command line: it overrides postgresql.conf and postgresql.auto.conf, so ALTER SYSTEM cannot change the
# preload set on a running cluster — edit db_init.sh and recreate the container.

COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/
