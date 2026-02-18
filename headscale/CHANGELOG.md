# Changelog

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
