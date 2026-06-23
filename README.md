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

- Borg 1 (`borg`, Alpine package) **and** Borg 2 (`borg2`, compiled into its own
  venv) on `python:3.12-alpine`
- the `borg-ui-agent` (from the pinned `borg-ui` submodule) in a virtualenv
- runs as the unprivileged `borg` user (`1001:1001`) with passwordless sudo for
  `borg`/`borg2` (see below)
- no `/etc/borg-ui-agent/config.toml` — registration is deferred

Enrollment (`borg-ui-agent register --server … --token … --name …`) and the
run loop will be wired into the entry point in a later iteration. See the
upstream agent docs in `borg-ui/agent/README.md`.

## Borg versions and the `borg` user

Both Borg majors are shipped so the server can choose per repository:

| Command | Version | Path |
| --- | --- | --- |
| `borg`  | 1.x (Alpine package)     | `/usr/bin/borg` |
| `borg2` | 2.x beta (compiled venv) | `/usr/local/bin/borg2` |

The agent reports both to the server (`detect_borg_binaries` scans `borg` and
`borg2`); a backup job picks the binary via its `borg_version` (1 → `borg`,
2 → `borg2`) or an explicit `borg_binary`.

`borg2` is built with the `borgstore[sftp]` extra (paramiko + cryptography),
so it can use plain **SFTP** repositories with **no server-side Borg** — e.g. a
Hetzner Storage Box, which only ships server-side Borg 1.x: `borg2 -r
sftp://uXXXXX@uXXXXX.your-storagebox.de:23/./repo …`. Note that Borg 2's repo
format is incompatible with Borg 1 (migrate with `borg transfer`), and Borg 2
is beta — its on-disk format can change between betas, so use the same `borg2`
build everywhere.

The container runs as `borg` (`1001:1001`), which may run `borg` and `borg2` via
**passwordless sudo** (`/etc/sudoers.d/borg`).

> **Note — the agent does not call sudo itself.** It invokes `borg`/`borg2`
> directly as the `borg` user, so the sudo grant is only a *capability*. To back
> up source paths the `borg` user cannot read, one of these is needed (open
> question, to settle with the enrollment work):
> - make mounted source volumes readable by uid `1001`, or
> - put `sudo`-prefixing wrapper scripts named `borg`/`borg2` earlier on `PATH`, or
> - run the container as root.

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
