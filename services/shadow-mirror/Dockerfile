# Multi-stage: build in alpine golang, run in distroless.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download 2>/dev/null || true
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' \
    -o /out/shadow-mirror ./cmd/shadow-mirror

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/shadow-mirror /usr/local/bin/shadow-mirror
EXPOSE 9103
ENTRYPOINT ["/usr/local/bin/shadow-mirror"]
