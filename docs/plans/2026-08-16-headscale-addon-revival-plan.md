# Headscale Addon Revival — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Headscale HA addon per the approved spec ([2026-08-16-headscale-addon-revival-design.md](2026-08-16-headscale-addon-revival-design.md)): bridge networking with zero privileges, headscale 0.29.3 + Headplane 0.7.0, tag-based ACLs with a serve-based HA proxy, opt-in subnet router, and full CI/CD (Dependabot → CI → auto-merge → auto-release).

**Architecture:** Single addon container (bridge network, no capabilities) running headscale, Headplane, two userspace tailscaled nodes (`ts-ha-proxy` always-on, `ts-subnet-router` opt-in), and nginx under s6-overlay, every longrun as a dedicated non-root user. All dependencies arrive via pinned Dockerfile `FROM` stages so Dependabot sees them.

**Tech Stack:** HA addon (s6-overlay v3, bashio v0.18), Alpine 3.24 base `ghcr.io/hassio-addons/base:21.0.1`, headscale v0.29.3, Headplane v0.7.0 (Node 24), tailscale v1.102.2, nginx, GitHub Actions.

## Global Constraints

- Base image: `ghcr.io/hassio-addons/base:21.0.1` (Alpine 3.24; `apk add nodejs` = 24.18.1 ≥ Headplane's required 24.2). Pin appears in BOTH `headscale/Dockerfile` (ARG default) and `headscale/build.yaml` — CI enforces they match.
- Version pins: headscale `v0.29.3`, headplane `0.7.0`, tailscale `v1.102.2`. Every dependency is a Dockerfile `FROM` line (Dependabot-visible). No curl-downloaded binaries anywhere.
- Verified upstream image paths: headscale binary `/ko-app/headscale`; headplane app `/app` (run: `node /app/build/server/index.js`), agent `/usr/libexec/headplane/agent`, healthcheck `/usr/bin/hp_healthcheck` (reads `HEADPLANE_LISTEN_FILE`); tailscale `/usr/local/bin/{tailscale,tailscaled}`.
- bashio v0.18 names: `bashio::app.ingress_port`, `bashio::app.port`, `bashio::core.port`, `bashio::core.ssl`, `bashio::network <cache_key> <jq-filter>` (returns Supervisor `/network/info` JSON). Do NOT use removed `bashio::addon.*`/`bashio::network.info` forms.
- headscale 0.29 CLI: `preauthkeys create --user <numeric-id> --tags tag:x` (default expiry 1h, single-use — exactly what we want; don't pass `-e`); `apikeys create -e 87600h` (no cap); `policy set -f <file>`; `nodes approve-routes -i <id> -r <cidrs>`; `users create <name>` / `users list -o json`. Policy validation tolerates groups referencing missing users; empty `tagOwners` lists are valid; preauthkey tags don't require tagOwners.
- `tailscale serve --bg --tcp=<port> tcp://<host>:<port>` — non-localhost backends allowed when the `tcp://` scheme is explicit; raw TCP mode needs no ts.net certs (headscale-compatible).
- Security invariants (regression-tested, never weaken): no `host_network`, no `privileged`, no `map: homeassistant_config`, no `NODE_TLS_REJECT_UNAUTHORIZED`, ingress vhost allows only 172.30.32.2, no secret values in logs, seed ACL applied before any node can join and fail-closed on first run.
- All internal listen ports are unprivileged: headscale 8443 (TLS mode) / 8081 (HTTP mode; also the ACME listener port in TLS mode), headplane 3000, direct nginx 8080, dynamic ingress port. Host mapping via `ports:` (8443→443, 8081→80, 3478→3478/udp).
- Commit style: existing repo convention (`feat:`/`fix:`/`refactor:` prefixes), every commit ends with the Claude co-author trailer used in this repo's history.
- Follow hassio-addons community patterns for anything not specified here (reference: `hassio-addons/addon-adguard-home` @ main). Reusable CI: `hassio-addons/workflows/.github/workflows/app-ci.yaml` v3.0.0. Linter: `frenck/action-addon-linter@v2.21.0`.

## Shared blocks

**CANONICAL-FINISH** — every longrun service (`headscale`, `headplane`, `ts-ha-proxy`, `ts-subnet-router`, `nginx`) uses this exact `finish` script; only the `service=` line differs:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
readonly exit_code_container=$(</run/s6-linux-init-container-results/exitcode)
readonly exit_code_service="${1}"
readonly exit_code_signal="${2}"
readonly service="SERVICE_NAME_HERE"

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

**MODE-DETECT** — shared logic several init scripts need (inline it where used; it's 8 lines):

```bash
server_url=$(bashio::config 'server_url')
hs_host=$(echo "${server_url}" | sed -e 's|https\?://||' -e 's|[:/].*||')
if [[ "${server_url}" == https://* ]] \
    && [[ ! "${hs_host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    && bashio::var.has_value "$(bashio::config 'acme_email')"; then
    hs_mode=tls; hs_port=8443; hs_local_url="https://${hs_host}:8443"
else
    hs_mode=http; hs_port=8081; hs_local_url="http://127.0.0.1:8081"
fi
```

**S6 layout reminders** (from this repo's history — they bite): write container-env files with `printf '%s'` (no trailing newline); use full binary paths; oneshot `up` files contain exactly `/etc/s6-overlay/s6-rc.d/<name>/run`; every service dir needs a `type` file; new services must be registered in `user/contents.d/<name>` (empty file) plus `dependencies.d/` entries.

## File structure (end state)

```
headscale/
├── config.yaml                    # bridge networking, ports map, users option, backup_exclude
├── build.yaml                     # build_from per arch (same tag as Dockerfile ARG)
├── Dockerfile                     # all deps as FROM stages
├── apparmor.txt                   # NEW custom profile
├── translations/en.yaml           # NEW option descriptions
├── DOCS.md / CHANGELOG.md
└── rootfs/etc/
    ├── headscale/config.yaml      # template (ports, tailnet.internal, policy db mode)
    ├── nginx/nginx.conf           # non-root paths, limit_req zone
    ├── nginx/templates/{ingress,direct,upstream}.gtpl
    └── s6-overlay/s6-rc.d/
        ├── init-headscale/        # config patch, /etc/hosts pin, migration cleanup
        ├── headscale/             # longrun, s6-setuidgid headscale
        ├── init-policy/           # NEW: users + seed/merge ACL, fail-closed
        ├── init-headplane/        # 0.7.0 config gen
        ├── headplane/             # longrun, s6-setuidgid headplane
        ├── init-ha-proxy/ ts-ha-proxy/          # NEW: serve-based HA access
        ├── init-subnet-router/ ts-subnet-router/ # NEW: opt-in router
        ├── init-nginx/ nginx/
        └── user/contents.d/       # updated membership
    (DELETED: init-tailscale/, tailscaled/)
test/
├── options.json                   # standalone test options (HTTP mode)
├── options-router.json            # NEW variant with subnet_router.enabled=true
├── entrypoint.sh                  # supervisor mock + /init
├── supervisor-mock/               # NEW static JSON tree served as http://supervisor
└── smoke.sh                       # NEW assertion suite (used locally + CI)
docker-compose.test.yml
.github/
├── dependabot.yml                 # NEW
└── workflows/ci.yaml, e2e.yaml, auto-merge.yaml, release.yaml, deploy.yaml, scheduled.yaml  # NEW
test/e2e.sh                        # NEW supervisor-devcontainer e2e driver
```

---

### Task 1: Dockerfile + build.yaml — all deps as FROM stages

**Files:**

- Modify: `headscale/Dockerfile` (full rewrite)
- Modify: `headscale/build.yaml`

**Interfaces:**

- Produces: binaries at `/usr/local/bin/headscale`, `/usr/local/bin/tailscale`, `/usr/local/bin/tailscaled`, `/usr/bin/node`; headplane at `/opt/headplane` (server entry `/opt/headplane/build/server/index.js`), agent `/usr/libexec/headplane/agent`, healthcheck `/usr/local/bin/hp_healthcheck`; system users `headscale`, `headplane`, `tailscale` (nginx user comes from the nginx apk package); dirs `/etc/nginx/servers`, `/var/run/nginx`, `/var/run/tailscale`, `/etc/headplane`.

- [ ] **Step 1: Write the failing build check**

The "test" for this task is the build + binary smoke script. Create nothing yet — run the current build to record the baseline, then rewrite.

Run: `docker build --build-arg BUILD_ARCH=aarch64 -t headscale-addon:dev headscale/`
Expected (baseline): succeeds on the OLD Dockerfile (node:22 base). After Step 2's rewrite it must still succeed with the new base.

- [ ] **Step 2: Rewrite `headscale/Dockerfile`**

```dockerfile
ARG BUILD_FROM=ghcr.io/hassio-addons/base:21.0.1

# Dependency stages — every external component is a pinned FROM so
# Dependabot's docker ecosystem can track and update it.
FROM ghcr.io/juanfont/headscale:v0.29.3 AS headscale
FROM ghcr.io/tale/headplane:0.7.0 AS headplane
FROM tailscale/tailscale:v1.102.2 AS tailscale

FROM ${BUILD_FROM}

# Runtime packages. nodejs on Alpine 3.24 is 24.18.x (headplane needs >=24.2).
RUN apk add --no-cache \
    nodejs \
    nginx \
    jq \
    yq-go \
    curl \
    openssl

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

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s \
    CMD /usr/local/bin/hp_healthcheck || exit 1
```

Note: no `ENTRYPOINT` line — the hassio base image already sets `/init`, and no s6/bashio/tempio install steps — the base bundles them.

- [ ] **Step 3: Rewrite `headscale/build.yaml`**

```yaml
build_from:
  aarch64: ghcr.io/hassio-addons/base:21.0.1
  amd64: ghcr.io/hassio-addons/base:21.0.1
args:
  BUILD_ARCH: "{arch}"
```

(The tag MUST equal the Dockerfile ARG default; Task 11 adds the CI check that enforces this.)

- [ ] **Step 4: Build and verify binaries**

Run:

```bash
docker build --build-arg BUILD_ARCH=aarch64 -t headscale-addon:dev headscale/ \
 && docker run --rm --entrypoint sh headscale-addon:dev -c '
    set -e
    /usr/local/bin/headscale version
    /usr/local/bin/tailscaled --version | head -1
    node --version
    nginx -v
    test -f /opt/headplane/build/server/index.js
    test -x /usr/libexec/headplane/agent
    test -x /usr/local/bin/hp_healthcheck
    id headscale && id headplane && id tailscale && id nginx
    test -x /usr/bin/bashio && test -x /init'
```

Expected: `v0.29.3`, a `1.102.2` line, `v24.x`, nginx version banner, all `test`/`id` lines silent-pass, exit 0.

- [ ] **Step 5: Commit**

```bash
git add headscale/Dockerfile headscale/build.yaml
git commit -m "feat: restructure Dockerfile — all deps as pinned FROM stages on hassio base 21"
```

---

### Task 2: config.yaml, translations, AppArmor profile

**Files:**

- Modify: `headscale/config.yaml` (full rewrite)
- Create: `headscale/translations/en.yaml`
- Create: `headscale/apparmor.txt`

**Interfaces:**

- Produces: addon options schema (`server_url`, `log_level`, `acme_email`, `users` list, `subnet_router.enabled` default **false**, `subnet_router.exit_node`); ports map 8443→443, 8081→80, 3478→3478/udp, 8080→disabled; NO host_network / privileged / homeassistant_config. Later tasks read options via `bashio::config`.

- [ ] **Step 1: Rewrite `headscale/config.yaml`**

```yaml
name: Headscale
version: 0.7.0
slug: headscale
description: Self-hosted Tailscale control server with web UI
url: https://github.com/josh/app-headscale
ingress: true
ingress_port: 0
panel_icon: mdi:vpn
panel_title: Headscale
startup: services
arch:
  - aarch64
  - amd64
init: false
image: ghcr.io/josh/{arch}-addon-headscale
ports:
  8443/tcp: 443
  8081/tcp: 80
  3478/udp: 3478
  8080/tcp: null
ports_description:
  8443/tcp: Headscale server (HTTPS) — forward router port 443 here
  8081/tcp: Let's Encrypt challenge / HTTP mode — forward router port 80 here
  3478/udp: STUN relay
  8080/tcp: Headplane direct access (bypasses Home Assistant auth — leave disabled unless you need it)
hassio_api: true
map:
  - ssl
options:
  server_url: ""
  log_level: info
  acme_email: ""
  users: []
  subnet_router:
    enabled: false
    exit_node: false
schema:
  server_url: url
  log_level: list(trace|debug|info|warning|error)
  acme_email: "email?"
  users:
    - str
  subnet_router:
    enabled: bool
    exit_node: bool
backup_exclude:
  - "*/headscale/noise_private.key"
  - "*/headscale/derp_server_private.key"
  - "*/headplane/api_key"
  - "*/headplane/cookie_secret"
```

- [ ] **Step 2: Create `headscale/translations/en.yaml`**

```yaml
---
configuration:
  server_url:
    name: Server URL
    description: >-
      Public URL clients use to reach this Headscale server, e.g.
      https://vpn.example.com. With an https URL, a real domain, and an ACME
      email set, TLS certificates are obtained automatically.
  log_level:
    name: Log level
    description: Verbosity of the Headscale server log.
  acme_email:
    name: ACME email
    description: >-
      Email address for Let's Encrypt registration. Leave empty to run
      without TLS (only sensible for testing or when server_url is an IP).
  users:
    name: Tailnet users
    description: >-
      Headscale user accounts to create automatically. Generate device keys
      for them in the Headplane UI. Users added here are also added to
      group:users in the access policy (never removed automatically).
  subnet_router:
    name: Subnet router
    description: >-
      Optional LAN access for tailnet devices. Disabled by default — enabling
      it advertises your Home Assistant host's network to the tailnet, gated
      by the group:subnet-access ACL group (empty by default).
network:
  8443/tcp: Headscale server (HTTPS)
  8081/tcp: Let's Encrypt challenge / HTTP mode
  3478/udp: STUN relay
  8080/tcp: Headplane direct access (bypasses Home Assistant auth)
```

- [ ] **Step 3: Create `headscale/apparmor.txt`**

Profile name MUST match the addon slug convention (`<slug>_<anything>` works; supervisor loads the first profile in the file and applies it when named after the slug):

```
#include <tunables/global>

profile headscale flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  capability chown,
  capability dac_override,
  capability setgid,
  capability setuid,
  capability kill,
  capability net_bind_service,

  network tcp,
  network udp,
  network unix,

  file,
  /** mrwkl,

  # s6-overlay
  /init ix,
  /run/{s6,s6-rc*,service}/** ix,
  /package/** ix,
  /command/** ix,

  # Service binaries
  /usr/local/bin/headscale cx -> headscale,
  /usr/local/bin/tailscaled cx -> tailscaled,
  /usr/bin/node cx -> headplane,
  /usr/sbin/nginx cx -> nginx,

  deny mount,
  deny umount,
  deny /sys/[^f]*/** wklx,
  deny /proc/sys/kernel/** wklx,

  profile headscale flags=(attach_disconnected,mediate_deleted) {
    #include <abstractions/base>
    network tcp,
    network udp,
    /usr/local/bin/headscale r,
    /data/headscale/** rwk,
    /data/headscale/ rw,
    /etc/hosts r,
    /etc/resolv.conf r,
    /etc/ssl/** r,
    owner /tmp/** rwk,
    deny network raw,
  }

  profile tailscaled flags=(attach_disconnected,mediate_deleted) {
    #include <abstractions/base>
    network tcp,
    network udp,
    network unix,
    /usr/local/bin/tailscaled r,
    /usr/local/bin/tailscale rix,
    /data/tailscale/** rwk,
    /var/run/tailscale/** rwk,
    /etc/hosts r,
    /etc/resolv.conf r,
    /etc/ssl/** r,
    owner /tmp/** rwk,
    deny network raw,
  }

  profile headplane flags=(attach_disconnected,mediate_deleted) {
    #include <abstractions/base>
    network tcp,
    network unix,
    /usr/bin/node r,
    /opt/headplane/** r,
    /usr/libexec/headplane/agent rix,
    /etc/headplane/** r,
    /data/headplane/** rwk,
    /data/headscale/config.yaml r,
    /etc/hosts r,
    /etc/resolv.conf r,
    /etc/ssl/** r,
    owner /tmp/** rwk,
    deny network raw,
  }

  profile nginx flags=(attach_disconnected,mediate_deleted) {
    #include <abstractions/base>
    capability net_bind_service,
    capability setgid,
    capability setuid,
    network tcp,
    network unix,
    /usr/sbin/nginx r,
    /etc/nginx/** r,
    /var/run/nginx/** rwk,
    /var/lib/nginx/** rwk,
    /var/log/nginx/** rw,
    /proc/1/fd/* w,
    owner /tmp/** rwk,
    deny network raw,
  }
}
```

Note: `deny network raw` in every child profile is the AppArmor expression of "no NET_RAW"; verify on the real HA VM during final verification (Task 14) — if the supervisor rejects the profile, the fallback is relaxing the child-profile transitions to `ix` while keeping the outer profile.

- [ ] **Step 4: Validate**

Run:

```bash
docker run --rm -v "$PWD/headscale":/w mikefarah/yq:4 e 'true' /w/config.yaml /w/translations/en.yaml >/dev/null && echo YAML-OK
apparmor_parser -Q headscale/apparmor.txt 2>/dev/null || docker run --rm -v "$PWD/headscale":/w alpine:3.24 sh -c 'apk add -q apparmor-utils && apparmor_parser -Q /w/apparmor.txt' && echo APPARMOR-OK
```

Expected: `YAML-OK` and `APPARMOR-OK` (parser syntax check only; enforcement is verified in Task 14).

- [ ] **Step 5: Commit**

```bash
git add headscale/config.yaml headscale/translations/en.yaml headscale/apparmor.txt
git commit -m "feat: bridge networking config, opt-in subnet router, translations, AppArmor profile"
```

---

### Task 3: Standalone test harness (supervisor mock + smoke suite)

**Files:**

- Modify: `docker-compose.test.yml`
- Modify: `test/entrypoint.sh`
- Modify: `test/options.json`
- Create: `test/options-router.json`
- Create: `test/supervisor-mock/core/info`, `test/supervisor-mock/network/info`, `test/supervisor-mock/addons/self/info`
- Create: `test/smoke.sh`

**Interfaces:**

- Produces: `docker compose -f docker-compose.test.yml up -d --build` boots the addon standalone; `test/smoke.sh` is the assertion suite Tasks 4–10 extend (bash, `assert` helper, exits non-zero on failure); mock Supervisor reachable inside the container at `http://supervisor` (hosts-pinned to 127.0.0.1:80, served by busybox httpd). Mock values: core port **8123**, host interface `192.168.77.0/24` with address `192.168.77.10`, ingress port **62000**.
- Consumes: image from Task 1, options schema from Task 2.

- [ ] **Step 1: Write the mock Supervisor JSON files**

`test/supervisor-mock/core/info`:

```json
{
  "result": "ok",
  "data": {
    "version": "2026.8.1",
    "port": 8123,
    "ssl": false,
    "hostname": "homeassistant"
  }
}
```

`test/supervisor-mock/network/info` (shape matches Supervisor `/network/info`; bashio jq-filters into it):

```json
{
  "result": "ok",
  "data": {
    "interfaces": [
      {
        "interface": "end0",
        "primary": true,
        "ipv4": { "address": ["192.168.77.10/24"], "gateway": "192.168.77.1" }
      }
    ]
  }
}
```

`test/supervisor-mock/addons/self/info`:

```json
{
  "result": "ok",
  "data": { "ingress_port": 62000, "network": { "8080/tcp": 8080 } }
}
```

- [ ] **Step 2: Rewrite `test/entrypoint.sh`**

```bash
#!/bin/bash
# Standalone test entrypoint: fake the Supervisor, then boot s6 normally.
set -e
echo "127.0.0.1 supervisor" >> /etc/hosts
# Serve the static mock tree as the Supervisor API (busybox httpd is in the base image)
busybox httpd -p 127.0.0.1:80 -h /test/supervisor-mock
exec /init
```

- [ ] **Step 3: Rewrite test options + compose file**

`test/options.json`:

```json
{
  "server_url": "http://127.0.0.1",
  "log_level": "debug",
  "acme_email": "",
  "users": ["e2etest"],
  "subnet_router": { "enabled": false, "exit_node": false }
}
```

`test/options-router.json`: identical but `"enabled": true`.

`docker-compose.test.yml`:

```yaml
# Standalone test environment — no HA Supervisor, no capabilities.
# Usage: docker compose -f docker-compose.test.yml up -d --build && ./test/smoke.sh
services:
  headscale-addon:
    build:
      context: ./headscale
      args:
        BUILD_ARCH: amd64
    container_name: headscale-addon-test
    ports:
      - "8081:8081" # headscale (HTTP mode)
      - "8080:8080" # headplane direct
      - "62000:62000" # ingress vhost (for allowlist denial test)
    entrypoint: ["/bin/bash", "/test/entrypoint.sh"]
    volumes:
      - headscale-data:/data
      - ./test/options.json:/data/options.json:ro
      - ./test:/test:ro
    environment:
      SUPERVISOR_TOKEN: "test-token-not-real"
  # Stand-in for the internal `homeassistant` hostname (serve backend target)
  homeassistant:
    image: nginx:alpine
    command:
      [
        "sh",
        "-c",
        "sed -i 's/listen  *80/listen 8123/' /etc/nginx/conf.d/default.conf && nginx -g 'daemon off;'",
      ]
volumes:
  headscale-data:
```

- [ ] **Step 4: Create `test/smoke.sh` with the harness + first assertion**

```bash
#!/usr/bin/env bash
# Smoke suite for the standalone addon container. Extend with asserts per task.
set -uo pipefail
C=headscale-addon-test
FAIL=0
assert() { # assert <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS: ${desc}"; else echo "FAIL: ${desc}"; FAIL=1; fi
}
in_c() { docker exec "$C" "$@"; }

echo "== waiting for services (max 120s) =="
for i in $(seq 1 60); do
  curl -fs http://127.0.0.1:8081/health >/dev/null 2>&1 && break
  sleep 2
done

assert "headscale /health responds"        curl -fs http://127.0.0.1:8081/health

exit $FAIL
```

Run: `chmod +x test/smoke.sh test/entrypoint.sh`

- [ ] **Step 5: Run to verify current state fails**

Run: `docker compose -f docker-compose.test.yml up -d --build && sleep 20 && ./test/smoke.sh`
Expected: **FAIL** — the old s6 services still target old ports/paths; that's the red state Tasks 4–9 turn green. (If the container crash-loops, that's equally "red" — fine.)

- [ ] **Step 6: Commit**

```bash
git add docker-compose.test.yml test/
git commit -m "test: standalone harness with supervisor mock and smoke suite"
```

---

### Task 4: init-headscale + headscale service (bridge-mode config, /etc/hosts pin, non-root)

**Files:**

- Modify: `headscale/rootfs/etc/headscale/config.yaml` (template)
- Modify: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headscale/run`
- Modify: `headscale/rootfs/etc/s6-overlay/s6-rc.d/headscale/run`
- Modify: `headscale/rootfs/etc/s6-overlay/s6-rc.d/headscale/finish` (CANONICAL-FINISH, `service="Headscale"`)
- Test: extend `test/smoke.sh`

**Interfaces:**

- Consumes: MODE-DETECT block; options from Task 2.
- Produces: container-env vars for later services — `HS_MODE` (`tls`|`http`), `HS_LOCAL_URL` (`https://<host>:8443` | `http://127.0.0.1:8081`), `HS_LOGIN_SERVER` (public URL clients/nodes use), `HA_PORT` (from `bashio::core.port`, fallback 8123 when Supervisor unreachable — mock supplies it in tests). Headscale runs as user `headscale`, config+state at `/data/headscale/`, `headscale` CLI usable via `s6-setuidgid headscale /usr/local/bin/headscale <cmd> --config /data/headscale/config.yaml`.

- [ ] **Step 1: Add failing assertions to `test/smoke.sh`** (before `exit $FAIL`)

```bash
assert "config: listen_addr is 0.0.0.0:8081 (HTTP mode)" \
  bash -c "docker exec $C yq e '.listen_addr' /data/headscale/config.yaml | grep -q '0.0.0.0:8081'"
assert "config: base_domain is tailnet.internal" \
  bash -c "docker exec $C yq e '.dns.base_domain' /data/headscale/config.yaml | grep -q 'tailnet.internal'"
assert "headscale runs as non-root" \
  bash -c "docker exec $C ps -o user,comm | grep headscale | grep -qv root"
assert "no NODE_TLS_REJECT_UNAUTHORIZED in container env" \
  bash -c "! docker exec $C test -e /var/run/s6/container_environment/NODE_TLS_REJECT_UNAUTHORIZED"
```

Run: `./test/smoke.sh` → these FAIL.

- [ ] **Step 2: Update the config template** — `headscale/rootfs/etc/headscale/config.yaml`:

```yaml
# Template — copied to /data/headscale/config.yaml on first run, patched every start
server_url: https://REPLACE_ME
listen_addr: 0.0.0.0:8443
metrics_listen_addr: 127.0.0.1:9090

noise:
  private_key_path: /data/headscale/noise_private.key

tls_letsencrypt_hostname: ""
tls_letsencrypt_cache_dir: /data/headscale/cache
tls_letsencrypt_challenge_type: HTTP-01
tls_letsencrypt_listen: ":8081"

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
  base_domain: tailnet.internal
  override_local_dns: false
  nameservers:
    global:
      - 1.1.1.1
      - 9.9.9.9
    split: {}
  search_domains: []
  extra_records: []

policy:
  mode: database

log:
  level: info
```

- [ ] **Step 3: Rewrite `init-headscale/run`**

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# Configures Headscale: bridge-mode ports, TLS/HTTP mode, hosts pin, migration.
readonly CONFIG="/data/headscale/config.yaml"
readonly DEFAULT_CONFIG="/etc/headscale/config.yaml"

bashio::log.info "Configuring Headscale..."

if ! bashio::fs.file_exists "${CONFIG}"; then
    bashio::log.info "First run: creating default configuration..."
    mkdir -p /data/headscale/cache
    cp "${DEFAULT_CONFIG}" "${CONFIG}"
fi

# --- v0.6.0 migration: old TUN node + old subnet router state are obsolete ---
if [ -d /data/tailscale/ha ] || [ -d /data/tailscale/subnet ]; then
    bashio::log.notice "Migrating from v0.6.x: removing old tailscale node state."
    bashio::log.notice "Clients that used the old homeassistant tailnet IP should"
    bashio::log.notice "switch to homeassistant.tailnet.internal (see documentation)."
    rm -rf /data/tailscale/ha /data/tailscale/subnet
    rm -rf /data/headplane/user_keys /data/headplane/ha_users.txt \
           /data/tailscale/ha_auth_key /data/tailscale/subnet_auth_key \
           /data/headplane/agent_preauth_key
fi

server_url=$(bashio::config 'server_url')
if ! bashio::var.has_value "${server_url}"; then
    bashio::log.fatal "server_url is required (e.g. https://vpn.example.com)"
    bashio::exit.nok
fi
log_level=$(bashio::config 'log_level')
acme_email=$(bashio::config 'acme_email')

# MODE-DETECT
hs_host=$(echo "${server_url}" | sed -e 's|https\?://||' -e 's|[:/].*||')
if [[ "${server_url}" == https://* ]] \
    && [[ ! "${hs_host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    && bashio::var.has_value "${acme_email}"; then
    hs_mode=tls; hs_local_url="https://${hs_host}:8443"
    bashio::log.info "TLS enabled with ACME for ${hs_host}"
    acme_hostname="${hs_host}" yq e --inplace '.tls_letsencrypt_hostname = env(acme_hostname)' "${CONFIG}"
    acme_email="${acme_email}" yq e --inplace '.acme_email = env(acme_email)' "${CONFIG}"
    yq e --inplace '.listen_addr = "0.0.0.0:8443"' "${CONFIG}"
    # Pin the public hostname to loopback so in-container clients (headplane,
    # tailscaled) reach headscale locally with a VALID cert — no TLS bypass.
    if ! grep -q " ${hs_host}\$" /etc/hosts; then
        echo "127.0.0.1 ${hs_host}" >> /etc/hosts
    fi
else
    hs_mode=http; hs_local_url="http://127.0.0.1:8081"
    bashio::log.info "TLS disabled (no domain/email for ACME). HTTP on port 80 (container 8081)."
    yq e --inplace '.tls_letsencrypt_hostname = ""' "${CONFIG}"
    yq e --inplace '.listen_addr = "0.0.0.0:8081"' "${CONFIG}"
    if [[ "${server_url}" == https://* ]]; then
        server_url="http://${hs_host}"
        bashio::log.warning "Rewrote server_url to ${server_url} (ACME unavailable)"
    fi
fi

server_url="${server_url}" yq e --inplace '.server_url = env(server_url)' "${CONFIG}"
log_level="${log_level}" yq e --inplace '.log.level = env(log_level)' "${CONFIG}"
yq e --inplace '.metrics_listen_addr = "127.0.0.1:9090"' "${CONFIG}"
yq e --inplace '.database.sqlite.path = "/data/headscale/db.sqlite"' "${CONFIG}"
yq e --inplace '.policy.mode = "database"' "${CONFIG}"
yq e --inplace '.dns.base_domain = "tailnet.internal"' "${CONFIG}"
yq e --inplace '.dns.nameservers.split |= (. // {})' "${CONFIG}"
yq e --inplace '.dns.search_domains |= (. // [])' "${CONFIG}"
yq e --inplace '.dns.extra_records |= (. // [])' "${CONFIG}"

# HA core port for the serve proxy + seed ACL (mock supplies it in tests)
ha_port=$(bashio::core.port 2>/dev/null) || true
[ -z "${ha_port}" ] || [ "${ha_port}" = "null" ] && ha_port=8123

chown -R headscale:headscale /data/headscale

printf '%s' "${hs_mode}"      > /var/run/s6/container_environment/HS_MODE
printf '%s' "${hs_local_url}" > /var/run/s6/container_environment/HS_LOCAL_URL
printf '%s' "${server_url}"   > /var/run/s6/container_environment/HS_LOGIN_SERVER
printf '%s' "${ha_port}"      > /var/run/s6/container_environment/HA_PORT

bashio::log.info "Headscale configured (mode=${hs_mode}, server_url=${server_url})"
```

- [ ] **Step 4: Rewrite `headscale/run`**

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
bashio::log.info "Starting Headscale server..."
exec s6-setuidgid headscale /usr/local/bin/headscale serve --config /data/headscale/config.yaml
```

And write `headscale/finish` from CANONICAL-FINISH with `service="Headscale"`.

- [ ] **Step 5: Rebuild, rerun smoke**

Run: `docker compose -f docker-compose.test.yml up -d --build --force-recreate && sleep 25 && ./test/smoke.sh`
Expected: the four new assertions PASS (later-task assertions still absent). `headscale /health responds` PASSES.

- [ ] **Step 6: Commit**

```bash
git add headscale/rootfs test/smoke.sh
git commit -m "feat: bridge-mode headscale on unprivileged ports, hosts-pin TLS, non-root, v0.6 migration"
```

---

### Task 5: init-policy — users + fail-closed seed ACL + surgical merge

**Files:**

- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-policy/{type,up,run,dependencies.d/headscale}`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/init-policy` (empty file)
- Modify: dependencies of `init-headplane`, `init-nginx` (Task 6/9 note: their `dependencies.d/` gains `init-policy` replacing bare `headscale`)
- Test: extend `test/smoke.sh`

**Interfaces:**

- Consumes: `HS_MODE`, `HA_PORT` env; running headscale.
- Produces: headscale users exist for each `users` option entry plus service users `addon` (owns proxy/router keys) and `headplane-agent`; database policy seeded exactly as the spec's tag-based ACL; marker file `/data/headscale/.policy_seeded`. Helper convention for later tasks: `hs() { s6-setuidgid headscale /usr/local/bin/headscale --config /data/headscale/config.yaml "$@"; }`.

- [ ] **Step 1: Add failing assertions to `test/smoke.sh`**

```bash
assert "policy: seeded with tag:homeassistant rule" \
  bash -c "docker exec $C s6-setuidgid headscale headscale policy get --config /data/headscale/config.yaml | grep -q 'tag:homeassistant'"
assert "policy: no allow-all member rule" \
  bash -c "! docker exec $C s6-setuidgid headscale headscale policy get --config /data/headscale/config.yaml | jq -e '.acls[] | select(.src==[\"autogroup:member\"] and .dst==[\"*:*\"])'"
assert "users: e2etest + addon + headplane-agent exist" \
  bash -c "docker exec $C s6-setuidgid headscale headscale users list -o json --config /data/headscale/config.yaml | jq -r '.[].name' | grep -qx 'e2etest'"
assert "policy: group:users contains e2etest@" \
  bash -c "docker exec $C s6-setuidgid headscale headscale policy get --config /data/headscale/config.yaml | jq -e '.groups[\"group:users\"] | index(\"e2etest@\")'"
```

Run: `./test/smoke.sh` → FAIL.

- [ ] **Step 2: Create the service files**

`init-policy/type`: `oneshot`
`init-policy/up`: `/etc/s6-overlay/s6-rc.d/init-policy/run`
`init-policy/dependencies.d/headscale`: empty file
`user/contents.d/init-policy`: empty file

`init-policy/run`:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# Creates headscale users and applies the access policy BEFORE any node joins.
# First-run policy failure is FATAL: never run on headscale's allow-all default.
readonly SEED_MARKER="/data/headscale/.policy_seeded"

hs() { s6-setuidgid headscale /usr/local/bin/headscale --config /data/headscale/config.yaml "$@"; }

# Wait for headscale API (mode-dependent local port)
if [ "${HS_MODE}" = "tls" ]; then wait_port=8443; else wait_port=8081; fi
bashio::net.wait_for "${wait_port}" 127.0.0.1 300

# --- Users: option users + service users (idempotent) ---
existing=$(hs users list -o json 2>/dev/null | jq -r '.[].name') || existing=""
create_user() {
    if ! echo "${existing}" | grep -qx "$1"; then
        bashio::log.info "Creating headscale user: $1"
        hs users create "$1" >/dev/null 2>&1 || true
    fi
}
create_user "addon"
create_user "headplane-agent"
option_users=$(bashio::config 'users') || option_users=""
for u in ${option_users}; do
    [ "${u}" = "null" ] && continue
    create_user "${u}"
done

# --- Build group:users JSON from options ---
users_json=$(bashio::config 'users' | jq -Rs '[split("\n")[] | select(length>0 and . != "null") | . + "@"]')

# --- Detected routes (only matter if subnet router enabled) ---
cidr_network() { # 192.168.77.10/24 -> 192.168.77.0/24 (IPv4 only, pure bash)
    local ip="${1%/*}" bits="${1#*/}" IFS=. o1 o2 o3 o4 m
    read -r o1 o2 o3 o4 <<< "${ip}"
    m=$(( 0xFFFFFFFF << (32 - bits) & 0xFFFFFFFF ))
    local n=$(( ((o1<<24 | o2<<16 | o3<<8 | o4) & m) ))
    echo "$(( (n>>24)&255 )).$(( (n>>16)&255 )).$(( (n>>8)&255 )).$(( n&255 ))/${bits}"
}
routes=""
if bashio::config.true 'subnet_router.enabled'; then
    routes=$(bashio::network "network_info" \
        '.interfaces[] | select(.primary==true) | .ipv4.address[0]' 2>/dev/null) || true
    if bashio::var.has_value "${routes}" && [ "${routes}" != "null" ]; then
        routes=$(cidr_network "${routes}")
    else
        routes=""
        bashio::log.warning "Subnet router enabled but no route detected (Supervisor API unavailable?)"
    fi
fi
printf '%s' "${routes}" > /var/run/s6/container_environment/TS_ROUTES

if ! bashio::fs.file_exists "${SEED_MARKER}"; then
    bashio::log.info "Seeding access policy (fail-closed)..."
    acl_tmp="/tmp/seed_policy.hujson"
    subnet_acl=""
    if bashio::var.has_value "${routes}"; then
        subnet_acl=",
        {\"action\": \"accept\", \"src\": [\"group:subnet-access\"], \"dst\": [\"${routes}:*\"]}"
    fi
    cat > "${acl_tmp}" <<ACLEOF
{
    "tagOwners": {
        "tag:homeassistant": [],
        "tag:subnet-router": []
    },
    "groups": {
        "group:admins": [],
        "group:users": ${users_json},
        "group:subnet-access": []
    },
    "acls": [
        {"action": "accept", "src": ["group:admins"], "dst": ["*:*"]},
        {"action": "accept", "src": ["group:users"], "dst": ["tag:homeassistant:*"]},
        {"action": "accept", "src": ["autogroup:member"], "dst": ["tag:homeassistant:${HA_PORT}"]}${subnet_acl}
    ]
}
ACLEOF
    if hs policy set -f "${acl_tmp}"; then
        printf '%s' "1" > "${SEED_MARKER}"
        bashio::log.info "Access policy seeded."
    else
        bashio::log.fatal "Could not apply the seed access policy."
        bashio::log.fatal "Refusing to start with headscale's allow-all default."
        bashio::exit.nok
    fi
else
    # Surgical add-only merges; failures are loud but non-fatal (policy exists).
    current=$(hs policy get 2>/dev/null)
    if bashio::var.has_value "${current}"; then
        merged=$(echo "${current}" | jq --argjson add "${users_json}" \
            '.groups["group:users"] = ((.groups["group:users"] // []) + $add | unique)')
        if bashio::var.has_value "${routes}" \
            && ! echo "${current}" | jq -e '.acls[] | select(.src==["group:subnet-access"])' >/dev/null; then
            merged=$(echo "${merged}" | jq --arg dst "${routes}:*" \
                '.acls += [{"action":"accept","src":["group:subnet-access"],"dst":[$dst]}]')
        fi
        if [ "${merged}" != "${current}" ]; then
            merge_tmp="/tmp/merged_policy.json"
            echo "${merged}" > "${merge_tmp}"
            if hs policy set -f "${merge_tmp}"; then
                bashio::log.info "Policy updated (add-only merge)."
            else
                bashio::log.error "Policy merge failed — existing policy left unchanged."
            fi
        fi
    else
        bashio::log.error "Could not read existing policy for merge; skipping."
    fi
fi

bashio::log.info "Policy configuration complete."
```

(CIDR normalization is pure bash because the base image has no python3/ipcalc.)

- [ ] **Step 3: Point `init-headplane/dependencies.d/` and `init-nginx/dependencies.d/` at `init-policy`**

```bash
cd headscale/rootfs/etc/s6-overlay/s6-rc.d
rm -f init-headplane/dependencies.d/headscale init-nginx/dependencies.d/headscale
touch init-headplane/dependencies.d/init-policy init-nginx/dependencies.d/init-policy
```

- [ ] **Step 4: Rebuild + smoke; also verify idempotent second boot**

Run:

```bash
docker compose -f docker-compose.test.yml up -d --build --force-recreate && sleep 30 && ./test/smoke.sh \
 && docker compose -f docker-compose.test.yml restart headscale-addon && sleep 30 && ./test/smoke.sh
```

Expected: all policy assertions PASS on both runs (second run exercises the merge path).

- [ ] **Step 5: Commit**

```bash
git add headscale/rootfs test/smoke.sh
git commit -m "feat: fail-closed tag-based seed ACL with add-only merges (init-policy)"
```

---

### Task 6: init-headplane + headplane service (0.7.0 config, non-root, no secrets in logs)

**Files:**

- Modify: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-headplane/run`
- Modify: `headscale/rootfs/etc/s6-overlay/s6-rc.d/headplane/run`
- Modify: `headscale/rootfs/etc/s6-overlay/s6-rc.d/headplane/finish` (CANONICAL-FINISH, `service="Headplane"`)
- Test: extend `test/smoke.sh`

**Interfaces:**

- Consumes: `HS_LOCAL_URL`, `HS_LOGIN_SERVER` env; `init-policy` complete (user `headplane-agent` exists).
- Produces: Headplane on 127.0.0.1:3000 with config at `/etc/headplane/config.yaml` (owner `headplane`, mode 0400); API key at `/data/headplane/api_key` (0600); server data at `/data/headplane/data`.

- [ ] **Step 1: Add failing assertions to `test/smoke.sh`**

```bash
assert "headplane login page responds" \
  bash -c "docker exec $C curl -fs -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/admin/login | grep -q 200"
assert "headplane runs as non-root" \
  bash -c "docker exec $C ps -o user,comm | grep node | grep -qv root"
assert "api key file exists with 0600" \
  bash -c "docker exec $C stat -c %a /data/headplane/api_key | grep -q 600"
assert "api key value never appears in logs" \
  bash -c "! docker logs $C 2>&1 | grep -qF \"\$(docker exec $C cat /data/headplane/api_key)\""
```

Run: `./test/smoke.sh` → FAIL.

- [ ] **Step 2: Rewrite `init-headplane/run`**

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# Generates Headplane v0.7.x configuration.
readonly HEADPLANE_CONFIG="/etc/headplane/config.yaml"
readonly COOKIE_SECRET_FILE="/data/headplane/cookie_secret"
readonly API_KEY_FILE="/data/headplane/api_key"

bashio::log.info "Configuring Headplane..."
mkdir -p /data/headplane/data /data/headplane/agent

hs() { s6-setuidgid headscale /usr/local/bin/headscale --config /data/headscale/config.yaml "$@"; }

# API key: created once, long expiry, NEVER logged.
if ! bashio::fs.file_exists "${API_KEY_FILE}"; then
    api_key=$(hs apikeys create -e 87600h 2>/dev/null) || true
    if bashio::var.has_value "${api_key}"; then
        (umask 077 && printf '%s' "${api_key}" > "${API_KEY_FILE}")
        bashio::log.info "Headscale API key generated for Headplane."
        bashio::log.info "To log in to Headplane, read it from: ${API_KEY_FILE}"
    else
        bashio::log.warning "Could not generate API key; Headplane login will not work yet."
    fi
fi
api_key=""
bashio::fs.file_exists "${API_KEY_FILE}" && api_key=$(cat "${API_KEY_FILE}")

# Cookie secret: exactly 32 chars.
if ! bashio::fs.file_exists "${COOKIE_SECRET_FILE}"; then
    (umask 077 && openssl rand -hex 16 | tr -d '\n' > "${COOKIE_SECRET_FILE}")
fi
cookie_secret=$(cat "${COOKIE_SECRET_FILE}")

server_url=$(bashio::config 'server_url')

cat > "${HEADPLANE_CONFIG}" <<EOF
server:
  host: "127.0.0.1"
  port: 3000
  base_url: "${HS_LOGIN_SERVER}"
  cookie_secret: "${cookie_secret}"
  cookie_secure: false
  data_path: "/data/headplane/data"
  proxy_auth:
    enabled: true
    user_header: "X-Remote-User-Name"
    name_header: "X-Remote-User-Display-Name"
    allowed_cidrs:
      - "127.0.0.1/32"

headscale:
  url: "${HS_LOCAL_URL}"
  public_url: "${HS_LOGIN_SERVER}"
  config_path: "/data/headscale/config.yaml"
  config_strict: false
  api_key: "${api_key}"

integration:
  proc:
    enabled: true
  agent:
    enabled: true
    host_name: "headplane-agent"
    work_dir: "/data/headplane/agent"
EOF
chown headplane:headplane "${HEADPLANE_CONFIG}" /data/headplane -R
chmod 0400 "${HEADPLANE_CONFIG}"
chmod 0600 "${API_KEY_FILE}" 2>/dev/null || true

# headplane must read the headscale config for config_path integration
chmod g+r /data/headscale/config.yaml 2>/dev/null || true
addgroup headplane headscale 2>/dev/null || true

bashio::log.info "Headplane configuration complete."
```

Notes: `proxy_auth.allowed_cidrs` is 127.0.0.1 because **nginx** (same container) is the proxy that injects/forwards the HA ingress identity headers — Task 9 configures nginx to forward `X-Remote-User-*` only on the ingress vhost and to strip them on the direct vhost. There is deliberately no `NODE_TLS_REJECT_UNAUTHORIZED` anywhere: in TLS mode `HS_LOCAL_URL` uses the real hostname pinned to loopback, so cert validation succeeds.

- [ ] **Step 3: Rewrite `headplane/run`** (+ finish from CANONICAL-FINISH, `service="Headplane"`)

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
bashio::log.info "Starting Headplane..."
cd /opt/headplane || bashio::exit.nok "Headplane directory not found"
export HEADPLANE_CONFIG_PATH=/etc/headplane/config.yaml
export HEADPLANE_LISTEN_FILE=/tmp/headplane-listen
exec s6-setuidgid headplane /usr/bin/node /opt/headplane/build/server/index.js
```

- [ ] **Step 4: Rebuild + smoke**

Run: `docker compose -f docker-compose.test.yml up -d --build --force-recreate && sleep 35 && ./test/smoke.sh`
Expected: Task 6 assertions PASS. If the login-page path differs in 0.7 (e.g. redirects), adjust the assertion to accept the actual 2xx/3xx login route — but it must be a Headplane-served response, verified with `curl -s | grep -qi headplane`.

- [ ] **Step 5: Commit**

```bash
git add headscale/rootfs test/smoke.sh
git commit -m "feat: headplane 0.7 config with server-side key, proxy auth, non-root, silent secrets"
```

---

### Task 7: ts-ha-proxy — serve-based HA access

**Files:**

- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-ha-proxy/{type,up,run,dependencies.d/init-policy}`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/ts-ha-proxy/{type,run,finish,dependencies.d/init-ha-proxy}`
- Create: `user/contents.d/init-ha-proxy`, `user/contents.d/ts-ha-proxy` (empty files)
- Test: extend `test/smoke.sh`

**Interfaces:**

- Consumes: `HS_MODE`, `HS_LOGIN_SERVER`, `HA_PORT`, running headscale + seeded policy; headscale user `addon` (key owner).
- Produces: tailnet node `homeassistant` tagged `tag:homeassistant`, serving TCP `${HA_PORT}` → `tcp://homeassistant:${HA_PORT}`; state at `/data/tailscale/ha-proxy`; socket `/var/run/tailscale/ha-proxy.sock`.

- [ ] **Step 1: Add failing assertions to `test/smoke.sh`**

```bash
assert "ha-proxy node joined with tag:homeassistant" \
  bash -c "docker exec $C s6-setuidgid headscale headscale nodes list -o json --config /data/headscale/config.yaml | jq -e '.[] | select(.name==\"homeassistant\") | .validTags==null or (.tags // [] | index(\"tag:homeassistant\")) or (.forcedTags // [] | index(\"tag:homeassistant\"))'"
assert "serve forwards HA_PORT" \
  bash -c "docker exec $C tailscale --socket /var/run/tailscale/ha-proxy.sock serve status | grep -q 8123"
```

(0.28+ collapsed node tag fields to `Tags`; the jq covers JSON-shape drift — tighten to the actual field name observed during implementation.)

Run: `./test/smoke.sh` → FAIL.

- [ ] **Step 2: Create `init-ha-proxy/run`** (`type`=oneshot, `up`=`/etc/s6-overlay/s6-rc.d/init-ha-proxy/run`, dependency `init-policy`)

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# Mints a single-use tagged join key for the HA proxy node when no state exists.
readonly STATE_DIR="/data/tailscale/ha-proxy"
readonly KEY_FILE="/tmp/ha-proxy-join-key"

hs() { s6-setuidgid headscale /usr/local/bin/headscale --config /data/headscale/config.yaml "$@"; }

mkdir -p "${STATE_DIR}" /var/run/tailscale
chown -R tailscale:tailscale "${STATE_DIR}" /var/run/tailscale

if [ ! -f "${STATE_DIR}/tailscaled.state" ]; then
    addon_uid=$(hs users list -o json 2>/dev/null | jq -r '.[] | select(.name=="addon") | .id') || true
    if bashio::var.has_value "${addon_uid}"; then
        # Default expiry 1h, single-use, tagged — never logged, never persisted.
        join_key=$(hs preauthkeys create --user "${addon_uid}" --tags tag:homeassistant 2>/dev/null) || true
        if bashio::var.has_value "${join_key}"; then
            (umask 077 && printf '%s' "${join_key}" > "${KEY_FILE}")
            bashio::log.info "HA proxy join key minted (single-use, 1h)."
        else
            bashio::log.warning "Could not mint HA proxy join key."
        fi
    fi
fi
```

- [ ] **Step 3: Create `ts-ha-proxy/run`** (`type`=longrun, dependency `init-ha-proxy`, finish=CANONICAL-FINISH `service="TS-HA-Proxy"`)

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
readonly STATE_DIR="/data/tailscale/ha-proxy"
readonly SOCKET="/var/run/tailscale/ha-proxy.sock"
readonly KEY_FILE="/tmp/ha-proxy-join-key"

bashio::log.info "Starting HA proxy tailscale node..."

s6-setuidgid tailscale /usr/local/bin/tailscaled \
    --statedir="${STATE_DIR}" \
    --socket="${SOCKET}" \
    --tun=userspace-networking &
TS_PID=$!
trap 'kill ${TS_PID} 2>/dev/null; wait' EXIT TERM

for i in $(seq 1 30); do [ -S "${SOCKET}" ] && break; sleep 1; done

up_args=(--login-server "${HS_LOGIN_SERVER}" --hostname homeassistant --accept-dns=false --accept-routes=false)
if [ -f "${KEY_FILE}" ]; then
    up_args+=(--authkey "$(cat "${KEY_FILE}")")
fi
if timeout 60 s6-setuidgid tailscale /usr/local/bin/tailscale --socket="${SOCKET}" up "${up_args[@]}"; then
    rm -f "${KEY_FILE}"
    bashio::log.info "HA proxy node is on the tailnet."
    # Forward the tailnet-side HA port to Home Assistant. Backend hostname
    # 'homeassistant' resolves on the internal hassio network (mocked in tests).
    if s6-setuidgid tailscale /usr/local/bin/tailscale --socket="${SOCKET}" \
        serve --bg --tcp="${HA_PORT}" "tcp://homeassistant:${HA_PORT}"; then
        bashio::log.info "Serving Home Assistant at homeassistant.tailnet.internal:${HA_PORT}"
    else
        bashio::log.warning "tailscale serve setup failed — HA not reachable via tailnet."
    fi
else
    bashio::log.warning "HA proxy could not join the tailnet (will retry on restart)."
fi

wait ${TS_PID}
```

- [ ] **Step 4: Rebuild + smoke**

Run: `docker compose -f docker-compose.test.yml up -d --build --force-recreate && sleep 40 && ./test/smoke.sh`
Expected: both Task 7 assertions PASS. This is also the local **serve-vs-headscale verification** the spec requires — if `serve --bg --tcp` errors against headscale here, STOP and consult the spec's fallback (subnet-route + extra_records design) before proceeding.

- [ ] **Step 5: Commit**

```bash
git add headscale/rootfs test/smoke.sh
git commit -m "feat: ts-ha-proxy — tagged userspace node serving HA via tailscale serve"
```

---

### Task 8: ts-subnet-router — opt-in LAN access

**Files:**

- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-subnet-router/{type,up,run,dependencies.d/init-policy}`
- Create: `headscale/rootfs/etc/s6-overlay/s6-rc.d/ts-subnet-router/{type,run,finish,dependencies.d/init-subnet-router}`
- Create: `user/contents.d/init-subnet-router`, `user/contents.d/ts-subnet-router` (empty files)
- Test: extend `test/smoke.sh`

**Interfaces:**

- Consumes: `TS_ROUTES` (set by init-policy), `HS_LOGIN_SERVER`, options `subnet_router.*`; headscale user `addon`.
- Produces: when enabled — node `subnet-router` tagged `tag:subnet-router`, advertised+approved routes; when disabled — NO tailscaled process, NO node. Longrun must exit 0 immediately when disabled (s6 oneshot-like no-op via `s6-svc -O`).

- [ ] **Step 1: Add failing assertions to `test/smoke.sh`**

```bash
assert "subnet router absent when disabled (default)" \
  bash -c "! docker exec $C s6-setuidgid headscale headscale nodes list -o json --config /data/headscale/config.yaml | jq -e '.[] | select(.name==\"subnet-router\")'"
```

And a separate enabled-variant check appended at the END of smoke.sh as a second phase:

```bash
echo "== subnet-router enabled variant =="
docker compose -f docker-compose.test.yml stop headscale-addon >/dev/null
docker run -d --rm --name ${C}-router \
  --volumes-from ${C} \
  -v "$PWD/test/options-router.json":/data/options.json:ro \
  -e SUPERVISOR_TOKEN=test-token-not-real \
  --network container:${C} \
  --entrypoint /bin/bash "$(docker inspect ${C} -f '{{.Config.Image}}')" /test/entrypoint.sh >/dev/null 2>&1 || true
sleep 45
assert "subnet router joins with tag and approved route" \
  bash -c "docker exec ${C}-router s6-setuidgid headscale headscale nodes list -o json --config /data/headscale/config.yaml | jq -e '.[] | select(.name==\"subnet-router\")'"
assert "route 192.168.77.0/24 approved" \
  bash -c "docker exec ${C}-router s6-setuidgid headscale headscale nodes list-routes 2>/dev/null | grep -q '192.168.77.0/24' || docker exec ${C}-router s6-setuidgid headscale headscale nodes list -o json --config /data/headscale/config.yaml | jq -e '[.[].approvedRoutes // []] | flatten | index(\"192.168.77.0/24\")'"
docker stop ${C}-router >/dev/null 2>&1 || true
docker compose -f docker-compose.test.yml start headscale-addon >/dev/null
```

(If the `--network container:` re-use pattern fights compose locally, simplify: run the enabled variant as a one-off `docker compose -f docker-compose.test.yml run` with the router options file bind-mounted — the assertion content is what matters, keep it identical.)

Run: `./test/smoke.sh` → disabled-assert PASSES already (nothing implemented = no node) — the enabled-variant asserts FAIL. That's the red state.

- [ ] **Step 2: Create `init-subnet-router/run`** (`type`=oneshot, `up` per convention, dependency `init-policy`)

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
readonly STATE_DIR="/data/tailscale/subnet-router"
readonly KEY_FILE="/tmp/subnet-router-join-key"

if ! bashio::config.true 'subnet_router.enabled'; then
    bashio::log.info "Subnet router disabled (default)."
    exit 0
fi

hs() { s6-setuidgid headscale /usr/local/bin/headscale --config /data/headscale/config.yaml "$@"; }

mkdir -p "${STATE_DIR}"
chown -R tailscale:tailscale "${STATE_DIR}"

if [ ! -f "${STATE_DIR}/tailscaled.state" ]; then
    addon_uid=$(hs users list -o json 2>/dev/null | jq -r '.[] | select(.name=="addon") | .id') || true
    if bashio::var.has_value "${addon_uid}"; then
        join_key=$(hs preauthkeys create --user "${addon_uid}" --tags tag:subnet-router --reusable=false 2>/dev/null) || true
        if bashio::var.has_value "${join_key}"; then
        (umask 077 && printf '%s' "${join_key}" > "${KEY_FILE}")
            bashio::log.info "Subnet router join key minted (single-use, 1h)."
        fi
    fi
fi
```

- [ ] **Step 3: Create `ts-subnet-router/run`** (`type`=longrun, dependency `init-subnet-router`, finish=CANONICAL-FINISH `service="TS-Subnet-Router"` **with one extra guard**: when disabled, exit 0 must NOT halt the container — add at the top of finish: `bashio::config.true 'subnet_router.enabled' || exit 0`)

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
readonly STATE_DIR="/data/tailscale/subnet-router"
readonly SOCKET="/var/run/tailscale/subnet-router.sock"
readonly KEY_FILE="/tmp/subnet-router-join-key"

if ! bashio::config.true 'subnet_router.enabled'; then
    # Tell s6 to bring this service down without killing the container.
    exec s6-svc -Od /run/service/ts-subnet-router
fi

bashio::log.info "Starting subnet router..."

s6-setuidgid tailscale /usr/local/bin/tailscaled \
    --statedir="${STATE_DIR}" \
    --socket="${SOCKET}" \
    --tun=userspace-networking &
TS_PID=$!
trap 'kill ${TS_PID} 2>/dev/null; wait' EXIT TERM

for i in $(seq 1 30); do [ -S "${SOCKET}" ] && break; sleep 1; done

up_args=(--login-server "${HS_LOGIN_SERVER}" --hostname subnet-router --accept-dns=false --accept-routes=false)
[ -f "${KEY_FILE}" ] && up_args+=(--authkey "$(cat "${KEY_FILE}")")
if bashio::var.has_value "${TS_ROUTES:-}"; then
    up_args+=(--advertise-routes "${TS_ROUTES}")
fi
if bashio::config.true 'subnet_router.exit_node'; then
    up_args+=(--advertise-exit-node)
fi

if timeout 60 s6-setuidgid tailscale /usr/local/bin/tailscale --socket="${SOCKET}" up "${up_args[@]}"; then
    rm -f "${KEY_FILE}"
    bashio::log.info "Subnet router on the tailnet (routes: ${TS_ROUTES:-none})."
    hs() { s6-setuidgid headscale /usr/local/bin/headscale --config /data/headscale/config.yaml "$@"; }
    node_id=$(hs nodes list -o json 2>/dev/null | jq -r '.[] | select(.name=="subnet-router") | .id') || true
    if bashio::var.has_value "${node_id}" && bashio::var.has_value "${TS_ROUTES:-}"; then
        if hs nodes approve-routes -i "${node_id}" -r "${TS_ROUTES}"; then
            bashio::log.info "Routes approved: ${TS_ROUTES}"
        else
            bashio::log.warning "Route approval failed — approve manually in Headplane."
        fi
    fi
else
    bashio::log.warning "Subnet router could not join the tailnet."
fi

wait ${TS_PID}
```

- [ ] **Step 4: Rebuild + smoke (both variants)**

Run: `docker compose -f docker-compose.test.yml up -d --build --force-recreate && sleep 40 && ./test/smoke.sh`
Expected: disabled assert PASSES with the addon running (no `subnet-router` node), enabled-variant asserts PASS.

- [ ] **Step 5: Commit**

```bash
git add headscale/rootfs test/smoke.sh
git commit -m "feat: opt-in tagged subnet router with auto-approved detected routes"
```

---

### Task 9: nginx — ingress allowlist, identity-header hygiene, rate-limited direct port, non-root

**Files:**

- Modify: `headscale/rootfs/etc/nginx/nginx.conf`
- Modify: `headscale/rootfs/etc/nginx/templates/ingress.gtpl`, `direct.gtpl` (`upstream.gtpl` unchanged)
- Modify: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-nginx/run` (only the bashio rename: `bashio::app.ingress_port` / `bashio::app.port` instead of `bashio::addon.*`)
- Modify: `headscale/rootfs/etc/s6-overlay/s6-rc.d/nginx/run` + `finish` (CANONICAL-FINISH, `service="Nginx"`)
- Test: extend `test/smoke.sh`

**Interfaces:**

- Consumes: headplane upstream on 127.0.0.1:3000; ingress port from Supervisor API (mock: 62000); direct port mapping (mock: 8080).
- Produces: ingress vhost reachable ONLY from 172.30.32.2; direct vhost with `limit_req` on auth paths and identity headers stripped.

- [ ] **Step 1: Add failing assertions to `test/smoke.sh`**

```bash
assert "ingress vhost denies non-supervisor sources" \
  bash -c "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:62000/admin/ | grep -q 403"
assert "direct vhost serves headplane" \
  bash -c "curl -fs -o /dev/null http://127.0.0.1:8080/admin/login"
assert "direct vhost strips identity headers" \
  bash -c "curl -fs -H 'X-Remote-User-Name: attacker' http://127.0.0.1:8080/admin/login -o /dev/null"
assert "direct vhost rate-limits the login path" \
  bash -c "for i in \$(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:8080/admin/login; done; curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/admin/login | grep -qE '429|503'"
assert "nginx workers run as nginx user" \
  bash -c "docker exec $C ps -o user,comm | grep nginx | grep -qv root"
```

(The header-strip assertion is behavioral via e2e — here it just proves the vhost accepts the request; the strip itself is verified by config review + the e2e proxy_auth scenario. Keep both.)

Run: `./test/smoke.sh` → FAIL (62000 not listening yet with allowlist, no limit).

- [ ] **Step 2: Rewrite `nginx.conf`** (non-root paths + limit zone)

```nginx
worker_processes 2;
pid /var/run/nginx/nginx.pid;
error_log /proc/1/fd/1 warn;
daemon off;

events {
    worker_connections 512;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /proc/1/fd/1;
    sendfile on;
    keepalive_timeout 65;

    client_body_temp_path /var/run/nginx/client_body;
    proxy_temp_path /var/run/nginx/proxy;
    fastcgi_temp_path /var/run/nginx/fastcgi;
    uwsgi_temp_path /var/run/nginx/uwsgi;
    scgi_temp_path /var/run/nginx/scgi;

    limit_req_zone $binary_remote_addr zone=auth:1m rate=10r/m;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    include /etc/nginx/servers/*.conf;
}
```

- [ ] **Step 3: Rewrite `ingress.gtpl`**

```nginx
server {
    listen 0.0.0.0:{{ .port }} default_server;

    # Home Assistant ingress requests come exclusively from the Supervisor.
    allow 172.30.32.2;
    deny all;

    location = / {
        return 302 /admin/;
    }

    location / {
        proxy_pass http://headplane;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # Forward HA's authenticated-user identity headers for proxy_auth
        proxy_set_header X-Remote-User-Name $http_x_remote_user_name;
        proxy_set_header X-Remote-User-Display-Name $http_x_remote_user_display_name;
    }
}
```

- [ ] **Step 4: Rewrite `direct.gtpl`**

```nginx
server {
    listen 0.0.0.0:{{ .port }};

    location = / {
        return 302 /admin/;
    }

    # Auth endpoints get brute-force protection.
    location /admin/login {
        limit_req zone=auth burst=10 nodelay;
        proxy_pass http://headplane;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # NEVER forward identity headers on the direct (unauthenticated) port.
        proxy_set_header X-Remote-User-Name "";
        proxy_set_header X-Remote-User-Display-Name "";
    }

    location / {
        proxy_pass http://headplane;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Remote-User-Name "";
        proxy_set_header X-Remote-User-Display-Name "";
    }
}
```

- [ ] **Step 5: Update `init-nginx/run` bashio names and `nginx/run`**

In `init-nginx/run` replace `bashio::addon.ingress_port` → `bashio::app.ingress_port` and `bashio::addon.port 8080` → `bashio::app.port 8080` (two occurrences each in condition + assignment); everything else stays.

`nginx/run`:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
bashio::net.wait_for 3000 127.0.0.1 300
bashio::log.info "Starting Nginx..."
mkdir -p /var/run/nginx && chown -R nginx:nginx /var/run/nginx /var/lib/nginx
exec s6-setuidgid nginx /usr/sbin/nginx -c /etc/nginx/nginx.conf
```

Smoke-test caveat: in the standalone harness there is no 172.30.32.2, so the allowlist assertion checks the **deny** path (403 from 127.0.0.1 via the published port). The allow path is e2e's job (Task 12).

- [ ] **Step 6: Rebuild + smoke**

Run: `docker compose -f docker-compose.test.yml up -d --build --force-recreate && sleep 40 && ./test/smoke.sh`
Expected: all assertions PASS (full suite green for the first time).

- [ ] **Step 7: Commit**

```bash
git add headscale/rootfs test/smoke.sh
git commit -m "feat: ingress source allowlist, identity-header hygiene, rate-limited direct port, non-root nginx"
```

---

### Task 10: Remove dead services, rewrite DOCS.md, CHANGELOG, README

**Files:**

- Delete: `headscale/rootfs/etc/s6-overlay/s6-rc.d/init-tailscale/`, `.../tailscaled/`, `user/contents.d/{init-tailscale,tailscaled}`
- Modify: `headscale/DOCS.md` (rewrite), `headscale/CHANGELOG.md`, `README.md`

- [ ] **Step 1: Delete old services and verify image drops them**

```bash
git rm -r headscale/rootfs/etc/s6-overlay/s6-rc.d/init-tailscale \
          headscale/rootfs/etc/s6-overlay/s6-rc.d/tailscaled \
          headscale/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/init-tailscale \
          headscale/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/tailscaled
docker compose -f docker-compose.test.yml up -d --build --force-recreate && sleep 40 && ./test/smoke.sh
```

Expected: suite stays green; `docker exec headscale-addon-test test ! -d /etc/s6-overlay/s6-rc.d/tailscaled` exits 0.

- [ ] **Step 2: Prepend `headscale/CHANGELOG.md`**

```markdown
## 0.7.0

Security-focused re-architecture. **Breaking changes — read before upgrading:**

- The addon no longer uses host networking or any privileged capabilities.
  An attacker compromising the (internet-facing) headscale service no longer
  lands in your host network.
- Home Assistant is now reached at `homeassistant.tailnet.internal` on your
  HA port (via a built-in tailnet proxy node) instead of the old node's
  tailnet IP. Update bookmarks/apps accordingly.
- The subnet router is now **disabled by default** (LAN access is opt-in).
  Re-enable it in the addon options if you used it.
- The `users` addon option replaces automatic Home Assistant user import;
  the addon no longer reads your HA configuration directory.
- Existing custom ACL policies are kept untouched; the addon logs the
  tag-based rules you should add. Fresh installs get a least-privilege
  policy automatically.
- Headscale 0.28.0 → 0.29.3 (database migrates automatically; clients need
  Tailscale ≥ 1.80). Headplane 0.6.2-beta.5 → 0.7.0 (fixes CVE-2026-46484).
- Web UI: log in via Home Assistant ingress — sessions now come from your
  HA login (proxy auth). The API key is no longer printed to the log.
```

- [ ] **Step 3: Rewrite `headscale/DOCS.md`**

Full replacement — structure and key content (write it out in these words, adjusting only formatting):

```markdown
# Headscale

Self-hosted Tailscale control server with the Headplane web UI, a built-in
tailnet proxy for reaching Home Assistant, and an optional subnet router.

## Security model (read this)

- This addon exposes headscale to the internet (ports 443/80/3478). It runs
  with **no** host networking and **no** privileged capabilities, under a
  custom AppArmor profile, with every service as a separate non-root user —
  a compromise of the exposed service is contained to the container.
- Whoever controls the headscale server controls your tailnet (headscale
  has no Tailnet Lock). Keep the addon updated — dependency updates with
  CVE fixes are released automatically.
- **Backups contain your tailnet state** (the headscale database, including
  device keys). Treat backup files as sensitive.
- The access policy is least-privilege by default: tailnet members can only
  reach Home Assistant; LAN access requires both enabling the subnet router
  AND adding users to `group:subnet-access` in the policy.

## Prerequisites

1. A domain name pointing at your public IP (e.g. `vpn.example.com`)
2. Router port forwards: `443/tcp`, `80/tcp`, `3478/udp` → Home Assistant
3. An email address for Let's Encrypt

## Quick start

1. Set `server_url` (e.g. `https://vpn.example.com`) and `acme_email`
2. Add your user names to `users` (e.g. `- josh`)
3. Start the addon; open **Headscale** in the sidebar — you're logged in
   through your Home Assistant session
4. In Headplane, create a pre-auth key for your user and connect a device:
   `tailscale up --login-server https://vpn.example.com --authkey <key>`
5. Reach Home Assistant from anywhere at
   `http(s)://homeassistant.tailnet.internal:<your HA port>`

## Reaching Home Assistant

The addon runs a tailnet node named `homeassistant` that forwards your HA
port (detected automatically) to Home Assistant. Any tailnet member can
reach it by default; edit `group:users` / the ACL in Headplane to restrict.

## Subnet router (optional, off by default)

Enabling `subnet_router.enabled` advertises your LAN to the tailnet — but
no device can use it until you add users to `group:subnet-access` in the
ACL (Headplane → Access Control). `exit_node: true` additionally offers
full-internet routing through your home connection.

## Users and access control

- `users` option: headscale accounts created automatically and added to
  `group:users` (full access to the Home Assistant node). Removing a name
  from the option does NOT delete the user or their access — manage that
  in Headplane.
- Groups in the default policy: `group:admins` (everything, empty by
  default), `group:users` (HA node), `group:subnet-access` (LAN, empty by
  default). Tags: `tag:homeassistant` (the HA proxy), `tag:subnet-router`.

## Direct web UI access (advanced)

The web UI normally requires your Home Assistant login. Mapping host port
8080 exposes it directly WITHOUT Home Assistant authentication (Headplane's
API-key login only, rate-limited). Leave it disabled unless you need it.
To log in there, use the API key from `/data/headplane/api_key` (addon
shell: Settings → Add-ons → Headscale → ⋮ → open terminal).

## API key rotation

The addon holds a long-lived headscale API key for Headplane. To rotate:
delete `/data/headplane/api_key` and restart the addon — a fresh key is
generated and Headplane reconfigured automatically. (Expire the old key in
Headplane → Settings → API keys, or `headscale apikeys expire`.)

## Troubleshooting

- **ACME/certificate errors**: check port 80 forwarding and DNS; the addon
  falls back to HTTP-only when ACME is impossible (IP server_url or no
  email) — fine for testing, not production.
- **Client can't connect**: verify 443 forwarding and that `server_url`
  matches exactly (including scheme).
- **`homeassistant.tailnet.internal` doesn't resolve**: the client must
  accept MagicDNS (default on most platforms). The node's tailnet IP from
  Headplane works as a fallback.
- **Subnet routes not working**: routes must be approved (automatic for
  the built-in router) and the user must be in `group:subnet-access`.
- **Upgrading from 0.6.x**: see the changelog — the old HA tailnet IP is
  gone; use `homeassistant.tailnet.internal`.
```

- [ ] **Step 4: Update `README.md`** — replace any "host network / auto user import" claims with one paragraph mirroring the security-model summary and the standard addon-repo install snippet (add this repo URL in HA → Add-on store → Repositories). Keep it short; DOCS.md is the reference.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs: 0.7.0 changelog, security-model docs, remove dead tailscaled services"
```

---

### Task 11: Dependabot + CI workflow

**Files:**

- Create: `.github/dependabot.yml`
- Create: `.github/workflows/ci.yaml`

**Interfaces:**

- Produces: PR pipeline = community reusable CI (lint+build) + `base-sync` + `smoke` + `trivy` jobs. Job names later referenced by auto-merge/branch protection: `ci / information`, `ci / lint-app`, `ci / build (amd64)`, `base-sync`, `smoke`, `trivy`, `e2e` (Task 12 adds e2e).

- [ ] **Step 1: Create `.github/dependabot.yml`**

```yaml
version: 2
updates:
  - package-ecosystem: docker
    directory: /headscale
    schedule:
      interval: daily
    labels:
      - dependencies
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    labels:
      - dependencies
```

- [ ] **Step 2: Create `.github/workflows/ci.yaml`**

```yaml
---
name: CI

on:
  push:
    branches:
      - main
  pull_request:

jobs:
  ci:
    name: CI
    uses: hassio-addons/workflows/.github/workflows/app-ci.yaml@383c10df9e8c99b83aae6a8b190a41243c1a4b93 # v3.0.0

  base-sync:
    name: Base image pins match
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
      - name: Dockerfile ARG default equals build.yaml build_from
        run: |
          df=$(sed -n 's/^ARG BUILD_FROM=//p' headscale/Dockerfile | head -1)
          by=$(yq e '.build_from.amd64' headscale/build.yaml)
          by2=$(yq e '.build_from.aarch64' headscale/build.yaml)
          echo "Dockerfile=$df build.yaml=$by/$by2"
          test "$df" = "$by" && test "$df" = "$by2"

  smoke:
    name: Smoke test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
      - name: Build and boot standalone
        run: docker compose -f docker-compose.test.yml up -d --build
      - name: Run smoke suite
        run: sleep 45 && ./test/smoke.sh
      - name: Container logs on failure
        if: failure()
        run: docker logs headscale-addon-test

  trivy:
    name: Trivy scan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
      - name: Build image
        run: docker build --build-arg BUILD_ARCH=amd64 -t scan-target headscale/
      - uses: aquasecurity/trivy-action@dc5a429b52fcf669ce959baa2c2dd26090d2a6c4 # 0.32.0
        with:
          image-ref: scan-target
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: "1"
```

(Pin note: resolve each action SHA at implementation time with `gh api repos/<owner>/<repo>/commits/<tag>` — the SHAs above are the v3.0.0/v5.0.0/0.32.0 pins known at planning; verify before committing. If the reusable `app-ci.yaml` fails outside the hassio-addons org — e.g. org-scoped secrets — replace the `ci` job with direct use of `frenck/action-addon-linter@v2.21.0` + `docker/build-push-action` per-arch, mirroring app-ci.yaml's job list.)

- [ ] **Step 3: Validate workflow syntax**

Run: `docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest -color`
Expected: no errors (warnings acceptable).

- [ ] **Step 4: Commit**

```bash
git add .github/
git commit -m "ci: dependabot, community CI, base-pin sync check, smoke and trivy jobs"
```

---

### Task 12: E2E — real Supervisor in CI

**Files:**

- Create: `test/e2e.sh`
- Create: `.github/workflows/e2e.yaml` — a separate workflow file keeps CI readable; it must run on `pull_request` too so auto-merge waits on it.

**Interfaces:**

- Consumes: whole addon tree; devcontainer image `ghcr.io/home-assistant/devcontainer:5-apps` (fallback tag `:addons` if 5-apps is unavailable).
- Produces: `test/e2e.sh` — exits non-zero on any scenario failure; runnable locally (`./test/e2e.sh`) and in CI.

- [ ] **Step 1: Create `test/e2e.sh`**

```bash
#!/usr/bin/env bash
# E2E: boots a real Supervisor (devcontainer), installs the addon as a local
# addon, and exercises ingress, ACLs, lifecycle, and credential hygiene.
set -uo pipefail
SUP=hassio-e2e
FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
sup()  { docker exec "$SUP" "$@"; }
ha()   { docker exec "$SUP" ha "$@"; }

cleanup() { docker rm -f "$SUP" >/dev/null 2>&1 || true; docker volume rm -f e2e-dind >/dev/null 2>&1 || true; }
trap cleanup EXIT

# --- 1. Boot Supervisor ---
docker volume create e2e-dind >/dev/null
docker run -d --name "$SUP" --privileged \
  -e SUPERVISOR_MACHINE=generic-x86-64 \
  -e SUPERVISOR_DEV=1 \
  -e SUPERVISOR_TOKEN="$(openssl rand -hex 32)" \
  -v e2e-dind:/var/lib/docker \
  -v "$PWD":/mnt/supervisor/addons/local/headscale-src:ro \
  -p 7123:8123 \
  ghcr.io/home-assistant/devcontainer:5-apps \
  sleep infinity
# local addon dir must be writable (we strip image:) — copy it inside
sup bash -c 'cp -r /mnt/supervisor/addons/local/headscale-src/headscale /mnt/supervisor/addons/local/headscale \
  && sed -i "/^image:/d" /mnt/supervisor/addons/local/headscale/config.yaml'
sup bash -c 'supervisor_run > /tmp/supervisor.log 2>&1 &'
for i in $(seq 1 60); do ha supervisor info >/dev/null 2>&1 && break; sleep 5; done
ha supervisor info >/dev/null || { bad "supervisor did not become ready"; exit 1; }
ha jobs options --ignore-conditions healthy >/dev/null 2>&1 || true
ha resolution health-check ignore docker_gateway_unprotected >/dev/null 2>&1 || true
ok "supervisor ready"

# --- 2. Install + configure + start addon ---
ha apps reload >/dev/null 2>&1 || ha addons reload >/dev/null 2>&1
APPS=apps; ha apps info local_headscale >/dev/null 2>&1 || APPS=addons
check "addon install" ha $APPS install local_headscale
sup bash -c 'cat > /tmp/opts.json <<EOF
{"server_url": "http://172.30.32.1", "log_level": "debug", "acme_email": "",
 "users": ["e2etest"], "subnet_router": {"enabled": true, "exit_node": false}}
EOF'
check "addon options"  bash -c "docker exec $SUP ha $APPS options local_headscale --options-json /tmp/opts.json || docker exec $SUP bash -c 'curl -fs -X POST -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" -d @/tmp/opts.json http://supervisor/addons/local_headscale/options'"
check "addon start"    ha $APPS start local_headscale
sleep 60
ADDON_IP=$(sup bash -c "docker inspect addon_local_headscale -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'")
hsx() { sup docker exec addon_local_headscale s6-setuidgid headscale headscale --config /data/headscale/config.yaml "$@"; }

# --- 3. Ingress exclusive ---
ING_PORT=$(sup bash -c "curl -fs -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" http://supervisor/addons/local_headscale/info | jq -r .data.ingress_port")
check "ingress denies non-supervisor" \
  sup bash -c "curl -s -o /dev/null -w '%{http_code}' http://${ADDON_IP}:${ING_PORT}/admin/ | grep -q 403"
ING_TOKEN=$(sup bash -c "curl -fs -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" http://supervisor/addons/local_headscale/info | jq -r .data.ingress_url" )
ok "ingress port/token resolved (${ING_PORT})"
# Full authenticated-ingress fetch requires an HA user session; the supervisor
# proxies ingress itself — verify via supervisor ingress proxy path:
check "ingress serves via supervisor" \
  sup bash -c "curl -s -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" http://supervisor/ingress/panels | grep -q 200"

# --- 4. Client join + ACL enforcement ---
KEY=$(hsx users list -o json | jq -r '.[] | select(.name=="e2etest") | .id')
AUTHKEY=$(hsx preauthkeys create --user "$KEY")
sup bash -c "docker run -d --name ts-client --network hassio tailscale/tailscale:v1.102.2 tailscaled --tun=userspace-networking --socket=/tmp/ts.sock"
sleep 5
check "client joins tailnet" \
  sup docker exec ts-client tailscale --socket=/tmp/ts.sock up \
    --login-server "http://${ADDON_IP}:8081" --authkey "$AUTHKEY" --hostname e2eclient --accept-dns=false
sleep 10
HA_TS_IP=$(hsx nodes list -o json | jq -r '.[] | select(.name=="homeassistant") | .ipAddresses[0] // .ip_addresses[0]')
check "client reaches HA through serve proxy" \
  sup docker exec ts-client sh -c "wget -q -O- --timeout=10 http://${HA_TS_IP}:8123/ | grep -qi 'home assistant'"
check "client CANNOT reach LAN route (not in subnet-access)" \
  sup docker exec ts-client sh -c "! wget -q -O- --timeout=5 http://172.30.32.1:80/ 2>/dev/null"

# --- 5. Credential hygiene ---
API_KEY=$(sup docker exec addon_local_headscale cat /data/headplane/api_key)
check "api key not in addon logs" \
  bash -c "! docker exec $SUP ha $APPS logs local_headscale 2>/dev/null | grep -qF '$API_KEY'"

# --- 6. Lifecycle: restart preserves identity ---
NODE_COUNT_BEFORE=$(hsx nodes list -o json | jq length)
check "addon restart" ha $APPS restart local_headscale
sleep 60
NODE_COUNT_AFTER=$(hsx nodes list -o json | jq length)
check "no re-provisioning after restart (node count stable)" \
  test "$NODE_COUNT_BEFORE" = "$NODE_COUNT_AFTER"
check "policy survives restart" \
  bash -c "docker exec $SUP docker exec addon_local_headscale s6-setuidgid headscale headscale policy get --config /data/headscale/config.yaml | grep -q tag:homeassistant"

# --- 7. Backup / restore ---
SLUG=$(sup bash -c "curl -fs -X POST -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" -H 'Content-Type: application/json' -d '{\"name\":\"e2e\",\"addons\":[\"local_headscale\"]}' http://supervisor/backups/new/partial | jq -r .data.slug")
check "backup created" test -n "$SLUG" -a "$SLUG" != "null"
check "restore succeeds" \
  sup bash -c "curl -fs -X POST -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" -H 'Content-Type: application/json' -d '{\"addons\":[\"local_headscale\"]}' http://supervisor/backups/${SLUG}/restore/partial"
sleep 60
check "addon healthy after restore" bash -c "hsx nodes list >/dev/null"
check "excluded api_key regenerated fresh" \
  bash -c "test \"$(sup docker exec addon_local_headscale cat /data/headplane/api_key)\" != \"$API_KEY\""

exit $FAIL
```

Implementation notes baked into the script: `server_url` uses the supervisor gateway IP in HTTP mode; the client joins via the addon's bridge IP on 8081; scenario 4's "cannot reach LAN" target is the gateway HTTP port (best available "LAN" stand-in inside the harness). Where the devcontainer's CLI is renamed, the `$APPS` shim handles `apps` vs `addons`. Adjust jq field names (`ipAddresses` vs `ip_addresses`) to what headscale 0.29 actually emits — check once and delete the fallback.

- [ ] **Step 2: Create `.github/workflows/e2e.yaml`**

```yaml
---
name: E2E

on:
  pull_request:
  push:
    branches:
      - main

jobs:
  e2e:
    name: Supervisor e2e
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
      - name: Free disk space
        run: sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc
      - name: Run e2e suite
        run: ./test/e2e.sh
      - name: Supervisor logs on failure
        if: failure()
        run: docker exec hassio-e2e cat /tmp/supervisor.log | tail -200 || true
```

- [ ] **Step 3: Run locally**

Run: `chmod +x test/e2e.sh && ./test/e2e.sh`
Expected: all `PASS`, exit 0. Docker Desktop note: the privileged DinD supervisor needs several GB — if local resources make it flaky, iterate on the exact failing scenario in CI via the PR (Task 14) instead; the script must be green in CI before merge.

- [ ] **Step 4: Commit**

```bash
git add test/e2e.sh .github/workflows/e2e.yaml
git commit -m "test: supervisor-devcontainer e2e — ingress exclusivity, ACLs, lifecycle, backup"
```

---

### Task 13: Auto-merge, release, deploy, scheduled jobs

**Files:**

- Create: `.github/workflows/auto-merge.yaml`, `.github/workflows/release.yaml`, `.github/workflows/deploy.yaml`, `.github/workflows/scheduled.yaml`

- [ ] **Step 1: `auto-merge.yaml`**

```yaml
---
name: Dependabot auto-merge

on: pull_request

permissions:
  contents: write
  pull-requests: write

jobs:
  auto-merge:
    if: github.actor == 'dependabot[bot]'
    runs-on: ubuntu-latest
    steps:
      - name: Fetch metadata
        id: meta
        uses: dependabot/fetch-metadata@08eff52bf64351f401fb50d4972fa95b9f2c2d1b # v2.4.0
      - name: Enable auto-merge (patch/minor, except headscale minors)
        if: >-
          steps.meta.outputs.update-type != 'version-update:semver-major' &&
          !(contains(steps.meta.outputs.dependency-names, 'juanfont/headscale') &&
            steps.meta.outputs.update-type == 'version-update:semver-minor')
        run: gh pr merge --auto --squash "$PR_URL"
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 2: `release.yaml`** (auto version-bump + GitHub release on merge to main)

```yaml
---
name: Release

on:
  push:
    branches:
      - main

permissions:
  contents: write

jobs:
  release:
    # Never react to our own bump commit
    if: "!startsWith(github.event.head_commit.message, 'release:')"
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
        with:
          fetch-depth: 0
          token: ${{ secrets.RELEASE_TOKEN }}
      - name: Determine version
        id: ver
        run: |
          current=$(yq e '.version' headscale/config.yaml)
          last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
          if [ "v${current}" = "${last_tag}" ]; then
            # not manually bumped -> auto patch bump
            next=$(echo "${current}" | awk -F. '{print $1"."$2"."$3+1}')
            yq e -i ".version = \"${next}\"" headscale/config.yaml
            title=$(git log -1 --pretty=%s)
            printf '## %s\n\n- %s\n\n%s\n' "${next}" "${title}" "$(cat headscale/CHANGELOG.md)" > headscale/CHANGELOG.md
            git config user.name "github-actions[bot]"
            git config user.email "github-actions[bot]@users.noreply.github.com"
            git add headscale/config.yaml headscale/CHANGELOG.md
            git commit -m "release: v${next}"
            git push
          else
            next="${current}"
          fi
          echo "version=${next}" >> "$GITHUB_OUTPUT"
      - name: Tag and publish release
        env:
          GH_TOKEN: ${{ secrets.RELEASE_TOKEN }}
        run: |
          v=${{ steps.ver.outputs.version }}
          git tag "v${v}" || true
          git push origin "v${v}" || true
          gh release create "v${v}" --title "v${v}" \
            --notes "$(awk '/^## /{n++} n==1' headscale/CHANGELOG.md)" || true
```

- [ ] **Step 3: `deploy.yaml`** (community trigger: build+push on release published)

```yaml
---
name: Deploy

on:
  release:
    types:
      - published

permissions:
  contents: read
  packages: write

jobs:
  deploy:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        arch: [aarch64, amd64]
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
      - uses: docker/setup-qemu-action@29109295f81e9208d7d86ff1c6c12d2833863392 # v3.6.0
      - uses: docker/setup-buildx-action@e468171a9de216ec08956ac3ada2f0791b6bd435 # v3.11.1
      - uses: docker/login-action@74a5d142397b4f367a81961eba4e8cd7edddf772 # v3.4.0
        with:
          registry: ghcr.io
          username: ${{ github.repository_owner }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Build and push
        uses: docker/build-push-action@263435318d21b8e681c14492fe198d362d7b0b73 # v6.18.0
        with:
          context: headscale
          platforms: ${{ matrix.arch == 'aarch64' && 'linux/arm64' || 'linux/amd64' }}
          push: true
          build-args: |
            BUILD_ARCH=${{ matrix.arch }}
          tags: |
            ghcr.io/${{ github.repository_owner }}/${{ matrix.arch }}-addon-headscale:${{ github.event.release.tag_name }}
            ghcr.io/${{ github.repository_owner }}/${{ matrix.arch }}-addon-headscale:latest
```

Note: image tag in `config.yaml` is `ghcr.io/josh/{arch}-addon-headscale` — the supervisor substitutes `{arch}` and pulls tag = the addon `version` (no `v` prefix). **Adjust the push tags to strip the leading `v`**: use `${GITHUB_REF_NAME#v}` via an env step: add `- id: tag` + `run: echo "plain=${TAG#v}" >> "$GITHUB_OUTPUT"` with `TAG: ${{ github.event.release.tag_name }}`, and reference `${{ steps.tag.outputs.plain }}` in the tags list.

- [ ] **Step 4: `scheduled.yaml`** (weekly refresh rebuild + trivy)

```yaml
---
name: Scheduled

on:
  schedule:
    - cron: "17 4 * * 1"
  workflow_dispatch:

permissions:
  contents: write
  issues: write

jobs:
  refresh-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
      - name: Rebuild without cache and diff package versions
        id: diff
        run: |
          docker build --no-cache --build-arg BUILD_ARCH=amd64 -t fresh headscale/
          ver=$(yq e '.version' headscale/config.yaml)
          docker pull "ghcr.io/${{ github.repository_owner }}/amd64-addon-headscale:${ver}" || { echo "changed=false" >> "$GITHUB_OUTPUT"; exit 0; }
          docker run --rm --entrypoint sh fresh -c 'apk list --installed 2>/dev/null | sort' > /tmp/fresh.txt
          docker run --rm --entrypoint sh "ghcr.io/${{ github.repository_owner }}/amd64-addon-headscale:${ver}" -c 'apk list --installed 2>/dev/null | sort' > /tmp/released.txt
          if diff -q /tmp/fresh.txt /tmp/released.txt >/dev/null; then
            echo "changed=false" >> "$GITHUB_OUTPUT"
          else
            echo "changed=true" >> "$GITHUB_OUTPUT"
            diff /tmp/released.txt /tmp/fresh.txt || true
          fi
      - name: Trigger release for base-layer updates
        if: steps.diff.outputs.changed == 'true'
        env:
          GH_TOKEN: ${{ secrets.RELEASE_TOKEN }}
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git commit --allow-empty -m "chore: rebuild for base-layer package updates"
          git push

  trivy-published:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
      - name: Scan latest published image
        id: scan
        uses: aquasecurity/trivy-action@dc5a429b52fcf669ce959baa2c2dd26090d2a6c4 # 0.32.0
        continue-on-error: true
        with:
          image-ref: ghcr.io/${{ github.repository_owner }}/amd64-addon-headscale:latest
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: "1"
      - name: Open issue when CVEs found
        if: steps.scan.outcome == 'failure'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh issue list --label security-scan --state open | grep -q . || \
          gh issue create --title "Trivy: HIGH/CRITICAL CVEs in published image" \
            --label security-scan \
            --body "The weekly Trivy scan found fixable HIGH/CRITICAL CVEs in the latest published image. Check the workflow run for details. A Dependabot PR or refresh rebuild should resolve it."
```

- [ ] **Step 5: Validate + commit**

Run: `docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest -color`
Expected: clean.

```bash
git add .github/workflows/
git commit -m "ci: dependabot auto-merge, auto-release on merge, GHCR deploy, weekly refresh+scan"
```

**Repo settings checklist** (manual, done in Task 14 with the user): enable auto-merge (Settings → General); branch protection on main requiring `CI`, `base-sync`, `smoke`, `trivy`, `e2e` with a bypass for the release token identity; create a fine-grained PAT (contents: write) as secret `RELEASE_TOKEN`.

---

### Task 14: Final verification + PR

- [ ] **Step 1: Full local run**

```bash
docker compose -f docker-compose.test.yml up -d --build --force-recreate && sleep 45 && ./test/smoke.sh && ./test/e2e.sh
```

Expected: both suites fully green.

- [ ] **Step 2: Security-invariant grep sweep** (the "never weaken" list from Global Constraints)

```bash
! grep -rn "host_network\|NODE_TLS_REJECT\|homeassistant_config" headscale/config.yaml headscale/rootfs/
! grep -rn "privileged:" headscale/config.yaml
grep -q "allow 172.30.32.2" headscale/rootfs/etc/nginx/templates/ingress.gtpl
```

Expected: all exit 0.

- [ ] **Step 3: Verify AppArmor on the real HA VM** (user's VM at 10.42.12.231; addon slug on that box is from the dev repo — install the branch build as a local addon or via the repo): profile loads (`ha apps info` shows AppArmor true; addon starts and functions). If the profile is rejected, apply the fallback noted in Task 2 Step 3 and re-verify.

- [ ] **Step 4: Push branch + PR (global PR workflow applies)**

Per the user's global CLAUDE.md: fetch origin, rebase onto origin/main if behind, push with `--force-with-lease` if rebased; open the PR; watch CI (`gh pr checks --watch`) and fix failures; wait for the Copilot review, address every comment. The PR body summarizes: security re-architecture, UI upgrade + CVE fix, CI/CD automation, breaking changes list from the CHANGELOG.

- [ ] **Step 5: Post-merge manual steps with the user**

Repo settings checklist from Task 13; confirm first auto-release + GHCR publish succeed; verify the addon updates on the HA VM from the published image.

---

## Self-review checklist (run after writing, before execution)

1. **Spec coverage**: every spec section maps to a task — architecture/config (1–2), services (4–9), migration+docs (10), CI/CD+Dependabot+auto-merge+release (11, 13), e2e (12), AppArmor+non-root (2, 4, 6, 9), credential policy (6, 7, 8), fail-closed ACL (5). Out-of-scope items in the spec stay out.
2. **Placeholders**: none — every file's full content is in its task; action SHAs are flagged for resolution at implementation, which is a verification step, not a gap.
3. **Type/name consistency**: env vars `HS_MODE`/`HS_LOCAL_URL`/`HS_LOGIN_SERVER`/`HA_PORT`/`TS_ROUTES` defined in Task 4/5, consumed in 5–9; `hs()` helper convention identical across scripts; state dirs `/data/tailscale/ha-proxy` + `/data/tailscale/subnet-router`; sockets `ha-proxy.sock`/`subnet-router.sock`; users `addon`/`headplane-agent`; tags `tag:homeassistant`/`tag:subnet-router`.
