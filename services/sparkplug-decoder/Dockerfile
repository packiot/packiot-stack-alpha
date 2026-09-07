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
    -o /out/sparkplug-decoder ./cmd/edge-transformer
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/plc-sim ./cmd/plc-sim
# s7-reader: reads a real Siemens S7 PLC and republishes as SparkPlug B — the
# real-client counterpart to plc-sim (S1/#32). CGo-free (gos7 is pure Go), so
# the static build is preserved.
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/s7-reader ./cmd/s7-reader
# modbus-reader / opcua-reader: the Modbus TCP + OPC-UA siblings of s7-reader —
# same additive-producer role, different factory protocol (CPACK runs all three
# across its lines). goburrow/modbus + gopcua/opcua are pure Go, so CGO_ENABLED=0
# still holds.
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/modbus-reader ./cmd/modbus-reader
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/opcua-reader ./cmd/opcua-reader
# s7-softplc: pure-Go S7 soft-PLC for the staging S7 end-to-end test — lets
# s7-reader read a real S7comm endpoint with no PLC, no Snap7/C, no CGo (S1/#32
# PR3). Only run in the "s7" compose profile.
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/s7-softplc ./cmd/s7-softplc
# sparkplug-agent: ADR-0042 Tier-2 transmission plane — consumes raw-tag JSON
# from a connectivity Node-RED over the internal broker and republishes a full
# SparkPlug B edge-node session (alias-ASSIGN, NBIRTH/NDATA/NDEATH-via-LWT,
# RBE, store-and-forward) to the cloud. Same-module reuse of
# internal/{sparkplug,outbox}; net-new code in internal/agent/*.
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/sparkplug-agent ./cmd/sparkplug-agent
# edge-dashboard: ADR-0053 B-minimal on-prem live board. Serves an HTTP view of
# the local current-state SQLite (internal/localstate) on the factory box so the
# shop floor keeps live production visibility during an internet outage. Pure
# stdlib HTTP, CGo-free.
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/edge-dashboard ./cmd/edge-dashboard

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
COPY --from=builder /out/sparkplug-decoder /usr/local/bin/sparkplug-decoder
COPY --from=builder /out/plc-sim /usr/local/bin/plc-sim
COPY --from=builder /out/s7-reader /usr/local/bin/s7-reader
COPY --from=builder /out/modbus-reader /usr/local/bin/modbus-reader
COPY --from=builder /out/opcua-reader /usr/local/bin/opcua-reader
COPY --from=builder /out/s7-softplc /usr/local/bin/s7-softplc
COPY --from=builder /out/sparkplug-agent /usr/local/bin/sparkplug-agent
COPY --from=builder /out/edge-dashboard /usr/local/bin/edge-dashboard
COPY --from=outbox-dir /out/var/lib /var/lib
USER nonroot:nonroot

# /healthz on 9102 by default (matches HEALTH_PORT in config).
# Port deliberately differs from oeecloud-worker's 9101 so the two
# services can colocate without collision.
EXPOSE 9102

ENTRYPOINT ["/usr/local/bin/sparkplug-decoder"]
