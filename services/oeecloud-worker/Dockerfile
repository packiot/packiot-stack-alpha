# Multi-stage build: compile to a static binary on Alpine, then ship a
# distroless runtime. Same pattern as mirror-worker for consistency.

FROM golang:1.23-alpine AS builder
WORKDIR /src

# Pull deps first so the layer caches when source changes but deps don't.
COPY go.mod go.sum* ./
RUN go mod download

COPY cmd ./cmd
COPY internal ./internal

# CGO disabled → fully static; -trimpath strips local paths from stack
# traces; -ldflags '-s -w' drops symbol + debug for a smaller binary.
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath -ldflags "-s -w" \
    -o /out/oeecloud-worker ./cmd/oeecloud-worker

# Distroless `static` image: just the binary + ca-certs + a non-root user.
# No shell, no package manager — minimal attack surface.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/oeecloud-worker /usr/local/bin/oeecloud-worker
USER nonroot:nonroot

# /health on 9101 by default (matches HEALTH_PORT in config).
EXPOSE 9101

ENTRYPOINT ["/usr/local/bin/oeecloud-worker"]
