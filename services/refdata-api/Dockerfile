# Multi-stage: build in alpine golang, run in distroless.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download 2>/dev/null || true
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' \
    -o /out/refdata-api ./cmd/refdata-api

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/refdata-api /usr/local/bin/refdata-api
EXPOSE 9104
ENTRYPOINT ["/usr/local/bin/refdata-api"]
