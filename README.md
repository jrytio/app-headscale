# Home Assistant Addon: Headscale

Self-hosted Tailscale control server with the Headplane web UI, a built-in tailnet proxy for reaching Home Assistant, and an optional subnet router.

## Security First

This addon runs with **no** host networking and **no** privileged capabilities. Every service runs as a separate non-root user under a custom AppArmor profile. A compromise of the exposed headscale service is contained to the container, not your home network. Backups contain your tailnet state and should be treated as sensitive.

## Installation

1. In Home Assistant, go to **Settings** → **Add-ons** → **Add-on Store** → **⋮** (menu) → **Repositories**
2. Add this repository: `https://github.com/josh/app-headscale`
3. Go to **Headscale** and click **Install**

## Documentation

See [headscale/DOCS.md](headscale/DOCS.md) for full setup instructions, configuration options, and troubleshooting.
