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
