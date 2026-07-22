# Multi-stage: build in alpine golang, run in distroless. Mirrors
# services/refdata-api/Dockerfile.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download 2>/dev/null || true
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' \
    -o /out/barcode-service ./cmd/barcode-service

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/barcode-service /usr/local/bin/barcode-service
EXPOSE 8446
ENTRYPOINT ["/usr/local/bin/barcode-service"]
