ARG BUILD_FROM=ghcr.io/hassio-addons/base:21.0.1

# Dependency stages — every external component is a pinned FROM so
# Dependabot's docker ecosystem can track and update it.
FROM ghcr.io/juanfont/headscale:v0.29.3 AS headscale
FROM ghcr.io/tale/headplane:0.7.0 AS headplane
FROM tailscale/tailscale:v1.102.2 AS tailscale

FROM ${BUILD_FROM}

# Runtime packages. nodejs on Alpine 3.24 is 24.18.x (headplane needs >=24.2).
# busybox-extras provides the `busybox httpd` applet used by the standalone
# test harness (test/entrypoint.sh) to mock the HA Supervisor API — the base
# image's busybox does not include it.
RUN apk add --no-cache \
    nodejs \
    nginx \
    jq \
    yq-go \
    curl \
    openssl \
    busybox-extras

COPY --from=headscale /ko-app/headscale /usr/local/bin/headscale
COPY --from=headplane /app /opt/headplane
COPY --from=headplane /usr/libexec/headplane/agent /usr/libexec/headplane/agent
COPY --from=headplane /usr/bin/hp_healthcheck /usr/local/bin/hp_healthcheck
COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscale
COPY --from=tailscale /usr/local/bin/tailscaled /usr/local/bin/tailscaled

# Dedicated non-root users; nginx user is created by the nginx package.
RUN addgroup -S headscale && adduser -S -G headscale -H -s /sbin/nologin headscale \
    && addgroup -S headplane && adduser -S -G headplane -H -s /sbin/nologin headplane \
    && addgroup -S tailscale && adduser -S -G tailscale -H -s /sbin/nologin tailscale

COPY rootfs /

RUN mkdir -p /etc/nginx/servers /var/run/nginx /var/run/tailscale /etc/headplane \
    && chown nginx:nginx /var/run/nginx \
    && chown tailscale:tailscale /var/run/tailscale \
    && find /etc/s6-overlay/s6-rc.d \( -name run -o -name finish \) -exec chmod +x {} +

# hp_healthcheck reads HEADPLANE_LISTEN_FILE; the HEALTHCHECK CMD runs
# without the headplane service's own env, so it must be set here too.
ENV HEADPLANE_LISTEN_FILE=/tmp/headplane-listen

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s \
    CMD /usr/local/bin/hp_healthcheck || exit 1
