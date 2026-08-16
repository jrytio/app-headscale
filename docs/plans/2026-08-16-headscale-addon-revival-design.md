# Headscale Addon Revival — Design Document

**Date:** 2026-08-16
**Status:** Draft — pending review
**Supersedes:** parts of `2026-02-18-headscale-addon-design.md` (architecture and provisioning sections; the original remains the reference for the base addon structure)

## Overview

Revival of the Headscale Home Assistant addon (last shipped v0.6.0, February 2026) with three goals:

1. **Security-first re-architecture** — a compromise of the internet-facing headscale server must not hand an attacker the host network or the home LAN.
2. **Current, patched components** — both pinned versions carry known security fixes upstream (Headplane 0.6.2-beta.5 is inside the CVE-2026-46484 HIGH affected range; headscale 0.29.3 contains auth-path hardening).
3. **Automation** — CI, automated releases on merge to main, and Dependabot-driven dependency updates so upstream CVE fixes reach users' Home Assistant instances without a human in the loop.

## Background: review findings (August 2026)

### UI re-evaluation — keep Headplane

| | Headplane | headscale-admin | headscale-ui (guru) | 2026 newcomers |
|---|---|---|---|---|
| Latest release | v0.7.0 (2026-07) | 2025-04 | 2026-03 | none |
| Commits, last 6 mo | 226 | 0 | 8 | — |
| Headscale 0.29 | explicit | no (no 0.26+ at all) | untested | unclear |
| API key location | server-side | browser | browser localStorage | browser |
| ACL editor / OIDC | yes / yes | yes / no | no / no | — |
| License | MIT | GPL-3.0 | BSD-3 | none |

Headplane is the only actively maintained, feature-complete option and the only SSR design (API key stays server-side; the browser holds only a session cookie) — the right model behind HA ingress. Decision: **keep Headplane, upgrade to v0.7.0 stable**. The upgrade is security-motivated: 0.6.2-beta.5 is vulnerable to CVE-2026-46484 / GHSA-vgj6-hcf2-fqf6 (CVSS 8.1, RBAC bypass via path traversal in rename operations; fixed 0.6.3).

### Security findings driving this design

1. `host_network: true` puts the internet-facing headscale in the host network namespace — RCE means immediate LAN access with NET_RAW/NET_ADMIN. The single largest blast-radius problem.
2. The ingress nginx listens on `0.0.0.0:<ingress_port>` with no source allowlist — with host networking, the admin UI is reachable from the LAN without HA authentication (same pattern as HA advisory GHSA-gh5m-4m97-c95h; the Supervisor firewall fix does not cover host-network binds).
3. `homeassistant_config:ro` maps HA's entire config dir (including `secrets.yaml` and `.storage` credential stores) into the most-exposed container, only to enumerate usernames.
4. `NODE_TLS_REJECT_UNAUTHORIZED=0` set container-wide disables all TLS validation in Headplane.
5. Credential hygiene: API key and pre-auth keys printed to the persistent addon log; reusable 10-year pre-auth keys on disk; nearly all of `/data` included in HA backups; API key created with headscale's default 90-day expiry (silently breaks Headplane login ~3 months post-install).
6. Seed ACL applied only after the HA node joins, failures swallowed (`2>/dev/null`); tailnet runs headscale's allow-all default until then. `10.0.0.0/8` fallback route in the policy.
7. Supply chain: binaries curl-downloaded without checksums, tailscale from unpinned Alpine edge, no AppArmor profile, all services root, no rebuild cadence for base-layer (nginx/Node) CVE fixes.

### Residual risk statement (documented in DOCS.md)

Headscale does not support Tailnet Lock (upstream issue #1307, open since 2023). Whoever controls the headscale server controls the tailnet: they can mint keys, join nodes, and rewrite ACLs. No addon design can remove that; this design's job is to make the server hard to compromise, make the container a dead end if it is compromised, and keep components patched automatically. DOCS.md will state this honestly, plus: backups contain the headscale database (node keys, pre-auth keys) and must be treated as sensitive.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| UI | Headplane v0.7.0 (stable) | Only maintained option; server-side API key; fixes CVE-2026-46484; headscale 0.29 support |
| Headscale | 0.29.3 | Auth-path hardening; strict no-skip minor upgrade path makes one-minor bumps the safe cadence |
| Networking | Bridge (drop `host_network`) | RCE lands in an isolated netns: NAT-only outbound, no ARP/sniffing, no host loopback/iptables |
| Privileges | None (drop NET_ADMIN, NET_RAW, TUN) | Subnet router runs userspace-networking; nothing else needs capabilities |
| HA reachability | `tailscale serve` TCP proxy on an always-on tagged node named `homeassistant` | HA reachable at its own MagicDNS name with no subnet router, no accept-routes, no LAN-IP/DHCP dependency; HA's port discovered from the Supervisor core API (no hardcoded 8123 — modern HA installs use standard HTTPS) |
| Subnet router | Separate, optional userspace tailscaled node — **default disabled** | LAN exposure is strictly opt-in; decoupled from HA access entirely |
| User provisioning | `users:` addon option, provisioned at startup | Replaces reading HA's `.storage`; `homeassistant_config` map removed |
| Dependency updates | All deps as Dockerfile `FROM` stages + Dependabot | Dependabot docker ecosystem sees every version; CVE fixes arrive as PRs |
| Releases | Auto version-bump + GHCR image publish on merge to main | Dependabot merges become user-visible HA updates without manual steps |
| E2E testing | Supervisor devcontainer in CI (only) | The approach community addons actually use; proven in public CI workflows. HAOS-in-QEMU deliberately not planned (reference sketch kept in Future work) |
| Conventions | Follow hassio-addons community addon patterns wherever a choice is otherwise open | Keeps the path open to eventually merging this as a community addon |

## Community addon alignment

Guiding principle for every otherwise-open choice: **do what the hassio-addons org does**, so the addon could plausibly be adopted as a community addon later. Concretely:

- Base image, s6-overlay usage, bashio idioms, `rootfs/` layout, DOCS.md/README structure, `apparmor.txt`, and `.github` workflow structure are modeled on a current first-tier community addon (AdGuard Home remains the reference; re-check its current form at implementation time rather than trusting the v0.6.0 copy).
- Add `translations/en.yaml` for the config options (community-standard, currently missing from this addon).
- CI reuses the community actions where they exist (addon linter, HA builder) and mirrors the hassio-addons workflow naming/trigger chain.
- Release mechanics align with the community chain (deploy on `release: published`) while staying fully automated — see Release pipeline.
- **Documented deviations** (deliberate, security-motivated, each with rationale in the spec): dedicated non-root users per service (community addons typically run as root), the fail-closed first-run policy gate, and the Supervisor-devcontainer e2e job (community addons rely on build+lint only).

## Architecture

Single all-in-one addon as before: headscale + Headplane + subnet router + nginx under s6-overlay. What changes is the isolation boundary and the service layout.

### config.yaml (delta from v0.6.0)

```yaml
version: 0.7.0
image: ghcr.io/josh/{arch}-addon-headscale   # prebuilt images; CI-tested bits are what users run
ingress: true
ingress_port: 0
# host_network: removed
# privileged: removed
# auth_api: removed (unused)
hassio_api: true          # kept: ingress port lookup + Supervisor network info
ports:
  8443/tcp: 443           # headscale HTTPS (internal unprivileged port → host 443)
  8081/tcp: 80            # ACME HTTP-01 challenge listener
  3478/udp: 3478          # STUN
  8080/tcp: null          # optional direct Headplane access (disabled by default)
map:
  - ssl                   # homeassistant_config removed
options:
  server_url: ""
  log_level: info
  acme_email: ""
  users: []
  subnet_router:
    enabled: false          # LAN exposure is opt-in (was true; breaking-change note in CHANGELOG)
    exit_node: false
schema:
  users:
    - str
  # rest unchanged
backup_exclude:
  - "*/headscale/noise_private.key"
  - "*/headscale/derp_server_private.key"
  - "*/headplane/api_key"
  - "*/headplane/cookie_secret"
```

Notes:
- All internal listeners live on unprivileged ports (8443, 8081, 3478, 3000, 8080, dynamic ingress port), remapped by the `ports:` map. This is what lets every service drop root.
- `apparmor.txt` ships alongside `config.yaml` (see Hardening), and `translations/en.yaml` documents every option in the HA UI (community standard).
- Existing `subnet_router.routes` stays removed (auto-detect via Supervisor API; power users can be given the option back later if demand exists).

### Service graph (s6-overlay)

```
init-headscale (oneshot: config patch, /etc/hosts pin)
  └─→ headscale (longrun, user: headscale)
        ├─→ init-policy (oneshot: create users, then seed/merge ACL — FAIL-CLOSED on first run)
        │     ├─→ init-headplane (oneshot) → headplane (longrun, user: headplane)
        │     ├─→ init-ha-proxy (oneshot) → ts-ha-proxy (longrun, user: tailscale, userspace, always on)
        │     ├─→ init-subnet-router (oneshot) → ts-subnet-router (longrun, user: tailscale, userspace, optional)
        │     └─→ init-nginx (oneshot) → nginx (longrun, user: nginx)
```

Changes from v0.6.0:
- New `init-policy` oneshot: creates headscale users from the `users` option first (headscale rejects a policy whose groups reference nonexistent users — creation must precede the seed), then applies the ACL **before any node can join** (it no longer waits for a tailnet IP; tag-based rules need no IPs). On **first run**, a policy-apply failure is fatal (`bashio::exit.nok` → container halts): the addon must never run on headscale's allow-all default. On subsequent runs the policy exists in the DB, so failures of the surgical updates (below) log loudly but don't kill the addon.
- **`ts-ha-proxy`** (always on): userspace tailscaled, node name `homeassistant`, joined with tag `tag:homeassistant`. Runs `tailscale serve` in TCP-forward mode proxying HA's actual port — discovered via the Supervisor core API (`bashio::core.port`; **not** hardcoded 8123, since modern HA installs serve standard HTTPS) — to the internal `homeassistant` hostname on the hassio network. HA terminates its own TLS exactly as it does on the LAN; clients reach `homeassistant.<base_domain>` regardless of subnet routing, accept-routes, or MagicDNS extra records. *(Implementation-plan step: verify `tailscale serve --tcp` against headscale 0.29; fallback if it misbehaves is the subnet-route + `dns.extra_records` design this replaces.)*
- **`ts-subnet-router`** (optional, **default disabled** — LAN exposure is opt-in): userspace tailscaled, tag `tag:subnet-router`, advertises Supervisor-API-detected (or future user-configured) routes. Completely decoupled from HA access.
- Both tailscale nodes: `--tun=userspace-networking`, no TUN device, no capabilities.
- Every longrun runs under a dedicated non-root user via `s6-setuidgid`; `/data` subdirectories are chowned per service. Only s6 init itself is root. Exception: the nginx MASTER process stays root — as non-root it cannot open s6's root-owned stdout pipe (/proc/1/fd/1) for addon-log output; all worker processes (which handle every untrusted request) drop to the nginx user, and the AppArmor nginx sub-profile already provisions exactly this (setuid/setgid + /proc/1/fd/* w). A fully non-root alternative via an s6-log consumer pipeline is noted as future work.

### Networking and TLS

- **Ingress**: nginx serves the Supervisor-assigned ingress port with `allow 172.30.32.2; deny all;`. HA authentication becomes the only path to the UI. The optional direct port 8080 keeps Headplane's own login as its gate, gains an nginx `limit_req` on the login/auth paths, and its `ports_description` warns it bypasses HA auth.
- **Internal TLS**: `init-headscale` appends `127.0.0.1 <acme_hostname>` to `/etc/hosts`. Headplane and the tailscale client dial `https://<acme_hostname>:8443` — the real ACME cert validates against the real hostname. `NODE_TLS_REJECT_UNAUTHORIZED` is deleted. The same pin makes in-container clients immune to hairpin-NAT failures. (HTTP/IP mode keeps the existing fallback behavior, minus the hosts pin.)
- **DNS**: MagicDNS `base_domain` default changes from `headscale.local` (mDNS collision) to `tailnet.internal`.

### HA reachability (ts-ha-proxy)

- Clients reach HA at `homeassistant.<base_domain>` — the node's own MagicDNS name — on HA's real port. No subnet route, no accept-routes, no `dns.extra_records`, no LAN-IP or DHCP-reservation dependency: the serve backend targets the internal `homeassistant` hostname on the hassio network, and the port comes from the Supervisor core API each boot (`bashio::core.port`, with `bashio::core.ssl` informing the URL scheme shown in docs/logs).
- HA terminates its own TLS through the TCP forward, so the user's existing certificate setup behaves identically to LAN access.

### Subnet router (ts-subnet-router — optional, default off)

- **Route detection**: the container can no longer see host routes (and `ip route` inside a bridge-mode container would only find the docker bridge). `init-subnet-router` calls the Supervisor network API (`GET http://supervisor/network/info`) and advertises the host's primary interface CIDR. If the API is unavailable (standalone/test mode) the router starts with no advertised routes and a prominent warning — there is **no** `10.0.0.0/8` fallback anywhere.
- **Exit node**: unchanged option, off by default, works under userspace networking.

### ACL policy

Seed policy (first run) — tag-based, so it is fully seedable before any node joins, with no IPs and no broad fallbacks (`<ha_port>` resolved from the Supervisor core API at seed time):

```jsonc
{
  "tagOwners": {
    "tag:homeassistant": [],      // only the addon (via pre-auth key) assigns these
    "tag:subnet-router": []
  },
  "groups": {
    "group:admins": [],
    "group:users": [/* from the users option, as name@ */],
    "group:subnet-access": []
  },
  "acls": [
    { "action": "accept", "src": ["group:admins"],        "dst": ["*:*"] },
    { "action": "accept", "src": ["group:users"],         "dst": ["tag:homeassistant:*"] },
    { "action": "accept", "src": ["group:subnet-access"], "dst": ["<detected routes>:*"] },
    { "action": "accept", "src": ["autogroup:member"],    "dst": ["tag:homeassistant:<ha_port>"] }
  ]
}
```

The subnet-access rule is seeded only when the subnet router is enabled at first run; enabling the router later adds it via the surgical merge (add-only, and only if no `group:subnet-access` rule already exists).

On every subsequent boot, `init-policy` performs **surgical, add-only** updates via the policy API (GET → jq edit → SET), preserving all user customizations made in Headplane:
- `group:users` gains (never loses) entries from the `users` option.
- The subnet-access rule is added if the router was newly enabled and no such rule exists.

Route destinations are never auto-edited once present — routes are the user's policy domain after they've touched the ACL.

### User provisioning

The `users: [alice, bob]` option replaces reading HA's auth store. Each boot, `init-policy` creates any missing headscale users before touching the ACL (idempotent, by name; headscale 0.29 user CLI is ID-based for mutations — lookups via `-o json | jq`). **No pre-auth keys are generated for humans and none are logged**; DOCS directs users to mint keys in Headplane (its intended workflow).

The addon's own nodes (HA proxy, subnet router, Headplane agent) join with **single-use, 1-hour** pre-auth keys minted only when no persisted tailscale state exists — the proxy and router keys created with their respective `--tags` so the ACL's tag rules apply from the moment of join. The key value is never logged and expires on its own. Node identity persists in `/data/tailscale/` and `/data/headplane/agent/` across restarts, so re-keying happens only after a state wipe.

### Credentials policy

| Credential | Handling |
|---|---|
| Headplane API key | Created once, 10-year expiry, `0600` file, **never logged** (log the file path only). Rotation: documented one-liner (expire + recreate + restart addon; init rewrites Headplane config from the file). Excluded from backups (regenerates on restore). |
| Cookie secret | Generated once, excluded from backups (restore = sessions invalidated, harmless). |
| Join keys (proxy/router/agent) | Single-use, 1 h expiry, tagged, generated on demand; not stored long-term. |
| Noise + DERP private keys | Excluded from backups (regenerate; clients re-pin on next connect). |
| Headscale DB | **In** backups by necessity (it *is* the tailnet state) — hence the DOCS sensitivity note. |

The e2e suite greps addon logs for the API key value as a regression test.

### Headplane 0.7.0 specifics

- Node.js ≥ 24.2 required. Primary plan: `apk add nodejs-current` (or `nodejs` where the base Alpine ships ≥24.2). Fallback if apk can't satisfy it: copy the runtime from a `node:24-alpine` `FROM` stage plus `apk add libstdc++` (same musl ABI). Verified at implementation time.
- Config migration: API key moves to `headscale.api_key` (config regenerated every boot from template, so no user migration); regenerate the full config against 0.7.0's `config.example.yaml` — several options were consolidated.
- **`server.proxy_auth` investigation**: configure Headplane to trust identity headers (`X-Remote-User-Name`, sent by Supervisor ingress) from 172.30.32.2 only — giving automatic login behind HA ingress and removing the paste-an-API-key step. Implemented behind a config template flag; if header behavior doesn't match expectations in e2e, ship with it disabled and keep API-key login. Never trust these headers on the direct-access port.
- Pin stays explicit; Headplane signals breaking changes toward 1.0, so majors are manual (see auto-merge policy).

## Hardening

- **AppArmor** (`apparmor.txt`): custom profile permitting the s6 tree, the four service binaries, their config/data paths, and network access — denying everything else (no raw sockets, no mounts, no /proc write access beyond what s6 needs). Raises the HA security rating; with ingress (+2), no host_network, no privileges, and AppArmor (+1) the addon moves from ~5 to ~7–8.
- **Non-root**: dedicated users `headscale`, `headplane`, `tailscale`, `nginx`; unprivileged internal ports make this possible everywhere. Only `/init` (s6) is root.
- **Supply chain**: every external component arrives via a pinned `FROM` stage (see below) — the curl-download + checksum problem is removed structurally rather than patched. GitHub Actions in workflows are pinned to commit SHAs.
- **Rate limiting**: nginx `limit_req` on the direct-access port's auth paths. (Rate-limiting headscale's own public 443 endpoints would require moving TLS termination into nginx — explicitly out of scope; see Future work.)

## Dockerfile restructure

```dockerfile
ARG BUILD_FROM=ghcr.io/hassio-addons/base:<latest at implementation time>
FROM ghcr.io/juanfont/headscale:v0.29.3 AS headscale
FROM ghcr.io/tale/headplane:0.7.0 AS headplane
FROM tailscale/tailscale:v1.102.2 AS tailscale
FROM ${BUILD_FROM}
# apk: nodejs-current nginx jq yq-go curl openssl
# COPY --from= the headscale binary, headplane app + agent, tailscale/tailscaled binaries
# COPY rootfs /
```

- Base is the HA community base directly (bundles s6-overlay, bashio, tempio) — deletes the hand-rolled s6 download and bashio extraction stages, and makes the base a Dependabot-visible dependency. `build.yaml` drops `build_from` so the Dockerfile `ARG` default is the single source of truth for all arches (the base is a multi-arch manifest).
- Every version-bearing dependency is now a `FROM` line → Dependabot's docker ecosystem tracks all of them, including the ARG-parameterized base.
- Tailscale comes from the official image at an explicit pin (replaces unpinned Alpine edge).
- Binary paths inside the upstream images verified at implementation time.

## CI/CD

### Dependabot (`.github/dependabot.yml`)

- Ecosystems: `docker` (daily, `/headscale` directory) and `github-actions` (weekly).
- Result: headscale / Headplane / Tailscale / HA-base releases — including CVE hotfixes — appear as PRs within a day.

### PR pipeline (`ci.yaml`)

1. **Lint** — HA addon config linter (frenck/action-addon-linter), hadolint, shellcheck on every s6 script, yamllint.
2. **Build** — both arches via the official HA builder action (no push).
3. **Smoke test** — the amd64 image boots standalone via the evolved `docker-compose.test.yml` (Supervisor API mocked; explicit test routes since auto-detect needs the real API). Asserts: headscale `/health` 200, Headplane login page 200 via nginx, seed policy actually present (`headscale policy get`), configured users exist, no API-key value in captured logs.
4. **E2E** — full Supervisor devcontainer job, detailed below.
5. **Trivy scan** — fails on new HIGH/CRITICAL findings with fixes available; results as PR annotation.

### Auto-merge policy

- Repo setting: allow auto-merge. A small workflow enables auto-merge (squash) on Dependabot PRs whose update type is **patch or minor** — with two carve-outs held for manual review: **headscale minor bumps** (strict upgrade path, breaking minors) and **any major**. CVE fixes are overwhelmingly patches, so the security path stays fully automated.
- Auto-merge only completes when the entire PR pipeline (including e2e) is green — that's the safety argument for unattended merges.

### Release pipeline (aligned with the community trigger chain)

Two workflows, mirroring how community addons ship, with the manual step automated away:

1. **`release.yaml` (on push to main)**: guard against reacting to its own commit; if `config.yaml` version is unchanged since the last tag, auto-bump **patch** and prepend a CHANGELOG entry from the merged PR title (Dependabot merges thus become releases; human PRs may pre-bump minor/major and write their own entry); commit, tag, and **publish a GitHub release**.
2. **`deploy.yaml` (on `release: published`)**: build + push multi-arch images to GHCR (`ghcr.io/josh/{arch}-addon-headscale:<version>`) via the HA builder — the same trigger community addons use, so this half is drop-in compatible with their tooling.
3. Users' HA instances see the update (version change + `image:` key = fast prebuilt pull of the exact bits CI tested).

End-to-end flow: **upstream CVE fix → Dependabot PR (≤1 day) → full CI incl. e2e → auto-merge → auto-bump + GHCR publish → update visible in HA UI.**

Repo settings required (documented in CONTRIBUTING/README): enable auto-merge; branch protection on main requiring the CI checks, with a bypass for the release credential; a fine-grained PAT or GitHub App token (contents: write) as a secret for the bump commit; workflow `packages: write` permission for GHCR.

### Scheduled jobs

- **Weekly refresh rebuild**: `--no-cache` rebuild; if installed apk package versions differ from the latest release image (nginx/Node/openssl fixes arriving via Alpine without a `FROM` change), auto-bump patch and release. Closes the gap Dependabot can't see.
- **Weekly Trivy scan** of the latest published image; opens/updates an issue when new CVEs land against it.

## E2E testing

### Supervisor devcontainer e2e (the community-standard environment)

Environment (verified against public 2026 workflows — FaserF/hassio-addons and lildude/ha-addon-teslamate are working references):

- `docker run -d --privileged` of `ghcr.io/home-assistant/devcontainer:5-apps` on `ubuntu-latest`, addon tree mounted at `/mnt/supervisor/addons/local`, env `SUPERVISOR_MACHINE=generic-x86-64`, a volume on `/var/lib/docker`, then `supervisor_run`; poll `ha supervisor info` (300 s budget). Apply the known CI accommodations: `ha jobs options --ignore-conditions healthy`, ignore the `docker_gateway_unprotected` resolution check, free runner disk first.
- Note the 2026 rename: CLI is `ha apps …`; the `image:` key is stripped from the mounted config.yaml so Supervisor builds the PR's tree locally as `local_headscale`.

Scenarios and assertions:

1. **Install/configure/start** via `ha apps` / Supervisor REST with test options (HTTP/IP mode — no public domain in CI; `users: [e2etest]`; `subnet_router.enabled: true` so the optional path is exercised too).
2. **Ingress works and is exclusive**: create an ingress session (`POST /api/hassio/ingress/session`), fetch the Headplane UI through `/api/hassio_ingress/<token>/` — 200. If `proxy_auth` is enabled: assert auto-login (no API-key form). From a second container on the Supervisor network, hit the addon's ingress port directly — assert refused. *(The lateral-movement regression test.)*
3. **Real client join + ACL enforcement**: a `tailscale/tailscale` container joins via `tailscale up --login-server` with a key minted for `e2etest`; assert it reaches HA through the serve proxy at `homeassistant.<base_domain>:<discovered port>` (this doubles as the serve-vs-headscale verification), **cannot** reach any LAN-route destination (not in `group:subnet-access`), and after adding it to `group:subnet-access` via the policy API, traffic flows through the subnet route to a target container.
4. **Credential hygiene**: grep full addon logs for the API-key value — must be absent; assert key file exists with mode 0600.
5. **Lifecycle**: restart → same node identities, no re-provisioning, policy user-edits intact (make a surgical-safe edit first, restart, assert preserved). Backup → uninstall → restore → addon healthy; excluded files regenerated fresh.
6. **AppArmor**: attempt profile load; if the runner environment can't load it (a known issue — one reference workflow stubs `apparmor_parser`), stub it and mark the step advisory. Real enforcement gets verified manually on the HA VM before release (and by the HAOS-in-QEMU sketch in Future work, if ever picked up).

Budget: ~15–25 min on a standard runner. Runs per-PR (it gates auto-merge); if runtime creeps, fallback posture is per-PR for Dependabot + label-triggered for humans, nightly otherwise.

### CI limitations (stated in DOCS/spec)

ACME issuance needs a public domain — all CI runs in HTTP/IP mode; TLS config generation is covered by the smoke test, real issuance only by manual testing. (Future refinement: Pebble ACME test server + DNS override.) DERP relay behavior across real NATs is manual-only.

## Migration (existing 0.6.0 installs)

- Headscale 0.28 → 0.29.3 migrates its DB on first start (one-minor jump — supported).
- Headplane config is regenerated every boot from the addon template → 0.7.0 format applied automatically; API key file carries over.
- The old TUN "homeassistant" node and the old subnet-router node are removed from headscale and their state dirs (`/data/tailscale/ha/`, `/data/tailscale/subnet/`) deleted; the new tagged userspace nodes join fresh. Clients that targeted the old tailnet IP move to `homeassistant.<base_domain>` — CHANGELOG calls this out as a breaking change.
- `subnet_router.enabled` default flips to **false**; upgraders who relied on the default-on router must re-enable it (CHANGELOG breaking-change note).
- Existing ACLs are **not** auto-rewritten (edits can't be reliably distinguished from the old seed): the addon logs a prominent one-time notice with the exact tag-based rules to add (`hosts.ha`-based rules point at the removed node and are dead but harmless).
- Stored per-HA-user pre-auth keys under `/data/headplane/user_keys/` and `ha_users.txt` are deleted; existing already-joined devices are untouched (their node keys live in the DB).
- Removed config keys are dropped from the schema; Supervisor tolerates removed options.

## Documentation updates (DOCS.md)

New/updated sections: security model & residual risk (control-plane compromise, backups sensitivity); the `users` option and Headplane-based key workflow; HA access via `homeassistant.<base_domain>` on HA's actual port/scheme (breaking change note for upgraders); subnet router as opt-in LAN exposure; direct-port warning; API-key rotation procedure; ACL groups & tags explainer (admins / users / subnet-access, tag:homeassistant / tag:subnet-router); CI/release badges.

## Out of scope / future work

1. **HAOS-in-QEMU e2e** — not planned; reference sketch (feasibility verified): standard GitHub runners expose `/dev/kvm`; HA's own OS repo boots the release qcow2 in CI via `qemu-system-x86_64 -accel kvm` with OVMF UEFI firmware and user-mode networking with `hostfwd` port forwards. Onboarding is browserless (`POST /api/onboarding/users` → auth code → `POST /auth/token`). Unique coverage it would add over the devcontainer job: real AppArmor enforcement, the released→candidate **update/migration path** (install the published addon from the repo URL, update to the candidate, assert data migration), the true frontend ingress chain, and emulated aarch64. Cadence would be nightly/release, not per-PR.
2. Rate limiting headscale's public endpoints (requires nginx TLS termination in front of headscale).
3. Pebble-based ACME e2e.
4. Image signing (cosign / HA codenotary).
5. Optional `subnet_router.routes` override option, if users ask for it.
6. Tailnet-Lock-equivalent — blocked on upstream headscale support.

## Testing strategy summary

| Layer | What | When |
|---|---|---|
| Lint | addon config, Dockerfile, shell, yaml | every PR |
| Build | both arches, HA builder | every PR |
| Smoke | standalone container, service health, policy applied, no secrets in logs | every PR |
| E2E | real Supervisor (devcontainer): ingress exclusivity, client join + ACL, lifecycle, backup/restore | every PR (gates auto-merge) |
| Trivy | image CVE scan | every PR + weekly |
| Refresh rebuild | base-layer CVE pickup | weekly |
| Manual | AppArmor enforcement on the real HA VM, ACME issuance, DERP across NAT | before notable releases |
