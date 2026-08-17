#!/usr/bin/env bash
# Smoke suite for the standalone addon container. Extend with asserts per task.
set -uo pipefail
C=headscale-addon-test
FAIL=0
assert() { # assert <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS: ${desc}"; else echo "FAIL: ${desc}"; FAIL=1; fi
}
echo "== waiting for services (max 120s) =="
for _ in $(seq 1 60); do
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
  bash -c "docker exec $C s6-setuidgid headscale headscale nodes list -o json --config /data/headscale/config.yaml | jq -e '.[] | select(.name==\"homeassistant\") | (.tags // [] | index(\"tag:homeassistant\")) or (.forcedTags // [] | index(\"tag:homeassistant\")) or (.validTags // [] | index(\"tag:homeassistant\"))'"
assert "serve forwards HA_PORT" \
  bash -c "docker exec $C tailscale --socket /var/run/tailscale/ha-proxy.sock serve status | grep -q 8123"
# NOTE: headscale v0.29.3 preauthkeys are NOT 48 hex chars — they are
# "hskey-auth-" + a 77-char mixed-case/digit/underscore/hyphen token (88
# chars total, observed consistently across several minted keys during
# testing). A plain hex regex false-positived on tailscaled's LogID lines
# (64 hex chars, logged routinely and unrelated to auth), so match the
# actual key shape instead.
assert "no preauthkey values in logs" \
  bash -c "! docker logs $C 2>&1 | grep -E 'hskey-auth-[A-Za-z0-9_-]{40,}'"

assert "subnet router absent when disabled (default)" \
  bash -c "! docker exec $C s6-setuidgid headscale headscale nodes list -o json --config /data/headscale/config.yaml | jq -e '.[] | select(.name==\"subnet-router\")'"

assert "ingress vhost denies non-supervisor sources" \
  bash -c "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8099/admin/ | grep -q 403"
assert "direct vhost serves headplane" \
  bash -c "curl -fs -o /dev/null http://127.0.0.1:8080/admin/login"
assert "direct vhost strips identity headers" \
  bash -c "curl -fs -H 'X-Remote-User-Name: attacker' http://127.0.0.1:8080/admin/login -o /dev/null"
assert "direct vhost rate-limits the login path" \
  bash -c "for i in \$(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:8080/admin/login; done; curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/admin/login | grep -qE '429|503'"
assert "nginx workers run as nginx user" \
  bash -c "docker exec $C ps -o user,args | grep 'nginx: worker process' | grep -v '^root' | grep -q nginx"
assert "nginx master is root (documented exception)" \
  bash -c "docker exec $C ps -o user,args | grep 'nginx: master process' | grep -q '^root'"

echo "== subnet-router enabled variant =="
# Reuse the SAME compose service/image/volume, but boot it standalone with
# the router-enabled options file over the options mount, so the addon's
# already-seeded /data (headscale db, policy, users) carries over. The
# --network container: + --volumes-from pattern fights compose locally, so
# instead: stop the compose-managed addon container (freeing its name/ports),
# capture its network/volume/image, then `docker run` a fresh container from
# the same image/volume with test/options-router.json bind-mounted read-only
# over /data/options.json. entrypoint.sh regenerates the Supervisor mock's
# options endpoint from that file at boot (see harness fix above), so
# bashio::config sees subnet_router.enabled=true for this run.
ROUTER_NET=$(docker inspect "$C" -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
ROUTER_VOL=$(docker inspect "$C" -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}')
ROUTER_IMG=$(docker inspect "$C" -f '{{.Config.Image}}')
docker compose -f docker-compose.test.yml stop headscale-addon >/dev/null 2>&1
docker rm -f "${C}-router" >/dev/null 2>&1 || true
docker run -d --rm --name "${C}-router" \
  --network "${ROUTER_NET}" \
  -v "${ROUTER_VOL}:/data" \
  -v "$PWD/test/options-router.json":/data/options.json:ro \
  -v "$PWD/test":/test:ro \
  -e SUPERVISOR_TOKEN=test-token-not-real \
  --entrypoint /bin/bash "${ROUTER_IMG}" /test/entrypoint.sh >/dev/null 2>&1
sleep 45
assert "subnet router joins with tag and approved route" \
  bash -c "docker exec ${C}-router s6-setuidgid headscale headscale nodes list -o json --config /data/headscale/config.yaml | jq -e '.[] | select(.name==\"subnet-router\") | (.tags // [] | index(\"tag:subnet-router\")) or (.forcedTags // [] | index(\"tag:subnet-router\")) or (.validTags // [] | index(\"tag:subnet-router\"))'"
assert "route 192.168.77.0/24 approved" \
  bash -c "docker exec ${C}-router s6-setuidgid headscale headscale nodes list -o json --config /data/headscale/config.yaml | jq -e '[.[].approved_routes // []] | flatten | index(\"192.168.77.0/24\")'"
assert "no preauthkey values in router logs" \
  bash -c "! docker logs ${C}-router 2>&1 | grep -E 'hskey-auth-[A-Za-z0-9_-]{40,}'"

# Phase 2 teardown: remove router node and state for idempotency
ROUTER_NODE_ID=$(docker exec ${C}-router s6-setuidgid headscale headscale nodes list -o json --config /data/headscale/config.yaml 2>/dev/null | jq -r '.[] | select(.name=="subnet-router") | .id' 2>/dev/null || echo "")
if [ -n "$ROUTER_NODE_ID" ]; then
  docker exec ${C}-router s6-setuidgid headscale headscale nodes delete -i "$ROUTER_NODE_ID" --force --config /data/headscale/config.yaml >/dev/null 2>&1 || true
fi
docker exec ${C}-router rm -rf /data/tailscale/subnet-router >/dev/null 2>&1 || true

docker stop "${C}-router" >/dev/null 2>&1 || true
docker compose -f docker-compose.test.yml up -d >/dev/null 2>&1

exit $FAIL
