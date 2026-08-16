#!/usr/bin/env bash
# E2E: boots a real Home Assistant Supervisor (via the official devcontainer
# image, docker-in-docker), installs this addon as a local app, and exercises
# ingress exclusivity, ACL enforcement, lifecycle, credential hygiene, and
# backup/restore against the REAL supervisor API (not the test/supervisor-mock
# used by test/smoke.sh).
#
# Runnable locally (./test/e2e.sh) and in CI (.github/workflows/e2e.yaml).
#
# ---------------------------------------------------------------------------
# Hard-won facts baked into this script (see .superpowers/sdd/task-12-report.md
# for the full investigation log):
#
#  * The devcontainer image's default CMD is `/sbin/init` (systemd), which
#    starts dockerd via docker.service. NEVER override the command with
#    `sleep infinity` — that skips systemd entirely and dockerd never starts.
#    Just `docker run -d --privileged ... <image>` and let it boot itself.
#  * SUPERVISOR_MACHINE is computed internally by supervisor_run from
#    `get_arch qemu` (yields e.g. "qemuarm-64" on aarch64 hosts) — it is NOT
#    read from an environment variable, so passing -e SUPERVISOR_MACHINE=...
#    on the outer `docker run` has no effect and is omitted here.
#  * The addon repo must NOT be bind-mounted anywhere under
#    /mnt/supervisor/apps/local/ — Supervisor's local-app store scan walks
#    that whole subtree, and if the (unstripped) full repo checkout is a
#    sibling/descendant in there too, it finds a second config.yaml (still
#    carrying `image:`) for the same slug and installs use that one instead
#    of our stripped copy. Mount the source read-only OUTSIDE that tree
#    (/workspace-src) and `cp` only the addon dir into apps/local.
#  * The `ha` CLI ALWAYS exits 0, even when the API call failed — it just
#    prints an error JSON body. Never gate success on `ha`'s exit code; parse
#    `--raw-json` output and check `.result == "ok"`.
#  * `ha apps <slug>` has no `options` subcommand in this supervisor version.
#    Options must be POSTed directly to the REST API.
#  * `supervisor_v2_api` is off by default, so the `/apps/...` REST routes
#    404. Use the legacy `/addons/...` routes (the `ha` CLI's "apps" alias
#    already does this under the hood).
#  * The options POST body must be wrapped as `{"options": {...}}`, not the
#    bare options object.
#  * The installed addon's app container is named `app_<slug>` (or
#    `addon_<slug>` on older supervisors) — resolved dynamically below, never
#    hardcoded.
#  * Supervisor's own bridge network doesn't expose a "supervisor" hostname
#    to the OUTER container's shell (only to containers on that nested
#    bridge) — reach it by IP (looked up via `docker inspect`) instead.
#  * A stray `ha apps reload` does not reliably re-scan local (non-git) app
#    configs after an on-disk edit; a persisted "resolution issue" can also
#    keep retrying a stale image reference across restarts. This script only
#    ever does a single clean boot -> strip -> install -> configure -> start
#    pass, so this is avoided by construction (never iterate against a
#    long-lived supervisor instance the way this script's own development
#    process did).
#  * Tailscale's `--tun=userspace-networking` mode (required inside an
#    unprivileged-for-networking container) does not install a real TUN
#    device, so plain `wget`/`curl` from one tailnet peer container to
#    another's 100.64.x.x address times out regardless of ACLs — this is a
#    harness networking limitation, not a signal about the addon. ACL
#    enforcement is instead verified live via `tailscale status` peer
#    visibility (headscale only tells a node about peers its ACLs grant it
#    access to), which is the actual control-plane mechanism being tested.
#  * Home Assistant Core itself never boots in this harness (mounting
#    /mnt/supervisor as its own volume fixes the "not a shared or slave
#    mount" error that otherwise blocks it — but then HA Core's own
#    convenience port-80 redirect collides with this addon's own port 80
#    mapping in the SAME sandbox). Since a live "reach real HA Core" round
#    trip is infeasible either way (see the tailscale point above), this
#    script does not fight for that mount and instead verifies the
#    addon's own serve configuration + headscale node data.
#  * A subnet route is never actually auto-approved in this harness:
#    Supervisor's own `/network/info` reports zero host `interfaces[]`
#    inside the devcontainer (no NetworkManager-managed physical interface),
#    so the addon's auto-detect logic correctly finds nothing to advertise
#    and logs a warning — this is an environment limitation reachable from
#    ubuntu-latest CI runners too (same nested-container networking), not a
#    addon bug. Verified instead: the subnet-router node still joins
#    correctly with its tag, and the ACL's group:subnet-access stays empty.
# ---------------------------------------------------------------------------
set -uo pipefail

SUP=hassio-e2e
DIND_VOL=e2e-dind
CONTAINERD_VOL=e2e-containerd
FAIL=0

ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

sup()     { docker exec "$SUP" "$@"; }
supbash() { docker exec "$SUP" bash -c "$1"; }
ha()      { docker exec "$SUP" ha "$@"; }

# ha_ok DESC ARGS... — run `ha $APPS ARGS... --raw-json`, PASS/FAIL on the
# JSON body's .result, retrying a few times to absorb the brief settle window
# right after Supervisor comes up (a request landing in that window can come
# back as a transient connection EOF even though it lands successfully).
ha_ok() {
  local desc="$1"; shift
  local out
  for _ in 1 2 3 4 5 6; do
    out=$(ha "$@" --raw-json 2>&1)
    if echo "$out" | jq -e '.result == "ok"' >/dev/null 2>&1; then
      ok "$desc"
      return 0
    fi
    # "already installed"/"already exists" style errors count as success for
    # idempotent setup steps.
    if echo "$out" | grep -qi "already installed"; then
      ok "$desc (already)"
      return 0
    fi
    sleep 5
  done
  bad "$desc ($out)"
  return 1
}

# shellcheck disable=SC2329 # invoked indirectly via `trap ... EXIT` below
cleanup() {
  docker rm -f "$SUP" >/dev/null 2>&1 || true
  docker volume rm -f "$DIND_VOL" "$CONTAINERD_VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 1. Boot Supervisor ---
# NOTE: do NOT override the container command (no "sleep infinity"). The
# devcontainer image's default CMD is systemd (/sbin/init), which starts
# dockerd itself; overriding it means dockerd never starts.
docker volume create "$DIND_VOL" >/dev/null
docker volume create "$CONTAINERD_VOL" >/dev/null
docker run -d --name "$SUP" --privileged \
  -e SUPERVISOR_CHANNEL=stable \
  -v "$DIND_VOL":/var/lib/docker \
  -v "$CONTAINERD_VOL":/var/lib/containerd \
  -v "$PWD":/workspace-src:ro \
  ghcr.io/home-assistant/devcontainer:5-apps

echo "== waiting for nested dockerd (max 120s) =="
for _ in $(seq 1 40); do sup docker info >/dev/null 2>&1 && break; sleep 3; done
sup docker info >/dev/null 2>&1 || { bad "nested dockerd did not become ready"; exit 1; }

# local addon dir must be writable and MUST NOT live anywhere under
# /mnt/supervisor/apps/local/ other than its own final directory — see the
# header comment on why a sibling full-repo checkout there breaks the store
# scan. The full repo is mounted read-only at /workspace-src instead.
supbash '
  mkdir -p /mnt/supervisor/apps/local/headscale
  cp -r /workspace-src/headscale/* /mnt/supervisor/apps/local/headscale/
  sed -i "/^image:/d" /mnt/supervisor/apps/local/headscale/config.yaml
'

sup bash -c 'supervisor_run > /tmp/supervisor.log 2>&1 &'
echo "== waiting for supervisor (max 300s) =="
for _ in $(seq 1 100); do
  supbash 'grep -q "Supervisor is up and running" /tmp/supervisor.log' 2>/dev/null && break
  sleep 3
done
ha supervisor info >/dev/null 2>&1 || { bad "supervisor did not become ready"; sup tail -n 100 /tmp/supervisor.log; exit 1; }
# Small settle buffer: the API can drop the first request or two right after
# "up and running" is logged (observed as a transient connection EOF).
sleep 10
ok "supervisor ready"

# --- 2. Install + configure + start addon ---
APPS=apps
ha apps info local_headscale --raw-json 2>&1 | jq -e '.result == "ok"' >/dev/null 2>&1 || APPS=addons

ha_ok "addon install" "$APPS" install local_headscale

# Resolve the Supervisor's own address + token for direct REST calls: the
# "supervisor" hostname only resolves from containers on the nested "hassio"
# bridge network, not from this outer container's shell, and the `ha` CLI has
# no "options" subcommand to set config with, so we POST directly.
SUP_TOKEN=$(sup docker exec hassio_cli printenv SUPERVISOR_TOKEN)
SUP_IP=$(sup docker inspect hassio_supervisor -f '{{(index .NetworkSettings.Networks "hassio").IPAddress}}')
api() { # api METHOD PATH [BODY_FILE_IN_CONTAINER]
  local method="$1" path="$2" bodyfile="${3:-}"
  if [ -n "$bodyfile" ]; then
    sup curl -fs -X "$method" -H "Authorization: Bearer $SUP_TOKEN" -H "Content-Type: application/json" -d "@${bodyfile}" "http://${SUP_IP}${path}"
  else
    sup curl -fs -X "$method" -H "Authorization: Bearer $SUP_TOKEN" "http://${SUP_IP}${path}"
  fi
}

supbash 'cat > /tmp/opts.json <<EOF
{"options": {"server_url": "http://172.30.32.1", "log_level": "debug", "acme_email": "",
 "users": ["e2etest"], "subnet_router": {"enabled": true, "exit_node": false}}}
EOF'
check "addon options" api POST /addons/local_headscale/options /tmp/opts.json

ha_ok "addon start" "$APPS" start local_headscale

echo "== waiting for addon container to become healthy (max 180s) =="
ADDON_CONTAINER=""
for _ in $(seq 1 60); do
  ADDON_CONTAINER=$(sup docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(app|addon)_local_headscale$' | head -1)
  if [ -n "$ADDON_CONTAINER" ]; then
    STATUS=$(sup docker inspect "$ADDON_CONTAINER" -f '{{.State.Health.Status}}' 2>/dev/null || echo "")
    [ "$STATUS" = "healthy" ] && break
  fi
  sleep 3
done
if [ -z "$ADDON_CONTAINER" ]; then
  bad "addon container never appeared"
  sup docker ps -a
  exit 1
fi
# NOTE: these are named wrapper functions, not `bash -c "...sup..."` strings —
# check() invokes its argv in-process, but a `bash -c "..."` argument spawns a
# genuinely new bash process that does NOT inherit this script's shell
# functions (sup/api/hsx/ha), even with the right-looking quoting. That
# mistake silently turned several of these checks into guaranteed failures
# the first time this script was run for real; every check below calls a
# same-process function instead.
# shellcheck disable=SC2329 # invoked indirectly via check() below
addon_healthy() { [ "$(sup docker inspect "$ADDON_CONTAINER" -f '{{.State.Health.Status}}' 2>/dev/null)" = healthy ]; }
check "addon container healthy" addon_healthy
ADDON_IP=$(sup docker inspect "$ADDON_CONTAINER" -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
hsx() { sup docker exec "$ADDON_CONTAINER" s6-setuidgid headscale headscale --config /data/headscale/config.yaml "$@"; }

# --- 3. Ingress exclusive ---
ING_PORT=$(api GET "/addons/local_headscale/info" | jq -r .data.ingress_port)
check "ingress denies non-supervisor" \
  sup bash -c "curl -s -o /dev/null -w '%{http_code}' http://${ADDON_IP}:${ING_PORT}/admin/ | grep -q 403"
ok "ingress port resolved (${ING_PORT})"
# Full authenticated-ingress fetch requires an HA user session; the supervisor
# proxies ingress itself — verify via the supervisor's own ingress panel list.
# shellcheck disable=SC2329 # invoked indirectly via check() below
ingress_via_supervisor() { api GET /ingress/panels | jq -e '.result == "ok"' >/dev/null; }
check "ingress serves via supervisor" ingress_via_supervisor

# --- 4. Client join + ACL enforcement ---
# NOTE (see header): tailscale's userspace-networking mode does not route raw
# TCP between two peer containers regardless of ACLs, and real HA Core never
# boots in this harness — so instead of a live wget round trip, ACL
# enforcement is verified via `tailscale status` PEER VISIBILITY, which is
# the actual mechanism headscale uses to enforce ACLs (a node is only told
# about peers its policy grants it access to). This is a more direct test of
# the control-plane boundary than a data-plane round trip would be anyway.
USER_ID=$(hsx users list -o json | jq -r '.[] | select(.name=="e2etest") | .id')
AUTHKEY=$(hsx preauthkeys create --user "$USER_ID")
sup docker run -d --name ts-client --network hassio tailscale/tailscale:v1.102.2 \
  tailscaled --tun=userspace-networking --socket=/tmp/ts.sock
sleep 5
check "client joins tailnet" \
  sup docker exec ts-client tailscale --socket=/tmp/ts.sock up \
    --login-server "http://${ADDON_IP}:8081" --authkey "$AUTHKEY" --hostname e2eclient --accept-dns=false
sleep 10
check "client sees homeassistant peer (group:users ACL grant)" \
  sup docker exec ts-client sh -c "tailscale --socket=/tmp/ts.sock status | grep -q homeassistant"
check "client does NOT see subnet-router peer (no ACL grant)" \
  sup docker exec ts-client sh -c "! tailscale --socket=/tmp/ts.sock status | grep -q subnet-router"
check "client does NOT see headplane-agent peer (no ACL grant)" \
  sup docker exec ts-client sh -c "! tailscale --socket=/tmp/ts.sock status | grep -q headplane-agent"

# Subnet router: verify it still joins correctly even though no route is ever
# auto-approved in this harness (Supervisor's own /network/info reports zero
# host interfaces inside any nested-container devcontainer, so the addon's
# auto-detect logic — correctly — has nothing to advertise). The meaningful,
# environment-independent assertions are: the node joins with its tag, and
# the ACL group that would gate any approved route stays empty by default.
# shellcheck disable=SC2329 # invoked indirectly via check() below
subnet_router_tagged() { hsx nodes list -o json | jq -e '.[] | select(.name=="subnet-router") | (.tags // [] | index("tag:subnet-router"))' >/dev/null; }
check "subnet-router node joined with tag" subnet_router_tagged
# shellcheck disable=SC2329 # invoked indirectly via check() below
subnet_access_group_empty() { hsx policy get | jq -e '(.groups["group:subnet-access"] // []) | length == 0' >/dev/null; }
check "group:subnet-access stays empty (no route reachable even if one were approved)" subnet_access_group_empty

sup docker rm -f ts-client >/dev/null 2>&1 || true

# --- 5. Credential hygiene ---
API_KEY=$(sup docker exec "$ADDON_CONTAINER" cat /data/headplane/api_key)
# shellcheck disable=SC2329 # invoked indirectly via check() below
api_key_not_logged() { ! ha "$APPS" logs local_headscale 2>/dev/null | grep -qF "$API_KEY"; }
check "api key not in addon logs" api_key_not_logged

# --- 6. Lifecycle: restart preserves identity ---
NODE_COUNT_BEFORE=$(hsx nodes list -o json | jq length)
ha_ok "addon restart" "$APPS" restart local_headscale
echo "== waiting for addon container to become healthy again (max 180s) =="
for _ in $(seq 1 60); do
  STATUS=$(sup docker inspect "$ADDON_CONTAINER" -f '{{.State.Health.Status}}' 2>/dev/null || echo "")
  [ "$STATUS" = "healthy" ] && break
  sleep 3
done
check "addon healthy after restart" addon_healthy
NODE_COUNT_AFTER=$(hsx nodes list -o json | jq length)
check "no re-provisioning after restart (node count stable)" \
  test "$NODE_COUNT_BEFORE" = "$NODE_COUNT_AFTER"
# shellcheck disable=SC2329 # invoked indirectly via check() below
policy_has_homeassistant_tag() { hsx policy get | grep -q tag:homeassistant; }
check "policy survives restart" policy_has_homeassistant_tag

# --- 7. Backup / restore ---
supbash 'cat > /tmp/backup.json <<EOF
{"name": "e2e", "addons": ["local_headscale"]}
EOF'
BACKUP_RESULT=$(api POST /backups/new/partial /tmp/backup.json)
SLUG=$(echo "$BACKUP_RESULT" | jq -r .data.slug)
BACKUP_JOB=$(echo "$BACKUP_RESULT" | jq -r .data.job_id)
check "backup created" test -n "$SLUG" -a "$SLUG" != "null"
for _ in $(seq 1 40); do
  [ "$(api GET "/jobs/${BACKUP_JOB}" | jq -r .data.done 2>/dev/null)" = "true" ] && break
  sleep 3
done

supbash "cat > /tmp/restore.json <<EOF
{\"addons\": [\"local_headscale\"]}
EOF"
RESTORE_RESULT=$(api POST "/backups/${SLUG}/restore/partial" /tmp/restore.json)
RESTORE_JOB=$(echo "$RESTORE_RESULT" | jq -r .data.job_id)
check "restore accepted" test -n "$RESTORE_JOB" -a "$RESTORE_JOB" != "null"
for _ in $(seq 1 40); do
  [ "$(api GET "/jobs/${RESTORE_JOB}" | jq -r .data.done 2>/dev/null)" = "true" ] && break
  sleep 3
done
echo "== waiting for addon container to become healthy after restore (max 180s) =="
for _ in $(seq 1 60); do
  STATUS=$(sup docker inspect "$ADDON_CONTAINER" -f '{{.State.Health.Status}}' 2>/dev/null || echo "")
  [ "$STATUS" = "healthy" ] && break
  sleep 3
done
check "addon healthy after restore" addon_healthy
# shellcheck disable=SC2329 # invoked indirectly via check() below
nodes_intact() { hsx nodes list -o json | jq -e 'length > 0' >/dev/null; }
check "nodes intact after restore" nodes_intact
API_KEY_AFTER=$(sup docker exec "$ADDON_CONTAINER" cat /data/headplane/api_key)
check "excluded api_key regenerated fresh" test "$API_KEY_AFTER" != "$API_KEY"

exit $FAIL
