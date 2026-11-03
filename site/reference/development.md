# Development

## Layout

| Path | Purpose |
| --- | --- |
| `chart/` | The Helm chart; [`chart/README.md`](https://github.com/ioanalytica/k8s-borg/blob/main/chart/README.md) documents its install and parameters, and this site the rest |
| `borg-ui/` | Submodule → `karanhudia/borg-ui` (agent and server source, pinned commit) |
| `docker/Dockerfile` | Backup/agent/repository server image (build context = repo root) |
| `docker/rootfs/` | Files copied into the image: `run.sh` (mode dispatch), `run-agent.sh` (enroll + agent), `prepare-repo-server.sh`, the `borg-*` / `backup-*` / `restore-*` / `s3-*` tools, `datastore-snapshot`, `sqlite-copy` and `borg-offsite-copy` (the repository server's external copy) |
| `docker/docker-build.sh`, `docker-build-runtime-base.sh`, `docker-build-server.sh` | Build helpers (`--push` / multi-arch to GHCR). The runtime-base and **server** images build directly from the submodule's `borg-ui/Dockerfile.runtime-base` and `borg-ui/Dockerfile`, with no copy of the recipe, under our own tag/registry via `--build-arg` / `-t` / `--label` |
| `examples/` | A Flux `HelmRelease` of the chart and templates of the Secrets it references |
| `local/` | A Docker Compose test stack: Borg UI, PostgreSQL, Redis, repository server and an agent from any borg-ui source tree |
| `tests/` | shellcheck, bats unit tests, the end-to-end suite and the database suite (`tests/e2e/db/`) |
| `.github/workflows/` | Lint and tests on every push; tag-triggered multi-arch image build and chart push to GHCR; daily Trivy scan |

## Build

CI builds `linux/amd64` + `linux/arm64` and pushes on any pushed tag. Locally:

```sh
git submodule update --init
docker/docker-build.sh                 # agent image, host arch + self-test
PUSH=1 docker/docker-build.sh <tag>    # multi-arch build + push to GHCR
```

The server and its runtime base build the same way via
`docker/docker-build-server.sh` and `docker/docker-build-runtime-base.sh`
(build the runtime base first: the server is `FROM` it).

## Test

```sh
./run-tests.sh            # lint + unit tests + end-to-end (needs docker)
./run-tests.sh --quick    # lint + unit tests only, ~3 s
```

Three layers: `shellcheck` over every shell script, bats unit tests for the
wrapper and chart logic, and end-to-end suites inside the agent image. One runs
the full repository lifecycle, the repository server and its external copy
against real Borg repositories, once for Borg 1 and once for Borg 2; the
database suite dumps and restores every engine against real servers of each
supported version. The same three run in CI on every push and pull request.
See [`tests/README.md`](https://github.com/ioanalytica/k8s-borg/blob/main/tests/README.md) for what each layer covers.

## Submodule

`borg-ui` provides the agent and server source, pinned to one commit per
release. The Borg UI image tag is `git describe` of that commit against
borg-ui's release tags (`docker/ui-app-version.sh`), so every pin gets its own
image; see [Versioning](/reference/versioning). To
move the pin:

```sh
git -C borg-ui fetch && git -C borg-ui checkout <commit>
git add borg-ui && git commit -m "Bump borg-ui submodule"
```
