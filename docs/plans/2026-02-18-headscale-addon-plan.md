# Headscale HA Addon Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Home Assistant addon that bundles Headscale, Headplane UI, and an optional Tailscale subnet router.

**Architecture:** Multi-stage Dockerfile based on `node:22-alpine` with s6-overlay for process management. Headscale handles TLS via built-in ACME. Headplane connects to headscale internally via localhost. Nginx reverse-proxies headplane for HA ingress and optional direct access.

**Tech Stack:** Headscale 0.28.0, Headplane 0.6.2-beta.5 (extracted from Docker image), s6-overlay v3, nginx, tailscale, bashio (extracted from HA base image), bash/yq/jq for init scripts.

**Design doc:** `docs/plans/2026-02-18-headscale-addon-design.md`

---

## Port Architecture

| Port                | Process   | Purpose                                    |
| ------------------- | --------- | ------------------------------------------ |
| 443/tcp             | headscale | HTTPS API + client connections (ACME TLS)  |
| 80/tcp              | headscale | ACME HTTP-01 challenge                     |
| 3478/udp            | headscale | STUN relay                                 |
| 3000/tcp            | headplane | Web UI (localhost only)                    |
| ingress (dynamic)   | nginx     | HA sidebar access → headplane              |
| 8080/tcp (optional) | nginx     | Direct web access → headplane with HA auth |

Headplane connects to headscale at `https://127.0.0.1:443` with `NODE_TLS_REJECT_UNAUTHORIZED=0` (safe, same container).

---

### Task 1: Create directory scaffold

**Files:**

- Create: `headscale/config.yaml`
- Create: `headscale/build.yaml`
- Create: `headscale/Dockerfile`
- Create: `headscale/DOCS.md` (placeholder)
- Create: `headscale/CHANGELOG.md`
- Create: all `rootfs/etc/s6-overlay/s6-rc.d/` directories
- Create: `README.md`
- Create: `LICENSE.md`

**Step 1: Create all directories**

```bash
mkdir -p headscale/rootfs/etc/{headscale,nginx/templates,s6-overlay/s6-rc.d/{user/contents.d,init-headscale/dependencies.d,init-headplane/dependencies.d,init-tailscale/dependencies.d,init-nginx/dependencies.d,headscale/dependencies.d,headplane/dependencies.d,tailscaled/dependencies.d,nginx/dependencies.d}}
```

**Step 2: Create placeholder files**

Create `headscale/CHANGELOG.md`:

```markdown
# Changelog

## 0.1.0

- Initial release
```

Create `LICENSE.md` with MIT license.

Create `README.md`:

```markdown
# Home Assistant Addon: Headscale

Self-hosted Tailscale control server with Headplane web UI and optional subnet router.

## About

This addon runs [Headscale](https://github.com/juanfont/headscale) (a self-hosted Tailscale control server), [Headplane](https://github.com/tale/headplane) (a web management UI), and an optional Tailscale subnet router for accessing your home network remotely.

## Installation

Add this repository to your Home Assistant addon store, then install the Headscale addon.

See the [documentation](headscale/DOCS.md) for setup instructions.
```

**Step 3: Commit**

```bash
git add -A && git commit -m "chore: scaffold addon directory structure"
```

---

### Task 2: Addon metadata — config.yaml and build.yaml

**Files:**

- Create: `headscale/config.yaml`
- Create: `headscale/build.yaml`

**Step 1: Write config.yaml**

Create `headscale/config.yaml`:

```yaml
name: Headscale
version: dev
slug: headscale
description: Self-hosted Tailscale control server with web UI
url: https://github.com/josh/app-headscale
ingress: true
ingress_port: 0
ingress_stream: true
panel_icon: mdi:vpn
panel_title: Headscale
startup: services
arch:
  - aarch64
  - amd64
init: false
host_network: true
ports:
  443/tcp: 443
  80/tcp: 80
  3478/udp: 3478
  8080/tcp: null
ports_description:
  443/tcp: Headscale server (HTTPS)
  80/tcp: Let's Encrypt certificate challenge
  3478/udp: STUN relay
  8080/tcp: Headplane web UI (not required for Ingress)
auth_api: true
hassio_api: true
map:
  - ssl
privileged:
  - NET_ADMIN
  - NET_RAW
options:
  server_url: ""
  log_level: info
  acme_email: ""
  subnet_router:
    enabled: true
    routes: []
    exit_node: false
schema:
  server_url: url
  log_level: list(trace|debug|info|warning|error)
  acme_email: email
  subnet_router:
    enabled: bool
    routes:
      - str
    exit_node: bool
backup_exclude:
  - "*/headscale/noise_private.key"
```

**Step 2: Write build.yaml**

Create `headscale/build.yaml`:

```yaml
build_from:
  aarch64: node:22-alpine
  amd64: node:22-alpine
args:
  BUILD_ARCH: "{arch}"
```

**Step 3: Commit**

```bash
git add headscale/config.yaml headscale/build.yaml && git commit -m "feat: add addon config.yaml and build.yaml"
```

---

### Task 3: Dockerfile

**Files:**

- Create: `headscale/Dockerfile`

**Step 1: Write the Dockerfile**

Create `headscale/Dockerfile`:

```dockerfile
# Stage 1: Extract bashio + tempio from HA community base
FROM ghcr.io/hassio-addons/base:20.0.1 AS hassio-base

# Stage 2: Extract headplane from its Docker image
ARG HEADPLANE_VERSION=0.6.2-beta.5
FROM ghcr.io/tale/headplane:${HEADPLANE_VERSION} AS headplane

# Stage 3: Build the addon
ARG BUILD_FROM=node:22-alpine
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

# Install system packages
RUN apk add --no-cache \
    nginx \
    bash \
    jq \
    yq-go \
    curl \
    openssl

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

# Create data directory
RUN mkdir -p /data

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
    CMD curl --fail http://127.0.0.1:3000/healthz 2>/dev/null || exit 1

ENTRYPOINT ["/init"]
```

**Step 2: Commit**

```bash
git add headscale/Dockerfile && git commit -m "feat: add multi-stage Dockerfile"
```

---

### Task 4: Default headscale config template

**Files:**

- Create: `headscale/rootfs/etc/headscale/config.yaml`

**Step 1: Write the default headscale config**

This template gets copied to `/data/headscale/config.yaml` on first run. Fields marked with comments are patched by `init-headscale` on every start.

Create `headscale/rootfs/etc/headscale/config.yaml`:

```yaml
# Patched by init-headscale on every start
server_url: https://REPLACE_ME
listen_addr: 0.0.0.0:443
metrics_listen_addr: 127.0.0.1:9090

noise:
  private_key_path: /data/headscale/noise_private.key

# ACME / Let's Encrypt — patched by init-headscale
tls_letsencrypt_hostname: ""
tls_letsencrypt_cache_dir: /data/headscale/cache
tls_letsencrypt_challenge_type: HTTP-01
tls_letsencrypt_listen: ":80"

database:
  type: sqlite
  sqlite:
    path: /data/headscale/db.sqlite

derp:
  server:
    enabled: true
    region_id: 900
    region_code: "ha"
    region_name: "Home Assistant"
    stun_listen_addr: 0.0.0.0:3478
    private_key_path: /data/headscale/derp_server_private.key
  urls:
    - https://controlplane.tailscale.com/derpmap/default
  auto_update_enabled: true

prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48

dns:
  magic_dns: true
  base_domain: headscale.local
  override_local_dns: false
  nameservers:
    global: []

policy:
  mode: database

log:
  level: info
```

**Step 2: Commit**

```bash
git add headscale/rootfs/etc/headscale/config.yaml && git commit -m "feat: add default headscale config template"
```

---

### Task 5: s6 init-headscale oneshot service

**Files:**

- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headscale/type`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headscale/up`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headscale/run`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headscale/dependencies.d/base`

**Step 1: Write the service definition files**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headscale/type`:

```
oneshot
```

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headscale/up`:

```
/etc/s6-overlay/s6-rc.d/init-headscale/run
```

Create empty dependency marker `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headscale/dependencies.d/base`:

```

```

**Step 2: Write the init script**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headscale/run`:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Addon: Headscale
# Configures Headscale server
# ==============================================================================
readonly CONFIG="/data/headscale/config.yaml"
readonly DEFAULT_CONFIG="/etc/headscale/config.yaml"

bashio::log.info "Configuring Headscale..."

# First run: copy default config
if ! bashio::fs.file_exists "${CONFIG}"; then
    bashio::log.info "First run detected, creating default configuration..."
    mkdir -p /data/headscale/cache
    cp "${DEFAULT_CONFIG}" "${CONFIG}"
fi

# Read addon options
server_url=$(bashio::config 'server_url')
acme_email=$(bashio::config 'acme_email')
log_level=$(bashio::config 'log_level')

# Validate required options
if ! bashio::var.has_value "${server_url}"; then
    bashio::log.fatal "server_url is required. Set it to your public domain (e.g., https://vpn.example.com)"
    bashio::exit.nok
fi

if ! bashio::var.has_value "${acme_email}"; then
    bashio::log.fatal "acme_email is required for Let's Encrypt certificate generation"
    bashio::exit.nok
fi

# Patch config with addon options
server_url="${server_url}" \
    yq e --inplace '.server_url = env(server_url)' "${CONFIG}"

# Extract hostname from server_url for ACME
acme_hostname=$(echo "${server_url}" | sed 's|https://||' | sed 's|http://||' | sed 's|/.*||' | sed 's|:.*||')
acme_hostname="${acme_hostname}" \
    yq e --inplace '.tls_letsencrypt_hostname = env(acme_hostname)' "${CONFIG}"

acme_email="${acme_email}" \
    yq e --inplace '.acme_email = env(acme_email)' "${CONFIG}"

log_level="${log_level}" \
    yq e --inplace '.log.level = env(log_level)' "${CONFIG}"

# Ensure critical settings
yq e --inplace '.listen_addr = "0.0.0.0:443"' "${CONFIG}"
yq e --inplace '.metrics_listen_addr = "127.0.0.1:9090"' "${CONFIG}"
yq e --inplace '.database.type = "sqlite"' "${CONFIG}"
yq e --inplace '.database.sqlite.path = "/data/headscale/db.sqlite"' "${CONFIG}"
yq e --inplace '.noise.private_key_path = "/data/headscale/noise_private.key"' "${CONFIG}"
yq e --inplace '.policy.mode = "database"' "${CONFIG}"

bashio::log.info "Headscale configuration complete."
bashio::log.info "Server URL: ${server_url}"
bashio::log.info "ACME hostname: ${acme_hostname}"
```

**Step 3: Make run script executable in Dockerfile**

Note: The Dockerfile `COPY rootfs /` preserves permissions. Ensure the run script is `chmod +x` before building. Add this to the Dockerfile after `COPY rootfs /`:

```dockerfile
RUN chmod +x /etc/s6-overlay/s6-rc.d/*/run /etc/s6-overlay/s6-rc.d/*/finish 2>/dev/null || true
```

**Step 4: Commit**

```bash
git add headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headscale/ && git commit -m "feat: add init-headscale s6 oneshot service"
```

---

### Task 6: s6 headscale longrun service

**Files:**

- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/headscale/type`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/headscale/run`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/headscale/finish`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/headscale/dependencies.d/init-headscale`

**Step 1: Write service definition**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/headscale/type`:

```
longrun
```

Create empty `headscale/rootfs/etc/s6-overlay/s6-rc.d/headscale/dependencies.d/init-headscale`

**Step 2: Write run script**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/headscale/run`:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Addon: Headscale
# Runs the Headscale server
# ==============================================================================

bashio::log.info "Starting Headscale server..."

exec headscale serve --config /data/headscale/config.yaml
```

**Step 3: Write finish script**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/headscale/finish`:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Addon: Headscale
# Halt container on Headscale failure
# ==============================================================================
readonly exit_code_container=$(</run/s6-linux-init-container-results/exitcode)
readonly exit_code_service="${1}"
readonly exit_code_signal="${2}"
readonly service="Headscale"

bashio::log.info \
    "Service ${service} exited with code ${exit_code_service}" \
    "(by signal ${exit_code_signal})"

if [[ "${exit_code_service}" -eq 256 ]]; then
    if [[ "${exit_code_container}" -eq 0 ]]; then
        echo $((128 + exit_code_signal)) > /run/s6-linux-init-container-results/exitcode
    fi
    [[ "${exit_code_signal}" -eq 15 ]] && exec /run/s6/basedir/bin/halt
elif [[ "${exit_code_service}" -ne 0 ]]; then
    if [[ "${exit_code_container}" -eq 0 ]]; then
        echo "${exit_code_service}" > /run/s6-linux-init-container-results/exitcode
    fi
    exec /run/s6/basedir/bin/halt
fi
```

**Step 4: Commit**

```bash
git add headscale/rootfs/etc/s6-overlay/s6-rc.d/headscale/ && git commit -m "feat: add headscale s6 longrun service"
```

---

### Task 7: s6 init-headplane oneshot service

**Files:**

- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headplane/type`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headplane/up`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headplane/run`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headplane/dependencies.d/headscale`

**Step 1: Write service definition**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headplane/type`:

```
oneshot
```

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headplane/up`:

```
/etc/s6-overlay/s6-rc.d/init-headplane/run
```

Create empty `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headplane/dependencies.d/headscale`

**Step 2: Write init script**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headplane/run`:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Addon: Headscale
# Configures Headplane web UI
# ==============================================================================
readonly API_KEY_FILE="/data/headplane/api_key"
readonly COOKIE_SECRET_FILE="/data/headplane/cookie_secret"

bashio::log.info "Configuring Headplane..."

mkdir -p /data/headplane/data

# Wait for headscale to be ready
bashio::log.info "Waiting for Headscale API to be available..."
bashio::net.wait_for 443 127.0.0.1 300

# Generate or read API key
if ! bashio::fs.file_exists "${API_KEY_FILE}"; then
    bashio::log.info "Generating Headscale API key for Headplane..."
    api_key=$(headscale apikeys create --config /data/headscale/config.yaml -o json 2>/dev/null | jq -r '.apiKey // .api_key // .')
    if ! bashio::var.has_value "${api_key}"; then
        bashio::log.fatal "Failed to generate Headscale API key"
        bashio::exit.nok
    fi
    echo "${api_key}" > "${API_KEY_FILE}"
    bashio::log.info "API key generated and stored."
else
    api_key=$(cat "${API_KEY_FILE}")
    bashio::log.info "Using stored API key."
fi

# Generate or read cookie secret
if ! bashio::fs.file_exists "${COOKIE_SECRET_FILE}"; then
    openssl rand -hex 32 > "${COOKIE_SECRET_FILE}"
    bashio::log.info "Cookie secret generated."
fi
cookie_secret=$(cat "${COOKIE_SECRET_FILE}")

# Write headplane environment file for s6 contenv
# These environment variables are picked up by the headplane process
echo "${api_key}" > /var/run/s6/container_environment/HEADSCALE_API_KEY
echo "https://127.0.0.1:443" > /var/run/s6/container_environment/HEADSCALE_URL
echo "/data/headscale/config.yaml" > /var/run/s6/container_environment/HEADSCALE_CONFIG
echo "${cookie_secret}" > /var/run/s6/container_environment/COOKIE_SECRET
echo "/data/headplane/data" > /var/run/s6/container_environment/DATA_DIRECTORY
echo "0" > /var/run/s6/container_environment/NODE_TLS_REJECT_UNAUTHORIZED

bashio::log.info "Headplane configuration complete."
```

**Step 3: Commit**

```bash
git add headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headplane/ && git commit -m "feat: add init-headplane s6 oneshot service"
```

---

### Task 8: s6 headplane longrun service

**Files:**

- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/headplane/type`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/headplane/run`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/headplane/finish`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/headplane/dependencies.d/init-headplane`

**Step 1: Write service definition**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/headplane/type`:

```
longrun
```

Create empty `headscale/rootfs/etc/s6-overlay/s6-rc.d/headplane/dependencies.d/init-headplane`

**Step 2: Write run script**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/headplane/run`:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Addon: Headscale
# Runs the Headplane web UI
# ==============================================================================

bashio::log.info "Starting Headplane..."

cd /opt/headplane || bashio::exit.nok "Headplane directory not found"

exec node build/server/index.js
```

**Step 3: Write finish script** (same pattern as headscale)

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/headplane/finish`:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Addon: Headscale
# Halt container on Headplane failure
# ==============================================================================
readonly exit_code_container=$(</run/s6-linux-init-container-results/exitcode)
readonly exit_code_service="${1}"
readonly exit_code_signal="${2}"
readonly service="Headplane"

bashio::log.info \
    "Service ${service} exited with code ${exit_code_service}" \
    "(by signal ${exit_code_signal})"

if [[ "${exit_code_service}" -eq 256 ]]; then
    if [[ "${exit_code_container}" -eq 0 ]]; then
        echo $((128 + exit_code_signal)) > /run/s6-linux-init-container-results/exitcode
    fi
    [[ "${exit_code_signal}" -eq 15 ]] && exec /run/s6/basedir/bin/halt
elif [[ "${exit_code_service}" -ne 0 ]]; then
    if [[ "${exit_code_container}" -eq 0 ]]; then
        echo "${exit_code_service}" > /run/s6-linux-init-container-results/exitcode
    fi
    exec /run/s6/basedir/bin/halt
fi
```

**Step 4: Commit**

```bash
git add headscale/rootfs/etc/s6-overlay/s6-rc.d/headplane/ && git commit -m "feat: add headplane s6 longrun service"
```

---

### Task 9: s6 init-tailscale oneshot service

**Files:**

- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-tailscale/type`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-tailscale/up`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-tailscale/run`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-tailscale/dependencies.d/headscale`

**Step 1: Write service definition**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-tailscale/type`:

```
oneshot
```

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-tailscale/up`:

```
/etc/s6-overlay/s6-rc.d/init-tailscale/run
```

Create empty `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-tailscale/dependencies.d/headscale`

**Step 2: Write init script**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-tailscale/run`:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Addon: Headscale
# Configures Tailscale subnet router
# ==============================================================================

# Check if subnet router is enabled
if ! bashio::config.true 'subnet_router.enabled'; then
    bashio::log.info "Subnet router is disabled, skipping Tailscale configuration."
    exit 0
fi

bashio::log.info "Configuring Tailscale subnet router..."

readonly TS_STATE_DIR="/data/tailscale/state"
readonly TS_AUTH_KEY_FILE="/data/tailscale/auth_key"

mkdir -p "${TS_STATE_DIR}"

# Wait for headscale to be ready
bashio::net.wait_for 443 127.0.0.1 300

server_url=$(bashio::config 'server_url')

# Create subnet-router user if it doesn't exist
bashio::log.info "Ensuring subnet-router user exists..."
headscale users create subnet-router --config /data/headscale/config.yaml 2>/dev/null || true

# Generate pre-auth key for subnet router (reusable, long-lived)
if ! bashio::fs.file_exists "${TS_AUTH_KEY_FILE}"; then
    bashio::log.info "Generating pre-auth key for subnet router..."
    auth_key=$(headscale preauthkeys create \
        --user subnet-router \
        --reusable \
        --expiration 87600h \
        --config /data/headscale/config.yaml \
        -o json 2>/dev/null | jq -r '.preAuthKey // .preauthkey // .key // .')
    if ! bashio::var.has_value "${auth_key}"; then
        bashio::log.fatal "Failed to generate pre-auth key"
        bashio::exit.nok
    fi
    echo "${auth_key}" > "${TS_AUTH_KEY_FILE}"
    bashio::log.info "Pre-auth key generated."
else
    bashio::log.info "Using stored pre-auth key."
fi

# Auto-detect LAN routes if none configured
routes=()
configured_routes=$(bashio::config 'subnet_router.routes')
if bashio::var.has_value "${configured_routes}" && [[ "${configured_routes}" != "[]" ]]; then
    # Use user-configured routes
    for route in $(bashio::config 'subnet_router.routes'); do
        routes+=("${route}")
    done
    bashio::log.info "Using configured routes: ${routes[*]}"
else
    # Auto-detect LAN subnet
    bashio::log.info "Auto-detecting LAN routes..."
    for iface in $(ip -o -4 addr show | awk '{print $4}' | grep -v '127.0.0.1' | grep -v '172.30.' | head -1); do
        routes+=("${iface}")
        bashio::log.info "Detected route: ${iface}"
    done
fi

# Build routes string
route_str=$(IFS=,; echo "${routes[*]}")

# Store configuration for the tailscaled longrun service
echo "${server_url}" > /var/run/s6/container_environment/TS_LOGIN_SERVER
echo "${route_str}" > /var/run/s6/container_environment/TS_ROUTES
echo "${TS_STATE_DIR}" > /var/run/s6/container_environment/TS_STATE_DIR

# Store exit node flag
if bashio::config.true 'subnet_router.exit_node'; then
    echo "true" > /var/run/s6/container_environment/TS_EXIT_NODE
else
    echo "false" > /var/run/s6/container_environment/TS_EXIT_NODE
fi

bashio::log.info "Tailscale subnet router configuration complete."
bashio::log.info "Routes: ${route_str}"
```

**Step 3: Commit**

```bash
git add headscale/rootfs/etc/s6-overlay/s6-rc.d/init-tailscale/ && git commit -m "feat: add init-tailscale s6 oneshot service"
```

---

### Task 10: s6 tailscaled longrun service

**Files:**

- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/tailscaled/type`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/tailscaled/run`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/tailscaled/finish`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/tailscaled/dependencies.d/init-tailscale`

**Step 1: Write service definition**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/tailscaled/type`:

```
longrun
```

Create empty `headscale/rootfs/etc/s6-overlay/s6-rc.d/tailscaled/dependencies.d/init-tailscale`

**Step 2: Write run script**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/tailscaled/run`:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Addon: Headscale
# Runs the Tailscale subnet router daemon
# ==============================================================================

# Skip if subnet router is disabled
if ! bashio::config.true 'subnet_router.enabled'; then
    bashio::log.info "Subnet router disabled, sleeping indefinitely..."
    exec sleep infinity
fi

bashio::log.info "Starting Tailscale daemon..."

readonly TS_STATE_DIR="${TS_STATE_DIR:-/data/tailscale/state}"
readonly TS_AUTH_KEY_FILE="/data/tailscale/auth_key"
readonly TS_SOCKET="/var/run/tailscale/tailscaled.sock"

mkdir -p /var/run/tailscale

# Start tailscaled in the background
tailscaled \
    --state="${TS_STATE_DIR}" \
    --socket="${TS_SOCKET}" \
    --tun=userspace-networking &

TAILSCALED_PID=$!

# Wait for tailscaled to be ready
sleep 3

# Read auth key and login
auth_key=$(cat "${TS_AUTH_KEY_FILE}")

declare -a ts_args
ts_args+=(--login-server "${TS_LOGIN_SERVER}")
ts_args+=(--authkey "${auth_key}")
ts_args+=(--hostname "ha-subnet-router")

if bashio::var.has_value "${TS_ROUTES}"; then
    ts_args+=(--advertise-routes "${TS_ROUTES}")
fi

if [[ "${TS_EXIT_NODE}" == "true" ]]; then
    ts_args+=(--advertise-exit-node)
fi

bashio::log.info "Connecting to Headscale at ${TS_LOGIN_SERVER}..."
tailscale --socket="${TS_SOCKET}" up "${ts_args[@]}"

bashio::log.info "Tailscale subnet router connected."

# Wait for tailscaled
wait ${TAILSCALED_PID}
```

**Step 3: Write finish script**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/tailscaled/finish`:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Addon: Headscale
# Halt container on Tailscale failure
# ==============================================================================
readonly exit_code_container=$(</run/s6-linux-init-container-results/exitcode)
readonly exit_code_service="${1}"
readonly exit_code_signal="${2}"
readonly service="Tailscale"

bashio::log.info \
    "Service ${service} exited with code ${exit_code_service}" \
    "(by signal ${exit_code_signal})"

if [[ "${exit_code_service}" -eq 256 ]]; then
    if [[ "${exit_code_container}" -eq 0 ]]; then
        echo $((128 + exit_code_signal)) > /run/s6-linux-init-container-results/exitcode
    fi
    [[ "${exit_code_signal}" -eq 15 ]] && exec /run/s6/basedir/bin/halt
elif [[ "${exit_code_service}" -ne 0 ]]; then
    if [[ "${exit_code_container}" -eq 0 ]]; then
        echo "${exit_code_service}" > /run/s6-linux-init-container-results/exitcode
    fi
    exec /run/s6/basedir/bin/halt
fi
```

**Step 4: Commit**

```bash
git add headscale/rootfs/etc/s6-overlay/s6-rc.d/tailscaled/ && git commit -m "feat: add tailscaled s6 longrun service"
```

---

### Task 11: Nginx config and templates

**Files:**

- Create: `headscale/rootfs/etc/nginx/nginx.conf`
- Create: `headscale/rootfs/etc/nginx/templates/ingress.gtpl`
- Create: `headscale/rootfs/etc/nginx/templates/direct.gtpl`
- Create: `headscale/rootfs/etc/nginx/templates/upstream.gtpl`

**Step 1: Write nginx.conf**

Create `headscale/rootfs/etc/nginx/nginx.conf`:

```nginx
worker_processes auto;
pid /var/run/nginx.pid;
error_log /dev/stderr;
daemon off;

events {
    worker_connections 512;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log off;
    sendfile on;
    keepalive_timeout 65;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    include /etc/nginx/servers/*.conf;
}
```

**Step 2: Write upstream template**

Create `headscale/rootfs/etc/nginx/templates/upstream.gtpl`:

```
upstream headplane {
    server 127.0.0.1:{{ .port }};
}
```

**Step 3: Write ingress template**

Create `headscale/rootfs/etc/nginx/templates/ingress.gtpl`:

```
server {
    listen {{ .interface }}:{{ .port }} default_server;

    location / {
        allow   172.30.32.2;
        deny    all;

        proxy_pass http://headplane;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**Step 4: Write direct access template**

Create `headscale/rootfs/etc/nginx/templates/direct.gtpl`:

```
server {
    listen {{ .port }};

    location = /authentication {
        internal;
        proxy_pass http://supervisor/auth;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Supervisor-Token "{{ .supervisor_token }}";
    }

    location / {
        auth_request /authentication;
        auth_request_set $auth_header $upstream_http_x_hassio_user;
        proxy_set_header X-Hassio-User $auth_header;

        proxy_pass http://headplane;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**Step 5: Create nginx servers directory in Dockerfile**

Add to Dockerfile (before COPY rootfs): `RUN mkdir -p /etc/nginx/servers`

**Step 6: Commit**

```bash
git add headscale/rootfs/etc/nginx/ && git commit -m "feat: add nginx config and ingress/direct templates"
```

---

### Task 12: s6 init-nginx and nginx services

**Files:**

- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-nginx/type`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-nginx/up`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-nginx/run`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-nginx/dependencies.d/headscale`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/nginx/type`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/nginx/run`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/nginx/finish`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/nginx/dependencies.d/init-nginx`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/nginx/dependencies.d/headplane`

**Step 1: Write init-nginx oneshot**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-nginx/type`:

```
oneshot
```

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-nginx/up`:

```
/etc/s6-overlay/s6-rc.d/init-nginx/run
```

Create empty `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-nginx/dependencies.d/headscale`

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-nginx/run`:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Addon: Headscale
# Configures Nginx reverse proxy
# ==============================================================================

bashio::log.info "Configuring Nginx..."

mkdir -p /etc/nginx/servers

# Generate upstream config
bashio::var.json \
    port "^3000" \
    | tempio \
        -template /etc/nginx/templates/upstream.gtpl \
        -out /etc/nginx/servers/upstream.conf

# Generate ingress config
bashio::var.json \
    interface "$(bashio::addon.ip_address)" \
    port "^$(bashio::addon.ingress_port)" \
    | tempio \
        -template /etc/nginx/templates/ingress.gtpl \
        -out /etc/nginx/servers/ingress.conf

# Generate direct access config if port 8080 is mapped
if bashio::var.has_value "$(bashio::addon.port 8080)"; then
    bashio::log.info "Direct access enabled on port $(bashio::addon.port 8080)"
    bashio::var.json \
        port "^$(bashio::addon.port 8080)" \
        supervisor_token "${SUPERVISOR_TOKEN}" \
        | tempio \
            -template /etc/nginx/templates/direct.gtpl \
            -out /etc/nginx/servers/direct.conf
fi

bashio::log.info "Nginx configuration complete."
```

**Step 2: Write nginx longrun**

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/nginx/type`:

```
longrun
```

Create empty files:

- `headscale/rootfs/etc/s6-overlay/s6-rc.d/nginx/dependencies.d/init-nginx`
- `headscale/rootfs/etc/s6-overlay/s6-rc.d/nginx/dependencies.d/headplane`

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/nginx/run`:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Addon: Headscale
# Runs the Nginx reverse proxy
# ==============================================================================

# Wait for headplane to become available
bashio::net.wait_for 3000 127.0.0.1 300

bashio::log.info "Starting Nginx..."
exec nginx -c /etc/nginx/nginx.conf
```

Create `headscale/rootfs/etc/s6-overlay/s6-rc.d/nginx/finish`:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Addon: Headscale
# Halt container on Nginx failure
# ==============================================================================
readonly exit_code_container=$(</run/s6-linux-init-container-results/exitcode)
readonly exit_code_service="${1}"
readonly exit_code_signal="${2}"
readonly service="Nginx"

bashio::log.info \
    "Service ${service} exited with code ${exit_code_service}" \
    "(by signal ${exit_code_signal})"

if [[ "${exit_code_service}" -eq 256 ]]; then
    if [[ "${exit_code_container}" -eq 0 ]]; then
        echo $((128 + exit_code_signal)) > /run/s6-linux-init-container-results/exitcode
    fi
    [[ "${exit_code_signal}" -eq 15 ]] && exec /run/s6/basedir/bin/halt
elif [[ "${exit_code_service}" -ne 0 ]]; then
    if [[ "${exit_code_container}" -eq 0 ]]; then
        echo "${exit_code_service}" > /run/s6-linux-init-container-results/exitcode
    fi
    exec /run/s6/basedir/bin/halt
fi
```

**Step 3: Commit**

```bash
git add headscale/rootfs/etc/s6-overlay/s6-rc.d/init-nginx/ headscale/rootfs/etc/s6-overlay/s6-rc.d/nginx/ && git commit -m "feat: add init-nginx and nginx s6 services"
```

---

### Task 13: s6 service bundle (user/contents.d)

**Files:**

- Create: empty marker files in `headscale/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/`

**Step 1: Create bundle marker files**

Create one empty file for each service in `headscale/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/`:

- `init-headscale`
- `headscale`
- `init-headplane`
- `headplane`
- `init-tailscale`
- `tailscaled`
- `init-nginx`
- `nginx`

Each file is empty — its mere existence registers the service with s6-rc.

```bash
cd headscale/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d
touch init-headscale headscale init-headplane headplane init-tailscale tailscaled init-nginx nginx
```

**Step 2: Commit**

```bash
git add headscale/rootfs/etc/s6-overlay/s6-rc.d/user/ && git commit -m "feat: add s6 service bundle"
```

---

### Task 14: Finalize Dockerfile with chmod and mkdir

**Files:**

- Modify: `headscale/Dockerfile`

**Step 1: Add post-COPY commands**

After the `COPY rootfs /` line in the Dockerfile, add:

```dockerfile
# Create required directories
RUN mkdir -p /etc/nginx/servers /var/run/nginx /var/run/tailscale /data

# Ensure all s6 scripts are executable
RUN find /etc/s6-overlay/s6-rc.d -name "run" -exec chmod +x {} \; \
    && find /etc/s6-overlay/s6-rc.d -name "finish" -exec chmod +x {} \;
```

**Step 2: Commit**

```bash
git add headscale/Dockerfile && git commit -m "fix: add chmod and mkdir to Dockerfile"
```

---

### Task 15: Docker build smoke test

**Step 1: Build the Docker image for amd64**

```bash
cd headscale
docker build --build-arg BUILD_ARCH=amd64 -t app-headscale:dev .
```

Expected: Build completes without errors. All stages resolve. Binaries are downloaded.

**Step 2: Verify image contents**

```bash
docker run --rm --entrypoint="" app-headscale:dev ls -la /usr/local/bin/headscale
docker run --rm --entrypoint="" app-headscale:dev ls -la /opt/headplane/build/server/index.js
docker run --rm --entrypoint="" app-headscale:dev which tailscale
docker run --rm --entrypoint="" app-headscale:dev which nginx
docker run --rm --entrypoint="" app-headscale:dev bashio --version
docker run --rm --entrypoint="" app-headscale:dev headscale version
```

Expected: All binaries present and executable.

**Step 3: Fix any issues found, rebuild, and commit if changes made**

```bash
git add -A && git commit -m "fix: resolve Docker build issues"
```

---

### Task 16: Write DOCS.md

**Files:**

- Create: `headscale/DOCS.md`

**Step 1: Write user documentation**

Create `headscale/DOCS.md` with these sections:

1. **Prerequisites** — domain name, port forwarding (443, 80, 3478/udp), email for Let's Encrypt
2. **Quick Start** — configure server_url + acme_email, start addon, open sidebar
3. **Connecting Clients** — per-platform `tailscale up --login-server` commands:
   - Linux: `tailscale up --login-server https://vpn.example.com --authkey YOUR_KEY`
   - macOS: same command
   - Windows: Tailscale GUI → Use alternate server
   - iOS/Android: alternate server configuration
4. **Subnet Router** — explanation of auto-detect vs custom routes, exit node toggle, how to verify
5. **Managing Your Network** — brief overview pointing to headplane UI for users, pre-auth keys, devices, ACLs, routes
6. **Configuration Options** — table of all addon options from config.yaml schema
7. **Troubleshooting** — ACME cert issues, client can't connect, subnet router not working, checking logs

**Step 2: Commit**

```bash
git add headscale/DOCS.md && git commit -m "docs: add user-facing addon documentation"
```

---

### Task 17: Integration test — full container startup

**Step 1: Run container with test config**

```bash
docker run --rm -d --name headscale-test \
    -e SUPERVISOR_TOKEN=test \
    -v /tmp/headscale-test:/data \
    app-headscale:dev
```

**Step 2: Check logs for startup sequence**

```bash
docker logs -f headscale-test
```

Expected log lines (in order):

1. "Configuring Headscale..."
2. Config validation errors (server_url required) — this is expected without real options

**Step 3: Clean up**

```bash
docker stop headscale-test 2>/dev/null
rm -rf /tmp/headscale-test
```

**Step 4: Document any issues for follow-up**

Note: Full integration testing requires the HA Supervisor environment. The Docker build + startup test validates the image structure and s6 service definitions. Real end-to-end testing happens after installing in Home Assistant.

---

### Task 18: Final commit — polish and tag

**Step 1: Review all files**

```bash
git status
git log --oneline
```

**Step 2: Create initial release tag**

```bash
git tag v0.1.0
```

---

## Dependency Graph

```
Task 1  (scaffold)
  ├── Task 2  (config.yaml, build.yaml)
  ├── Task 3  (Dockerfile)
  ├── Task 4  (headscale config template)
  ├── Task 5  (init-headscale) → Task 6  (headscale longrun)
  ├── Task 7  (init-headplane) → Task 8  (headplane longrun)
  ├── Task 9  (init-tailscale) → Task 10 (tailscaled longrun)
  ├── Task 11 (nginx templates) → Task 12 (init-nginx + nginx)
  └── Task 13 (bundle)
Task 14 (Dockerfile fixups) → Task 15 (build smoke test)
Task 16 (DOCS.md)
Task 17 (integration test)
Task 18 (polish + tag)
```

Tasks 2-13 can largely be parallelized. Tasks 14-18 are sequential.
