# Multi-stage build: compile to a static binary on Alpine, then ship a
# distroless runtime. Same pattern as oeecloud-worker for consistency.

FROM golang:1.25-alpine AS builder
WORKDIR /src

# Pull deps first so the layer caches when source changes but deps don't.
COPY go.mod go.sum* ./
RUN go mod download

COPY cmd ./cmd
COPY internal ./internal

# CGO disabled → fully static; -trimpath strips local paths; -ldflags '-s -w'
# drops symbols/debug. -p=1 caps compiler jobs (the staging runner has 2 CPUs).
RUN CGO_ENABLED=0 GOOS=linux GOMAXPROCS=1 go build \
    -p=1 -trimpath -ldflags "-s -w" \
    -o /out/oeecloud-fanout ./cmd/oeecloud-fanout

# Distroless static image: binary + ca-certs + a non-root user. No shell.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/oeecloud-fanout /usr/local/bin/oeecloud-fanout
USER nonroot:nonroot

# /health on 9102 by default (matches HEALTH_PORT in config).
EXPOSE 9102

ENTRYPOINT ["/usr/local/bin/oeecloud-fanout"]
