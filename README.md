# k8s-borg

Container image of the [Borg UI](https://github.com/karanhudia/borg-ui) **managed
agent**, packaged for Kubernetes/Docker. The agent registers with a central Borg
UI server and runs Borg backup/restore jobs on demand, controlled from the Borg
UI server.

This repository builds and publishes the agent image to GitHub Container
Registry:

```
ghcr.io/ioanalytica/k8s-borg:<tag>
ghcr.io/ioanalytica/k8s-borg:latest
```

## Status: setup-only image

This iteration produces a **"cold" image** — everything is installed but the
agent is **not enrolled**:

- Borg 1 (`borgbackup`) on `python:3.12-alpine`
- the `borg-ui-agent` (from the pinned `borg-ui` submodule) in a virtualenv
- no `/etc/borg-ui-agent/config.toml` — registration is deferred

Enrollment (`borg-ui-agent register --server … --token … --name …`) and the
run loop will be wired into the entry point in a later iteration. See the
upstream agent docs in `borg-ui/agent/README.md`.

## Layout

| Path | Purpose |
| --- | --- |
| `borg-ui/` | Submodule → `karanhudia/borg-ui` @ `main` (agent source; pinned commit) |
| `docker/Dockerfile` | Image definition (build context = repo root) |
| `docker/rootfs/` | Files copied into the image (`/entrypoint.sh`) |
| `docker/docker-build.sh` | Local build + self-test helper |
| `.github/workflows/docker-build.yml` | Tag-triggered multi-arch build → GHCR |
| `.github/workflows/cve-scan.yml` | Daily Trivy scan of `:latest` |
| `install.sh` | Upstream Borg UI VM/systemd installer (kept for the future enrollment path; unused by the container build) |

## Build

CI builds `linux/amd64` + `linux/arm64` and pushes on any pushed tag:

```sh
git tag 0.1.0
git push origin 0.1.0
```

Local test build (host architecture only):

```sh
git submodule update --init
docker/docker-build.sh            # builds k8s-borg:local and runs the self-test
```

## Submodule

`borg-ui` is pinned to a specific upstream commit. To advance it:

```sh
git submodule update --remote borg-ui   # move to latest origin/main
git add borg-ui && git commit -m "Bump borg-ui submodule"
```

The submodule uses an HTTPS URL so `git submodule update --init` and GitHub
Actions (`actions/checkout` with `submodules: recursive`) work without SSH keys.
