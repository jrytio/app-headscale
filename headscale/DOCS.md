# Headscale

Self-hosted Tailscale control server with Headplane web UI and optional subnet router.

## Prerequisites

Before installing this addon, you need:

1. **A domain name** pointing to your Home Assistant instance's public IP address (e.g., `vpn.example.com`)
2. **Port forwarding** configured on your router:
   - `443/tcp` — Headscale HTTPS server (client connections)
   - `80/tcp` — Let's Encrypt ACME certificate challenge
   - `3478/udp` — STUN relay for NAT traversal
3. **An email address** for Let's Encrypt certificate registration

## Quick Start

1. Install the addon from the Home Assistant addon store
2. Open the **Configuration** tab and set:
   - `server_url`: Your public domain (e.g., `https://vpn.example.com`)
   - `acme_email`: Your email for Let's Encrypt
3. Click **Start**
4. Open **Headscale** from the Home Assistant sidebar
5. Create your first user and generate a pre-auth key

## Connecting Clients

After creating a user and pre-auth key in the Headplane UI, use the key to connect devices.

### Linux / macOS

```bash
tailscale up --login-server https://vpn.example.com --authkey YOUR_AUTH_KEY
```

### Windows

1. Open the Tailscale GUI
2. Right-click the Tailscale icon in the system tray
3. Hold **Ctrl** and click **Log out** (if already connected to Tailscale)
4. Open a terminal (PowerShell or CMD) and run:

```powershell
tailscale up --login-server https://vpn.example.com --authkey YOUR_AUTH_KEY
```

### iOS

1. Install the Tailscale app from the App Store
2. Open the app, tap the menu (three dots)
3. Tap **Use an alternate server** (you may need to tap multiple times on the version number to enable this)
4. Enter your server URL: `https://vpn.example.com`
5. Follow the prompts and enter your auth key when asked

### Android

1. Install the Tailscale app from Google Play
2. Open the app, tap the menu (three dots)
3. Tap **Use an alternate server**
4. Enter your server URL: `https://vpn.example.com`
5. Follow the prompts and enter your auth key when asked

## Subnet Router

The built-in subnet router lets you access your home network from anywhere through your Tailscale VPN.

### How It Works

When enabled, the addon runs a Tailscale client that advertises your local network routes to all connected devices. This means any device connected to your Headscale VPN can reach devices on your home network (printers, NAS, cameras, etc.) as if they were local.

### Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `subnet_router.enabled` | `true` | Enable or disable the subnet router |
| `subnet_router.routes` | `[]` (auto-detect) | List of CIDR routes to advertise. Empty = auto-detect your LAN |
| `subnet_router.exit_node` | `false` | Advertise as an exit node (routes ALL traffic through your home network) |

### Auto-Detection

When `routes` is empty (the default), the addon automatically detects your Home Assistant host's local network subnet (e.g., `192.168.1.0/24`) and advertises it.

### Custom Routes

To advertise specific routes, add them to the configuration:

```yaml
subnet_router:
  enabled: true
  routes:
    - "192.168.1.0/24"
    - "10.0.0.0/24"
  exit_node: false
```

### Exit Node

Setting `exit_node: true` advertises this addon as an exit node, meaning connected clients can route ALL their internet traffic through your home network. This is useful for accessing geo-restricted content or securing traffic on public WiFi.

### Verifying Routes

After connecting a client, verify the subnet router is working:

```bash
tailscale status
```

You should see `ha-subnet-router` listed with the advertised routes. Try pinging a device on your home network from a remote client.

## Managing Your Network

The Headplane web UI (accessible from the Home Assistant sidebar) provides full management of your Headscale network:

- **Users**: Create and manage user accounts. Each person or role should have their own user.
- **Pre-Auth Keys**: Generate authentication keys for connecting new devices. Keys can be single-use or reusable, with configurable expiration.
- **Devices**: View all connected devices, their IP addresses, online status, and last seen time. Rename or remove devices as needed.
- **ACL Policies**: Configure access control rules to restrict which devices can communicate with each other. The default policy allows all devices to communicate freely.
- **Routes**: View and manage advertised routes from subnet routers and exit nodes.
- **DNS**: Configure DNS settings for your Tailscale network.

## Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `server_url` | URL | (required) | Public URL for your Headscale server (e.g., `https://vpn.example.com`) |
| `acme_email` | Email | (required) | Email for Let's Encrypt certificate registration |
| `log_level` | Select | `info` | Log verbosity: `trace`, `debug`, `info`, `warning`, `error` |
| `subnet_router.enabled` | Boolean | `true` | Enable the built-in subnet router |
| `subnet_router.routes` | List | `[]` | CIDR routes to advertise (empty = auto-detect LAN) |
| `subnet_router.exit_node` | Boolean | `false` | Advertise as an exit node |

## Network Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 443 | TCP | Headscale HTTPS server — client connections and API |
| 80 | TCP | ACME HTTP-01 challenge for Let's Encrypt |
| 3478 | UDP | STUN relay for NAT traversal |
| 8080 | TCP | Headplane web UI direct access (optional, not needed for Ingress) |

## Troubleshooting

### Certificate Issues

**"ACME challenge failed"**
- Ensure port 80 is forwarded to your HA instance
- Verify your domain resolves to your public IP: `nslookup vpn.example.com`
- Wait a few minutes for DNS propagation if you just created the record

**"TLS handshake error"**
- The certificate may still be provisioning. Check the addon logs and wait up to 2 minutes.

### Clients Can't Connect

**"connection refused" or timeout**
- Verify port 443 is forwarded to your HA instance
- Check that `server_url` in the addon config matches your domain exactly
- Ensure you're using `--login-server` flag with the full URL including `https://`

**"invalid auth key"**
- Keys expire. Generate a new pre-auth key in the Headplane UI.
- Ensure you're copying the full key (they can be long)

### Subnet Router Not Working

**Routes not visible to clients**
- Routes need to be approved in the Headplane UI under the device's route settings
- Check that the subnet router shows as online in `tailscale status`
- Verify `NET_ADMIN` and `NET_RAW` capabilities are enabled (they are by default in the addon config)

**Can't reach home network devices**
- Ensure the auto-detected or configured routes match your actual LAN subnet
- Check that the target device allows connections from the Tailscale IP range (100.64.0.0/10)

### Checking Logs

View addon logs from the Home Assistant UI:
1. Go to **Settings** -> **Add-ons** -> **Headscale**
2. Click the **Log** tab
3. Set `log_level` to `debug` in the addon configuration for more detailed output
