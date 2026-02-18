#!/bin/bash
set -e

# ==============================================================================
# Standalone test entrypoint for the Headscale HA addon.
# Replaces s6-overlay + bashio for local testing without the HA Supervisor.
# ==============================================================================

OPTIONS_FILE="/data/options.json"
CONFIG="/data/headscale/config.yaml"
DEFAULT_CONFIG="/etc/headscale/config.yaml"
COOKIE_SECRET_FILE="/data/headplane/cookie_secret"

echo "=== Headscale Addon Test Startup ==="

# --- Read options ---
server_url=$(jq -r '.server_url' "${OPTIONS_FILE}")
acme_email=$(jq -r '.acme_email' "${OPTIONS_FILE}")
log_level=$(jq -r '.log_level' "${OPTIONS_FILE}")
subnet_enabled=$(jq -r '.subnet_router.enabled' "${OPTIONS_FILE}")

echo "Server URL: ${server_url}"
echo "ACME Email: ${acme_email}"
echo "Log Level: ${log_level}"
echo "Subnet Router: ${subnet_enabled}"

# --- Configure Headscale ---
echo "--- Configuring Headscale ---"
if [ ! -f "${CONFIG}" ]; then
    echo "First run: creating default configuration..."
    mkdir -p /data/headscale/cache
    cp "${DEFAULT_CONFIG}" "${CONFIG}"
fi

# Patch config
server_url="${server_url}" yq e --inplace '.server_url = env(server_url)' "${CONFIG}"

acme_hostname=$(echo "${server_url}" | sed 's|https://||' | sed 's|http://||' | sed 's|/.*||' | sed 's|:.*||')
acme_hostname="${acme_hostname}" yq e --inplace '.tls_letsencrypt_hostname = env(acme_hostname)' "${CONFIG}"
acme_email="${acme_email}" yq e --inplace '.acme_email = env(acme_email)' "${CONFIG}"
log_level="${log_level}" yq e --inplace '.log.level = env(log_level)' "${CONFIG}"

yq e --inplace '.listen_addr = "0.0.0.0:443"' "${CONFIG}"
yq e --inplace '.metrics_listen_addr = "127.0.0.1:9090"' "${CONFIG}"
yq e --inplace '.database.type = "sqlite"' "${CONFIG}"
yq e --inplace '.database.sqlite.path = "/data/headscale/db.sqlite"' "${CONFIG}"
yq e --inplace '.noise.private_key_path = "/data/headscale/noise_private.key"' "${CONFIG}"
yq e --inplace '.policy.mode = "database"' "${CONFIG}"

echo "Headscale config written. Starting headscale..."

# --- Start Headscale ---
headscale serve --config "${CONFIG}" &
HEADSCALE_PID=$!

# Wait for headscale to be ready
echo "Waiting for Headscale to be ready..."
for i in $(seq 1 60); do
    if curl -sk https://127.0.0.1:443/health 2>/dev/null || curl -sk http://127.0.0.1:443 2>/dev/null; then
        echo "Headscale is ready!"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "WARNING: Headscale may not be fully ready yet (ACME will fail for localhost)."
        echo "This is expected in local testing — headscale is still running."
    fi
    sleep 2
done

# --- Configure Headplane ---
echo "--- Configuring Headplane ---"
mkdir -p /data/headplane/data /etc/headplane

# Generate cookie secret (must be exactly 32 characters)
if [ ! -f "${COOKIE_SECRET_FILE}" ]; then
    openssl rand -base64 24 > "${COOKIE_SECRET_FILE}"
    echo "Cookie secret generated."
fi
cookie_secret=$(cat "${COOKIE_SECRET_FILE}")

# Write Headplane YAML config file (v0.6.x format)
HEADPLANE_CONFIG="/etc/headplane/config.yaml"
cat > "${HEADPLANE_CONFIG}" <<HPEOF
server:
  host: "0.0.0.0"
  port: 3000
  cookie_secret: "${cookie_secret}"
  cookie_secure: false
  cookie_max_age: 86400
  data_path: "/data/headplane/data"

headscale:
  url: "https://127.0.0.1:443"
  public_url: "${server_url}"
  config_path: "${CONFIG}"
  config_strict: false

integration:
  proc:
    enabled: true
HPEOF

echo "Headplane config written to ${HEADPLANE_CONFIG}"

# --- Start Headplane ---
echo "--- Starting Headplane ---"
export NODE_TLS_REJECT_UNAUTHORIZED=0

cd /opt/headplane
node build/server/index.js &
HEADPLANE_PID=$!

# Wait for headplane
echo "Waiting for Headplane to be ready..."
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:3000/healthz 2>/dev/null; then
        echo "Headplane is ready at http://localhost:3000"
        break
    fi
    sleep 2
done

# --- Start Nginx (simple reverse proxy for port 8080 → 3000) ---
echo "--- Starting Nginx ---"
mkdir -p /etc/nginx/servers

cat > /etc/nginx/servers/upstream.conf <<'NGINX'
upstream headplane {
    server 127.0.0.1:3000;
}
NGINX

cat > /etc/nginx/servers/direct.conf <<'NGINX'
server {
    listen 8080;

    location = / {
        return 302 /admin/;
    }

    location / {
        proxy_pass http://headplane;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX

nginx -c /etc/nginx/nginx.conf &
NGINX_PID=$!

echo ""
echo "=== All services started ==="
echo "  Headscale: https://localhost:443 (ACME will fail for localhost, this is OK)"
echo "  Headplane: http://localhost:8080 (via nginx)"
echo "  Headplane: http://localhost:3000 (direct)"
echo ""
echo "Press Ctrl+C to stop all services."

# Handle shutdown
cleanup() {
    echo "Shutting down..."
    kill $NGINX_PID $HEADPLANE_PID $HEADSCALE_PID 2>/dev/null
    wait
}
trap cleanup EXIT INT TERM

# Wait for any process to exit
wait -n $HEADSCALE_PID $HEADPLANE_PID $NGINX_PID
