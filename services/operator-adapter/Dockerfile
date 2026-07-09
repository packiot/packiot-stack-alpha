# Multi-stage: build in alpine golang, run in distroless nonroot.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download 2>/dev/null || true
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' \
    -o /out/operator-adapter ./cmd/operator-adapter

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/operator-adapter /usr/local/bin/operator-adapter
EXPOSE 8443
ENTRYPOINT ["/usr/local/bin/operator-adapter"]
