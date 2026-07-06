# Multi-stage build: compile to a static binary on Alpine, then ship a
# distroless runtime. Same pattern as oeecloud-worker + mirror-worker-go
# per ADR-0009 reuse rule (Errata Correction 2).

FROM golang:1.25-alpine AS builder
WORKDIR /src

# Pull deps first so the layer caches when source changes but deps don't.
COPY go.mod go.sum* ./
RUN go mod download

COPY cmd ./cmd
COPY internal ./internal

# CGO disabled → fully static; -trimpath strips local paths from stack
# traces; -ldflags '-s -w' drops symbol + debug for a smaller binary.
#
# -p=1 caps the compiler to one job at a time. The staging actions-runner
# has 2 CPUs + modest RAM (saw an 18-min OOM-kill on oeecloud-worker's
# parallel build of pgx + amqp091-go). Trade wall-clock for predictable
# memory; the small dep set still builds in ~60s.
RUN CGO_ENABLED=0 GOOS=linux GOMAXPROCS=1 go build \
    -p=1 -trimpath -ldflags "-s -w" \
    -o /out/edge-transformer ./cmd/edge-transformer
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/plc-sim ./cmd/plc-sim

# Intermediate stage: create the outbox directory with nonroot ownership.
# Docker's named-volume mount copies file+dir OWNERSHIP from the container
# image if the volume is empty at first mount. Without this step, the
# volume gets root-owned + nonroot user can't write the SQLite DB.
# ADR-0011 P2 outbox lives here.
FROM alpine AS outbox-dir
RUN mkdir -p /out/var/lib/edge-transformer && chown -R 65532:65532 /out/var/lib

# Distroless `static` image: binary + ca-certs + non-root user. No shell,
# no package manager — minimal attack surface.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/edge-transformer /usr/local/bin/edge-transformer
COPY --from=builder /out/plc-sim /usr/local/bin/plc-sim
COPY --from=outbox-dir /out/var/lib /var/lib
USER nonroot:nonroot

# /healthz on 9102 by default (matches HEALTH_PORT in config).
# Port deliberately differs from oeecloud-worker's 9101 so the two
# services can colocate without collision.
EXPOSE 9102

ENTRYPOINT ["/usr/local/bin/edge-transformer"]
