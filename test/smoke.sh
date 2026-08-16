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

assert "config: listen_addr is 0.0.0.0:8081 (HTTP mode)" \
  bash -c "docker exec $C yq e '.listen_addr' /data/headscale/config.yaml | grep -q '0.0.0.0:8081'"
assert "config: base_domain is tailnet.internal" \
  bash -c "docker exec $C yq e '.dns.base_domain' /data/headscale/config.yaml | grep -q 'tailnet.internal'"
assert "headscale runs as non-root" \
  bash -c "docker exec $C ps -o user,comm | grep headscale | grep -qv root"
assert "no NODE_TLS_REJECT_UNAUTHORIZED in container env" \
  bash -c "! docker exec $C test -e /var/run/s6/container_environment/NODE_TLS_REJECT_UNAUTHORIZED"

assert "policy: seeded with tag:homeassistant rule" \
  bash -c "docker exec $C s6-setuidgid headscale headscale policy get --config /data/headscale/config.yaml | grep -q 'tag:homeassistant'"
assert "policy: no allow-all member rule" \
  bash -c "! docker exec $C s6-setuidgid headscale headscale policy get --config /data/headscale/config.yaml | jq -e '.acls[] | select(.src==[\"autogroup:member\"] and .dst==[\"*:*\"])'"
assert "users: e2etest + addon + headplane-agent exist" \
  bash -c "names=\$(docker exec $C s6-setuidgid headscale headscale users list -o json --config /data/headscale/config.yaml | jq -r '.[].name'); echo \"\$names\" | grep -qx 'e2etest' && echo \"\$names\" | grep -qx 'addon' && echo \"\$names\" | grep -qx 'headplane-agent'"
assert "policy: group:users contains e2etest@" \
  bash -c "docker exec $C s6-setuidgid headscale headscale policy get --config /data/headscale/config.yaml | jq -e '.groups[\"group:users\"] | index(\"e2etest@\")'"

assert "headplane login page responds" \
  bash -c "docker exec $C curl -fs -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/admin/login | grep -q 200"
# Node 24's main thread is named "MainThread" (not "node") in comm/ps output
# (libuv thread naming), so match on the unique server entrypoint in args
# instead of the comm column.
assert "headplane runs as non-root" \
  bash -c "docker exec $C ps -o user,args | grep 'headplane/build/server/index.js' | grep -qv '^root'"
assert "api key file exists with 0600" \
  bash -c "docker exec $C stat -c %a /data/headplane/api_key | grep -q 600"
assert "api key value never appears in logs" \
  bash -c "! docker logs $C 2>&1 | grep -qF \"\$(docker exec $C cat /data/headplane/api_key)\""

assert "ha-proxy node joined with tag:homeassistant" \
  bash -c "docker exec $C s6-setuidgid headscale headscale nodes list -o json --config /data/headscale/config.yaml | jq -e '.[] | select(.name==\"homeassistant\") | .validTags==null or (.tags // [] | index(\"tag:homeassistant\")) or (.forcedTags // [] | index(\"tag:homeassistant\"))'"
assert "serve forwards HA_PORT" \
  bash -c "docker exec $C tailscale --socket /var/run/tailscale/ha-proxy.sock serve status | grep -q 8123"

exit $FAIL
