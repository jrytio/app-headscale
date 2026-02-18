# Headscale Home Assistant Addon — Design Document

**Date:** 2026-02-18
**Status:** Approved

## Overview

A Home Assistant addon that bundles Headscale (self-hosted Tailscale control server), Headplane (web management UI), and an optional Tailscale subnet router into a single all-in-one addon. Follows the established HA addon pattern (AdGuard Home as reference) with s6-overlay process management and nginx ingress.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| UI | Headplane (tale/headplane) | Actively maintained, Headscale 0.28 support, MIT license, SSR keeps API key server-side |
| Scope | All-in-one (headscale + headplane + subnet router) | Simplest UX for HA users |
| Networking | Host network + user configures DNS/port forwarding | Standard self-hosted VPN pattern |
| TLS | Let's Encrypt via headscale built-in ACME | Zero-config TLS, user provides domain + email |
| Subnet routes | Auto-detect LAN + user can override | Smart defaults, full flexibility |
| ACL default | Simple allow-all | Avoids confusing new users; tighten via headplane UI |
| UI access | HA ingress + optional direct access | Sidebar integration as primary, fallback on separate port |
| Base image | node:22-alpine (Node.js LTS) | Headplane requires Node.js runtime; Alpine base keeps image small |
| Process manager | s6-overlay (installed on top of node:22-alpine) | Proven HA addon pattern for managing multiple services |
| Build pattern | Binary download (headscale + headplane from GitHub releases, tailscale from apk) | Smallest image, fastest builds, follows AdGuard Home addon pattern |

## Repository Structure

```
app-headscale/
├── .github/
│   └── workflows/
│       ├── ci.yaml
│       └── deploy.yaml
├── headscale/
│   ├── config.yaml
│   ├── build.yaml
│   ├── Dockerfile
│   ├── DOCS.md
│   ├── CHANGELOG.md
│   ├── icon.png
│   ├── logo.png
│   └── rootfs/
│       └── etc/
│           ├── headscale/
│           │   └── config.yaml
│           ├── nginx/
│           │   ├── nginx.conf
│           │   └── templates/
│           │       ├── ingress.gtpl
│           │       ├── direct.gtpl
│           │       └── upstream.gtpl
│           └── s6-overlay/
│               └── s6-rc.d/
│                   ├── user/contents.d/
│                   ├── init-headscale/
│                   ├── init-headplane/
│                   ├── init-tailscale/
│                   ├── init-nginx/
│                   ├── headscale/
│                   ├── headplane/
│                   ├── tailscaled/
│                   └── nginx/
├── images/
│   └── screenshot.png
├── LICENSE.md
└── README.md
```

## Addon Configuration (config.yaml)

```yaml
name: Headscale
version: dev
slug: headscale
description: Self-hosted Tailscale control server with web UI
url: https://github.com/your-org/app-headscale
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

## Dockerfile & Build

**Base image:** `node:22-alpine` (Node.js LTS)

**Layered on top:**
- s6-overlay (downloaded from GitHub releases, arch-specific)
- nginx (apk)
- tailscale (apk)
- bash, jq, yq-go, curl (apk)
- headscale binary (downloaded from GitHub releases, arch-specific)
- headplane pre-built release (downloaded from GitHub releases)

**build.yaml:**
```yaml
build_from:
  aarch64: node:22-alpine
  amd64: node:22-alpine
args:
  BUILD_ARCH: "{arch}"
```

**Version pins as Dockerfile ARGs:**
- `HEADSCALE_VERSION=0.28.0`
- `HEADPLANE_VERSION=0.6.2`
- `S6_OVERLAY_VERSION=3.2.0.2`

Note: Headplane release artifact format needs verification during implementation. May need to extract from Docker image or build from source if no standalone tarball is published.

## Service Architecture (s6-overlay)

**Dependency graph:**
```
init-headscale (oneshot)
  ├──→ headscale (longrun)
  │      ├──→ init-headplane (oneshot) → headplane (longrun)
  │      ├──→ init-tailscale (oneshot) → tailscaled (longrun)
  │      └──→ init-nginx (oneshot) → nginx (longrun)
```

| Service | Type | Description |
|---|---|---|
| init-headscale | oneshot | Copy default config to /data on first run. Patch server_url, ACME, DB path, ACL mode via yq. |
| headscale | longrun | `headscale serve` on :443 (HTTPS), :3478/udp (STUN), :80 (ACME) |
| init-headplane | oneshot | Wait for headscale ready. Generate API key (first run) or read stored key. Write headplane env. |
| headplane | longrun | Node.js SSR on 127.0.0.1:3000. Talks to headscale via localhost. |
| init-tailscale | oneshot | Wait for headscale. Create subnet-router user + pre-auth key. Configure tailscaled. Skip if disabled. |
| tailscaled | longrun | tailscale daemon with --advertise-routes (auto-detect or configured) and optional --advertise-exit-node. |
| init-nginx | oneshot | Generate nginx configs from templates. Ingress block (allow 172.30.32.2), direct access block with auth_request. |
| nginx | longrun | Reverse proxy. Ingress → headplane:3000. Direct access on :8080 with HA auth. |

All longrun services have finish scripts that halt the container on unexpected exit.

## Data Persistence

```
/data/
├── headscale/
│   ├── config.yaml          # Patched on every start
│   ├── db.sqlite            # Headscale database
│   ├── noise_private.key    # WireGuard noise key (auto-generated, excluded from backup)
│   ├── derp.yaml            # Optional custom DERP map
│   └── acl_policy.json      # Initial ACL seed (first run only)
├── headplane/
│   ├── data/                # Headplane SQLite DB
│   └── api_key              # Stored headscale API key
└── tailscale/
    └── state/               # Tailscale state directory
```

**First run:** Copy config template, headscale auto-creates keys + DB, seed allow-all ACL, create subnet-router user, generate + store API key.

**Every start:** Read /data/options.json, patch headscale config with yq (server_url, acme_email, listen_addr, etc.), read stored API key, auto-detect LAN routes if needed, generate nginx configs, start services.

## User Documentation (DOCS.md)

Sections:
1. **Prerequisites** — domain, port forwarding (443, 80, 3478), email for Let's Encrypt
2. **Quick Start** — set server_url + acme_email, start, open sidebar UI
3. **Connecting Clients** — per-platform tailscale up commands with --login-server
4. **Subnet Router** — auto-detect vs custom routes, exit node, verification
5. **Managing Your Network** — users, pre-auth keys, devices, ACLs, routes (via headplane UI)
6. **Troubleshooting** — ACME, connectivity, subnet router, log checking

## Reference Implementations

- **AdGuard Home addon:** https://github.com/hassio-addons/addon-adguard-home (structural pattern)
- **Existing K8s headscale:** `../additv/infrastructure/headscale/` (headscale config, ACL, subnet router)
- **PR #271 vpn-proxy:** https://github.com/tidelineio/additv/pull/271 (headscale API patterns, user/key flows)
- **Headplane:** https://github.com/tale/headplane (UI project)
