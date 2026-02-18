# Global ARGs (must be before any FROM to be used in FROM lines)
ARG HEADPLANE_VERSION=0.6.2-beta.5
ARG BUILD_FROM=node:22-alpine

# Stage 1: Extract bashio + tempio from HA community base
FROM ghcr.io/hassio-addons/base:20.0.1 AS hassio-base

# Stage 2: Extract headplane from its Docker image
FROM ghcr.io/tale/headplane:${HEADPLANE_VERSION} AS headplane

# Stage 3: Build the addon
FROM ${BUILD_FROM}

ARG BUILD_ARCH
ARG HEADSCALE_VERSION=0.28.0
ARG S6_OVERLAY_VERSION=3.2.0.2

# Install s6-overlay
RUN apk add --no-cache curl tar xz \
    && ARCH_MAP_aarch64=aarch64 \
    && ARCH_MAP_amd64=x86_64 \
    && eval "S6_ARCH=\${ARCH_MAP_${BUILD_ARCH}}" \
    && curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" \
        | tar Jxf - -C / \
    && curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" \
        | tar Jxf - -C /

# Copy bashio and tempio from HA base image
COPY --from=hassio-base /usr/lib/bashio /usr/lib/bashio
COPY --from=hassio-base /usr/bin/bashio /usr/bin/bashio
COPY --from=hassio-base /usr/bin/tempio /usr/bin/tempio

# Install system packages (nodejs needed for headplane runtime)
RUN apk add --no-cache \
    nodejs \
    nginx \
    bash \
    jq \
    yq-go \
    curl \
    openssl \
    iptables \
    ip6tables

# Install tailscale
RUN apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
    tailscale

# Download headscale binary
RUN ARCH_MAP_aarch64=arm64 \
    && ARCH_MAP_amd64=amd64 \
    && eval "HS_ARCH=\${ARCH_MAP_${BUILD_ARCH}}" \
    && curl -fsSL -o /usr/local/bin/headscale \
        "https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_${HS_ARCH}" \
    && chmod +x /usr/local/bin/headscale

# Copy headplane from its Docker image
COPY --from=headplane /app /opt/headplane
COPY --from=headplane /usr/libexec/headplane/agent /usr/libexec/headplane/agent
COPY --from=headplane /bin/hp_healthcheck /usr/local/bin/hp_healthcheck

# Copy filesystem overlay
COPY rootfs /

# Create required directories
RUN mkdir -p /etc/nginx/servers /var/run/nginx /var/run/tailscale /data

# Ensure all s6 scripts are executable
RUN find /etc/s6-overlay/s6-rc.d -name "run" -exec chmod +x {} \; 2>/dev/null || true \
    && find /etc/s6-overlay/s6-rc.d -name "finish" -exec chmod +x {} \; 2>/dev/null || true

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
    CMD curl --fail -s http://127.0.0.1:3000/admin/login 2>/dev/null || exit 1

ENTRYPOINT ["/init"]
