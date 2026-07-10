# Multi-stage build: compile a fully static binary on Alpine, then ship a
# distroless runtime. Same pattern as oeecloud-worker for consistency.

FROM golang:1.25-alpine AS builder
WORKDIR /src

# Pull deps first so the layer caches when source changes but deps don't.
COPY go.mod go.sum* ./
RUN go mod download

COPY cmd ./cmd
COPY internal ./internal

# CGO disabled → fully static; -trimpath strips local paths; -ldflags '-s -w'
# drops symbols + debug for a smaller binary. -p=1/GOMAXPROCS=1 caps compiler
# parallelism to stay within the modest staging runner's RAM (see the
# oeecloud-worker Dockerfile note on the OOM-kill).
RUN CGO_ENABLED=0 GOOS=linux GOMAXPROCS=1 go build \
    -p=1 -trimpath -ldflags "-s -w" \
    -o /out/ingest-shim ./cmd/ingest-shim

# Distroless `static` image: binary + ca-certs + non-root user. No shell,
# no package manager — minimal attack surface. The Docker healthcheck uses
# the binary's own `--healthcheck` subcommand since there's no curl/wget.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/ingest-shim /usr/local/bin/ingest-shim
USER nonroot:nonroot

# Public TLS API on 8444, Prometheus metrics on 9105.
EXPOSE 8444
EXPOSE 9105

ENTRYPOINT ["/usr/local/bin/ingest-shim"]
