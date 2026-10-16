# Multi-stage: build in alpine golang, run in distroless.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download 2>/dev/null || true
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' \
    -o /out/analytics-sync ./cmd/shadow-mirror

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/analytics-sync /usr/local/bin/analytics-sync
EXPOSE 9103
ENTRYPOINT ["/usr/local/bin/analytics-sync"]
