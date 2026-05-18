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
# PG15 bakes CLANG=clang-19 into Makefile.global; Alpine only ships clang≤16.
# clang-16 is already present (transitive dep of postgresql15-dev). Alias it
# so pgxs can invoke it by the expected name for .bc JIT bitcode generation.
RUN ln -sf /usr/bin/clang-16 /usr/local/bin/clang-19 \
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
