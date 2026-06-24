FROM golang:1.23-alpine AS builder
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
# -p=1 + GOMAXPROCS=1: staging runner has 2 CPUs + modest RAM (see
# oeecloud-worker's Dockerfile for the OOM-kill backstory).
RUN CGO_ENABLED=0 GOOS=linux GOMAXPROCS=1 go build \
    -p=1 -trimpath -ldflags "-s -w" \
    -o /out/mirror-worker-go ./cmd/mirror-worker-go

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/mirror-worker-go /usr/local/bin/mirror-worker-go
USER nonroot:nonroot
EXPOSE 9102
ENTRYPOINT ["/usr/local/bin/mirror-worker-go"]
