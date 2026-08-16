# Changelog

## 0.7.0

Security-focused re-architecture. **Breaking changes — read before upgrading:**

- The addon no longer uses host networking or any privileged capabilities.
  An attacker compromising the (internet-facing) headscale service no longer
  lands in your host network.
- Home Assistant is now reached at `homeassistant.tailnet.internal` on your
  HA port (via a built-in tailnet proxy node) instead of the old node's
  tailnet IP. Update bookmarks/apps accordingly.
- The subnet router is now **disabled by default** (LAN access is opt-in).
  Re-enable it in the addon options if you used it.
- The `users` addon option replaces automatic Home Assistant user import;
  the addon no longer reads your HA configuration directory.
- Existing custom ACL policies are kept untouched; the addon logs the
  tag-based rules you should add. Fresh installs get a least-privilege
  policy automatically.
- Headscale 0.28.0 → 0.29.3 (database migrates automatically; clients need
  Tailscale ≥ 1.80). Headplane 0.6.2-beta.5 → 0.7.0 (fixes CVE-2026-46484).
- Web UI: log in via Home Assistant ingress — sessions now come from your
  HA login (proxy auth). The API key is no longer printed to the log.

## 0.1.4

- Fix: trailing newlines in s6 container environment files broke tailscale routes

## 0.1.3

- Fix: make subnet router init non-fatal (don't crash addon if pre-auth key fails)

## 0.1.2

- Fix: install nodejs via apk (HA builder overrides base image, removing node)

## 0.1.1

- Fix: use full path for node binary (s6-overlay PATH issue)
- Fix: headplane v0.6.x YAML config format (was using deprecated env vars)
- Fix: headscale preauthkey creation (plain text output, not JSON)
- Add root-to-/admin/ redirect in nginx

## 0.1.0

- Initial release
