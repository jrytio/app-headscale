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

exit $FAIL
