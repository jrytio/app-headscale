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

exit $FAIL
