# Home Assistant Addon: Headscale

Self-hosted Tailscale control server with the Headplane web UI, a built-in tailnet proxy for reaching Home Assistant, and an optional subnet router.

## Security First

This addon runs with **no** host networking and **no** privileged capabilities. Every service runs as a separate non-root user under a custom AppArmor profile. A compromise of the exposed headscale service is contained to the container, not your home network. Backups contain your tailnet state and should be treated as sensitive.

## Installation

1. In Home Assistant, go to **Settings** → **Add-ons** → **Add-on Store** → **⋮** (menu) → **Repositories**
2. Add this repository: `https://github.com/jrytio/app-headscale`
3. Go to **Headscale** and click **Install**

## Documentation

See [headscale/DOCS.md](headscale/DOCS.md) for full setup instructions, configuration options, and troubleshooting.

## Repository settings (maintainer checklist)

These are one-time, manual GitHub repository settings the automation in
`.github/workflows/` depends on. They are not stored in this repo, so a fresh
fork or a new maintainer needs to configure them by hand:

- **Enable auto-merge** — Settings → General → Pull Requests → check "Allow
  auto-merge". Required for `auto-merge.yaml` to be able to call
  `gh pr merge --auto`.
- **Create a fine-grained PAT with `contents: write` and save it as the
  `RELEASE_TOKEN` secret** (Settings → Secrets and variables → Actions).
  `release.yaml`, `scheduled.yaml`, and `auto-merge.yaml` all push commits or
  merge PRs with this token instead of the default `GITHUB_TOKEN` — GitHub
  does not trigger downstream workflow runs (e.g. `release.yaml` firing off a
  push to `main`) for events authored by `GITHUB_TOKEN`, so a PAT-backed
  token is required for the release chain to actually fire.
- **Branch protection on `main`** — require these status checks before
  merging:
  - the CI lint/build jobs in `ci.yaml` (`Gather app information`,
    `Lint App`, `Hadolint`, `JSON Lint`, `Shellcheck`, `YAMLLint`,
    `Prettier`, `zizmor`, `Build {arch}`)
  - `Base image pins match`
  - `Smoke test`
  - `Trivy scan`
  - `Supervisor e2e`

  Add a bypass for the `RELEASE_TOKEN` identity (the user/app the PAT belongs
  to) so the automated `release:` version-bump commit and tag push in
  `release.yaml` aren't themselves blocked by the protection rule.

  `Supervisor e2e` runs `headscale/apparmor.txt` under **real, enforcing**
  AppArmor on the runner's kernel (unlike a local Docker Desktop dev loop,
  whose kernel has no AppArmor LSM at all and so silently passes regardless
  of the profile's correctness) — keep it required so a profile change that
  denies something the addon actually needs (confirmed via kernel AVC/`dmesg`
  denials, not guesswork) is caught before merge, not after a user installs.

- **Dependency graph / Dependabot alerts** — Settings → Advanced Security (or
  `PUT /repos/<owner>/app-headscale/vulnerability-alerts` via the API) should
  be enabled. `ci.yaml` intentionally does not run
  `actions/dependency-review-action`, since that action 404s outright on a
  repo where this isn't on — re-add a `dependency-review` job once it's
  confirmed enabled.
- **GHCR packages must be public** (or grant the Home Assistant Supervisor's
  pull path explicit read access) — `ghcr.io/<owner>/{arch}-addon-headscale`
  is pulled anonymously by installs; a private package will fail to install
  for anyone without registry credentials configured in their Supervisor.
- **Base image pin is updated manually.** Dependabot's Docker ecosystem
  cannot track `FROM ${BUILD_FROM}` in `headscale/Dockerfile` because the tag
  is parameterized through an `ARG` rather than a literal `FROM` line —
  Dependabot only parses literal image references. The `Base image pins
match` CI check (`base-sync` job in `ci.yaml`) only guards against
  `ARG BUILD_FROM` and `headscale/build.yaml` drifting apart from each other;
  it does not detect a new upstream base image release. Bumping to a newer
  `hassio-addons/base` version is a manual edit to both files.
