# ADR-0057 — data-plane sidecar: node + AWS session-manager-plugin on debian
# (edge-api's alpine/musl image can't run the glibc plugin, hence a dedicated
# minimal debian image with a tiny attack surface).
FROM node:18-bookworm-slim

WORKDIR /app

# Install the official session-manager-plugin (.deb), arch-matched so this image
# builds on both the amd64 dev box and the arm64 staging runner.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) url="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" ;; \
      arm64) url="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb" ;; \
      *) echo "unsupported arch $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "$url" -o /tmp/smp.deb; \
    dpkg -i /tmp/smp.deb; \
    rm -f /tmp/smp.deb; \
    apt-get purge -y --auto-remove curl; \
    rm -rf /var/lib/apt/lists/*; \
    session-manager-plugin --version

COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY server.mjs ./

EXPOSE 8090
USER node
CMD ["node", "server.mjs"]