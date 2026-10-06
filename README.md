# k8s-borg

Backup for Kubernetes clusters with [BorgBackup](https://www.borgbackup.org/).
k8s-borg grew out of an internal project (`k3s-borg`) and packages a battle-tested
set of Borg backup tooling as a container image, deployed as a small set of
cluster-native workloads. Each workload can talk to its own dedicated Borg
repository, and can *optionally* be driven by a central
[Borg UI](https://github.com/karanhudia/borg-ui) server.

The image is published to GitHub Container Registry:

```
ghcr.io/ioanalytica/k8s-borg:<tag>
ghcr.io/ioanalytica/k8s-borg:latest
```

## What gets deployed

k8s-borg is deployed as several assets, each instrumented so it can interact
independently with the Borg repository assigned to it:

- **DaemonSet** — backs up cluster **nodes** that carry local file-system assets
  (`BORG_MODE=node`), one backup per node.
- **CronJob** — regular backups of **cluster data** (`BORG_MODE=cluster`): a
  shared file system, shared user homes, S3 buckets, and **logical DB dumps** of
  in-cluster MariaDB and PostgreSQL databases.
- **`k8s-borg-app` pod** — console access to the DB backups, the Borg archives,
  and the shared file-system resources that also serve as the CronJob's sources.

Optionally, the chart adds a **repository server**: `sshd` and `borg serve` from
the same image, unprivileged, with every client key confined to its own
directory on one node's local storage — see
[chart/README.md](chart/README.md#repository-server-optional).

> Packaging the deployment as a Helm chart is in progress; this repository
> currently provides the **image** and its tooling.

## Two ways to run

### Standalone (default, production)

If `BORG_UI_AGENT` is unset or not `true`, k8s-borg runs completely **without**
Borg UI, on the stable foundation of the previous releases. The container
entrypoint (`/run.sh run`) validates the environment, mounts the sources
(S3 via `s3fs` for cluster/app jobs), takes logical DB dumps (MariaDB/PostgreSQL),
then runs `borg-backup` against the pod's assigned repository.

### Borg UI managed agent (optional, DEV/TEST only)

Set `BORG_UI_AGENT=true` to instead enroll the pod at a Borg UI server as a
**managed agent** and register its assigned repository with the server. From the
Borg UI you can then create, schedule, and interactively run **backup plans,
maintenance jobs, and restores**.

> ⚠️ **The Borg UI integration is under active development and not production
> ready.** Only set `BORG_UI_AGENT=true` in DEV/TEST environments. Enrollment is
> idempotent — an existing `config.toml` skips straight to running the agent.

## Configuration

Core settings (standalone mode), supplied via env / mounted secrets:

| Env var | Purpose |
| --- | --- |
| `BORG_MODE` | `cluster` (default) or `node` — selects the workload's backup flow |
| `NODE_NAME` | Node identity (archive naming; injected from the Downward API) |
| `BORG_REPO` | The Borg repository this pod owns |
| `BORG_PASSPHRASE` | Repository passphrase. Mandatory for Borg 2: every command needs it from 2.0.0b25 on |
| `BORG_ENCRYPTION` | Mode of a repository `borg-init` creates, by Borg UI's name for it; `register-repo` records the same mode. Borg 1: default `repokey-blake2`. Borg 2: default `repokey-aes-ocb`; `authenticated` stands for `authenticated-sha256`; there is no `none`, and `authenticated-blake3` is refused (Borg UI has no name for it) |
| `BORG_REMOTE_PATH` | Name or path of the borg executable on an `ssh://` server |
| `DB_BACKUP_LOCATION` | Where logical DB dumps are written before archiving |
| `S3_ENDPOINT`, `S3_MOUNTPOINT`, `AWS_KEY`, `AWS_SECRET_KEY` | S3 sources (cluster/app jobs; never mounted for node backups) |
| `S3_REGION` | SigV4 region of the S3 endpoint (s3fs `endpoint=`). Empty keeps s3fs's `us-east-1`; servers that check the region, such as Garage, need it |
| `S3_PROBE_TIMEOUT` | Seconds a freshly mounted bucket may take to answer a listing (default 30). A bucket that fails or does not answer stops the start; s3fs itself reports success in that case and leaves a mount that blocks its first reader |

Mounted files the standalone flow expects: `/root/.borg/{cluster,node}-{include,exclude}.patterns`,
`/root/.borg/cluster-s3-buckets`, and SSH material in `/root/.ssh/`
(`id_ed25519`, `id_ed25519.pub`, `known_hosts`).

Borg UI managed-agent mode (`BORG_UI_AGENT=true`) additionally uses:

| Env var | Purpose |
| --- | --- |
| `BORG_UI_SERVER` | Server URL, e.g. `http://k8s-borg-ui.borg.svc.cluster.local:8081` |
| `BORG_UI_AGENT_NAME` | Agent name at the server (default: hostname) |
| `BORG_UI_ADMIN_USER`, `BORG_UI_ADMIN_PASS` | Admin credentials — only for the one-time enrollment |
| `BORG_UI_CONFIG` | Agent config path (default `/etc/borg-ui-agent/config.toml`; persist it to avoid re-enrolling) |

## Borg versions and the wrappers

Both Borg majors ship so a repository can be served by either — the server (or
your config) chooses per repo:

| Command (PATH) | Version | Real binary run by the wrapper |
| --- | --- | --- |
| `borg`  | 1.x (Alpine package)     | `/usr/bin/borg` |
| `borg2` | 2.x beta (compiled venv) | `/opt/borg-ui-agent/borg2-venv/bin/borg` |

`borg2` is built with the `borgstore[sftp]` extra (paramiko + cryptography), so
it can use plain **SFTP** repositories with **no server-side Borg** — e.g. a
Hetzner Storage Box, which only ships server-side Borg 1.x. Borg 2's repo format
is incompatible with Borg 1 (migrate with `borg transfer`), and Borg 2 is beta —
its on-disk format can change between betas, so use the same `borg2` build
everywhere.

Borg 2 and borgstore are installed as a pair: Borg 2 at the version of the
`borg-ui` manifest, borgstore at exactly the version
`borg-ui/docker/runtime-base.env` states, with the `blake3` extra. A borgstore
version that does not fit the Borg 2 being built fails the build.

The image runs as **root**, so backups can read any source path with no
privilege juggling. On `PATH`, `borg` and `borg2` (`docker/rootfs/usr/local/bin/`)
are thin wrappers that inject default params and exec the real binary. SSH config
and credentials live in `/root/.ssh` (e.g. mounted by an initContainer from a
Secret). Each wrapper injects default common params:

| Env var | Default | Purpose |
| --- | --- | --- |
| `BORG1_DEFAULT_PARAMS` | (empty) | Borg 1; set e.g. `--remote-path=borg-1.4` for a Hetzner Storage Box over `ssh://` |
| `BORG2_DEFAULT_PARAMS` | (empty) | Borg 2; reaches a Storage Box over `sftp://`. Borg 2 has no `--remote-path` |

Server-provided flags override them (borg's argparse lets the last `--remote-path` win).

`BORG_REMOTE_PATH` becomes `--remote-path=<value>` in the `borg` wrapper. Borg 2
dropped that option in 2.0.0b22 and reads the variable itself, so the `borg2`
wrapper adds nothing.

The `borg2` wrapper refuses a `rest://` repository (`BORG_REPO`, `-r`, `--repo`)
when its binary is Borg 2.0.0b25 or later. That Borg has no such scheme and
would read the URL as a local directory; the repository is an `ssh://` one now.
With an earlier Borg 2 in the image the wrapper lets a `rest://` repository
pass. See "Upgrading to Borg 2.0.0b25" in [`chart/README.md`](chart/README.md).

## Layout

| Path | Purpose |
| --- | --- |
| `borg-ui/` | Submodule → `karanhudia/borg-ui` (agent + server source; pinned commit) |
| `docker/Dockerfile` | Agent/backup image (build context = repo root) |
| `docker/rootfs/` | Files copied into the image: `run.sh` (mode dispatch), `run-agent.sh` (enroll + agent), and the `borg-*` / `backup-*` / `restore-*` tools |
| `docker/docker-build.sh`, `docker-build-runtime-base.sh`, `docker-build-server.sh` | Build helpers (`--push` / multi-arch to GHCR). The runtime-base and **server** images build directly from the submodule's `borg-ui/Dockerfile.runtime-base` and `borg-ui/Dockerfile` — no fork copy of the recipe — under our own tag/registry via `--build-arg` / `-t` / `--label` |
| `.github/workflows/` | Tag-triggered multi-arch build → GHCR; daily Trivy scan |
| `install.sh` | Upstream Borg UI VM/systemd installer (unused by the container build) |

## Build

CI builds `linux/amd64` + `linux/arm64` and pushes on any pushed tag. Locally:

```sh
git submodule update --init
docker/docker-build.sh                 # agent image, host arch + self-test
PUSH=1 docker/docker-build.sh <tag>    # multi-arch build + push to GHCR
```

The server and its runtime base build the same way via
`docker/docker-build-server.sh` and `docker/docker-build-runtime-base.sh`
(build the runtime base first — the server is `FROM` it).

## Test

```sh
./run-tests.sh            # lint + unit tests + end-to-end (needs docker)
./run-tests.sh --quick    # lint + unit tests only, ~3 s
```

Three layers: `shellcheck` over every shell script, bats unit tests for the
wrapper logic, and an end-to-end suite that runs the full repository lifecycle
against real Borg repositories inside the agent image, once for Borg 1 and once
for Borg 2. The same three run in CI on every push and pull request. See
[`tests/README.md`](tests/README.md) for what each layer covers.

## Submodule

`borg-ui` provides the agent and server source, pinned to a specific commit
(currently tracking `main`). To advance it:

```sh
git submodule update --remote borg-ui
git add borg-ui && git commit -m "Bump borg-ui submodule"
```
