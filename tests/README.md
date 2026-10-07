# tests

Tests for the shell scripts that ship in the images, in two layers: fast unit
tests on the host, and end-to-end tests against real Borg repositories inside
the agent image. Both run in `.github/workflows/lint-test.yml` on every push and
pull request.

```sh
brew install shellcheck bats-core helm   # or: apt-get install shellcheck bats, plus helm

./run-tests.sh                        # all three layers, with a summary
./run-tests.sh --quick                # lint + unit tests only, ~3s
```

`run-tests.sh` keeps going after a failing layer and reports every result at the
end, so one command tells you everything that is broken. It refuses to run
quietly without docker: end-to-end is a hard failure then, and `--quick` is how
you ask for less. To drive a single layer directly:

```sh
./tests/shellcheck.sh                 # lint every shell script in the repo
bats tests/                           # unit tests (no docker, ~1s)
bats tests/borg-rc.bats               # a single file
./tests/e2e/run.sh                    # end-to-end, both Borg majors (needs docker)
./tests/e2e/run.sh 2                  # only Borg 2
```

## Unit tests — what is covered

| File | Subject |
| --- | --- |
| `borg-rc.bats` | `borg_rc_is_warning` / `borg_rc_worst` — borg's two exit-code schemes and the error-over-warning precedence |
| `borg-wrapper.bats` | the `borg` gateway: borg1/borg2 dispatch, default-param and `--remote-path` injection, warning downgrade, stdout/stderr separation |
| `borg2-wrapper.bats` | the `borg2` wrapper: always-borg2, modern exit codes, missing `/etc/borg-fuse.env`, no `--remote-path` for Borg 2, and the refusal of a `rest://` repository when the binary is 2.0.0b25 or later (by `BORG_REPO`, `-r`, `--repo`; not for an earlier Borg 2; not for `--version`) |
| `borg-init.bats` | `borg-init`: what `BORG_ENCRYPTION` becomes on the command line of each major, `authenticated` as `authenticated-sha256`, the refusal of `none` and `authenticated-blake3` for Borg 2, and what a failure is blamed on — a command line argparse rejects on `borg-init`, a repository Borg cannot reach (Borg 2's `Error: Could not access …` included, and a remote Borg's own usage error behind it) on the repository |
| `register-repo.bats` | `register-repo`: the encryption mode it records in Borg UI is the one `borg-init` created the repository with, under Borg UI's name (the pairs of issue #10, every Borg 2 mode, Borg 1 unchanged); a mode `borg-init` refuses stops it before the server is asked; a record with the node's path is left alone, the node's own record with another path is moved to `BORG_REPO` (path only) and resynced; a record of another agent, Borg major or encryption mode (with a hint for a copy only when the record's mode is one the node can create; Borg 1 by `BORG1_ENCRYPTION_MODES`), a path held by another record, a local `BORG_REPO` and a move Borg UI refuses stop the pod |
| `borg-mount.bats` | `borg-mount`: a failed mount ends with Borg's exit code, each stream on its own; Borg 2 mounts with `-f` in a session of its own and `borg-mount` returns once the mountpoint is mounted; a Borg 2 mount that ends without mounting fails, one that is not up within `BORG_MOUNT_TIMEOUT` is ended, and an existing mount is not mounted over |
| `agent-borg-shim.bats` | the agent-only `borg` shim: always Borg 1 through the gateway, regardless of the pod's `BORG_VERSION` |
| `s3-mount-bucket.bats` | `s3-mount-bucket`: the s3fs options with and without a region (`endpoint=`), and that a bucket whose listing fails or does not come back in time fails, with the mount aborted, s3fs ended, the mount detached and its empty directory removed; an s3fs that refuses to mount fails before any listing |
| `s3-mount-buckets.bats` | `s3-mount-buckets`: every listed bucket is mounted; under `S3_ON_MOUNT_FAILURE=skip` (the default) one bucket that cannot be mounted is skipped with a warning and the others are mounted (exit 1), none mounted stops the start (exit 2); under `fail` the first such bucket stops it; an unknown policy is refused; `--check` reports the same without mounting |
| `s3-verify-listing.bats` | `s3-verify-listing`: a key the S3 API lists but the mount does not show is reported with a limited sample, the bucket is mounted again and checked once more, and only a bucket still incomplete fails; objects created or deleted during the check, extra files on the mount and `_$folder$` markers do not count; a bucket that lost its mount is mounted again (and fails when it cannot be under `S3_ON_MOUNT_FAILURE=fail`; under `skip` it is left to `s3-mount-buckets --check`); a listing that cannot be written or a failed comparison fails instead of passing; a failing API listing fails without a new mount; the credentials reach rclone through the environment |
| `chart-s3-mount-failure.bats` | `s3.onMountFailure` as `S3_ON_MOUNT_FAILURE` in the CronJob and the console pod: `skip` by default, `fail` passed on, anything else refused, absent without S3; in plan mode `s3-check-mounts` is published to the cluster agent and is the plan's first pre-backup hook |
| `chart-s3-verify-listing.bats` | `s3.verifyListing` as `S3_VERIFY_LISTING` in the cluster CronJob: on by default, off when set to `false`, absent without S3 |
| `borg-files-cache-flag.bats` | the S3-mounted gate for `--files-cache=mtime,size` (negative cases only — the positive one needs a real fuse.s3fs mount) |
| `repo-serve.bats` | `borg-repo-serve`, the forced command of the repository server: Borg 1/Borg 2 dispatch by the client's request, pinned path and permissions, refusal of everything that is not a `serve` request |
| `repo-server-entrypoint.bats` | `prepare-repo-server.sh` and `run-repo-server.sh`: what a plain `authorized_keys` line becomes, the client list, modes of what is staged, and every input that has to stop the start |
| `chart-repo-server.bats` | the chart's repository server: nothing rendered by default, no other object touched when enabled, Service types, storage, and the values that are refused |
| `chart-repo-base.bats` | the chart's repository base: `rest://` refused in `borg.repoBase.value` for Borg 2, a base from an existing Secret left to the wrapper, `BORG_REMOTE_PATH` for both majors, no object rendered by the validations |
| `chart-encryption.bats` | the chart's `borg.encryption`: nothing rendered when empty, `BORG_ENCRYPTION` in the three workloads that create repositories, a mode the major lacks and the keyfile modes refused with the valid ones, and the chart's list per major equal to what `borg-encryption.sh` accepts (Borg 1: `BORG1_ENCRYPTION_MODES`, pinned to Borg 1.4.5), less the keyfile modes |
| `borgstore-pin.bats` | the agent image installs exactly the borgstore the submodule states, with the `blake3` extra; the submodule's two statements of the Borg 2 version agree; `borg-versions.py` stops on a pin that belongs to another Borg 2 |
| `chart-versions.bats` | the image versions stated in `chart/values.yaml`, `chart/Chart.yaml` (including the `annotations.images` block) and `.github/workflows/build.yml` agree, the UI image tag is `git describe` of the borg-ui pin, and the chart version follows `appVersion[-N]` |

`chart-versions.bats` describes the borg-ui pin (`docker/ui-app-version.sh`),
and `borgstore-pin.bats` reads the submodule's manifest and `runtime-base.env`,
so the submodule has to be checked out — with borg-ui's release tags, which our
fork does not carry: `./docker/ui-app-version.sh --fetch-tags` fetches them
from upstream once. Its extractors are plain sed/awk rather than `yq`, so the check
needs no setup; the first test pins the extractors themselves, because one that
quietly stops finding its value would make every later assertion compare `""`
with `""` and pass.

## How the wrappers are put under test

The wrappers run straight from `docker/rootfs/`, unmodified. Two seams make that
possible without installing anything into `/usr/local`:

- `BORG_LIB_DIR` / `BORG_BIN_DIR` — where a wrapper looks for `borg-rc.sh` and
  for the sibling `borg2`. Unset in the image, so production uses `/usr/local`.
- `BORG1_BINARY` / `BORG2_BINARY` — already part of the wrappers; the tests point
  them at a stub that records its argv and returns a chosen exit code.

`tests/helpers/common.bash` holds the setup, the stub generator and the argv
assertions. Every test starts from a clean environment: the wrappers read a lot
of `BORG_*` variables, and a leaked value would silently change behaviour.

## End-to-end tests (`tests/e2e/`)

`run.sh` builds the agent image, layers bats and the tests on top, and runs the
suite inside the container against a throwaway repository in `/tmp`. The scripts
under test are the ones the image ships — unmodified, at their real paths.

The whole suite runs **twice**, once per Borg major (`BORG_TEST_VERSION`), which
is what turns the borg1/borg2 differences into assertions instead of comments:
`init`/`repo-create`, `list`/`repo-list`, `info`/`repo-info`,
`delete`/`repo-delete`, the `REPO::ARCHIVE` syntax Borg 2 dropped, and the
different `mount` argument shape.

| File | Subject |
| --- | --- |
| `lifecycle.bats` | `borg-init` (create, idempotent, real failure), `borg-backup` (archive contents, name template, node vs cluster patterns, empty-pattern skip), `borg-list`, `borg-info`, `borg-break-lock`, `borg-mount` (no mount process left after the unmount), `borg-delete` |
| `prune.bats` | `borg-prune`: retention window, `KEEP_*` overrides, and the combined prune+compact exit code on real borg output |
| `clients.bats` | what the clients say to Borg, each case against a local repository and against one on the repository server: `rest://` refused from 2.0.0b25 on with no directory left behind, `BORG_REMOTE_PATH`, every encryption mode of `borg-init` with backup, prune, list and info, `none` and `authenticated-blake3` refused for Borg 2, what a failed `borg-init` is blamed on (an option Borg does not know, a refused path, an unknown key, a host that does not answer), the passphrase for `break-lock` and `delete`, the exit code of `borg-mount`, no mount process left after the unmount of a remote repository |
| `repo-server.bats` | the repository server with the image's own `sshd` as an unprivileged user and its own Borg as the client: create/backup/list below the client's directory, refusal outside it, no shell and no foreign command, permissions, unknown key, host key across a restart |
| `s3fs.bats` | S3 sources against a single-node Garage in the container, with objects written as rclone writes them (no directory objects): the image's s3fs lists such a directory completely after its stat cache entry expired (the s3fs 1.97 regression), `s3-verify-listing` passes a complete mount, reports a key the mount cannot show and mounts a bucket again whose s3fs was killed, `borg-backup` archives every object, fails a run whose mount misses objects after archiving, and skips the check with `S3_VERIFY_LISTING=false`; `s3-mount-buckets` skips a bucket that does not exist (no mount entry, no s3fs, no directory left) and mounts the rest, and stops when none can be mounted; `borg-backup` ends with a warning while a listed bucket is not mounted and fails under `S3_ON_MOUNT_FAILURE=fail` |

FUSE is required — `borg-mount` is part of the suite. The container gets
`--device /dev/fuse --cap-add SYS_ADMIN`; the host OS is irrelevant, since on
macOS and Windows Docker runs the container in a Linux VM that provides both.
If `/dev/fuse` is unusable the runner fails with a message saying so, rather
than reporting a product failure that is really a harness failure.

Two traps worth knowing when adding tests:

- Borg 2's `repo-list --short` prints archive **IDs**, not names — use
  `--format '{archive}{NL}'` (`archive_names` in the helper).
- Borg 1 mounts one archive at the root of the mountpoint; Borg 2 selects with
  `-a` and gives each matched archive its own subdirectory (`mounted_path`).

`SKIP_BUILD=1` reuses the existing `k8s-borg:test` image. It skips the **agent**
image, so a change under `docker/rootfs/` will not be picked up — rebuild.

## Deliberately not covered here

Remote repositories other than the image's own repository server (sftp://,
s3://, a foreign ssh:// server), the mounted-S3 files-cache case, and the borg
version pins. Python and frontend tests live in the `borg-ui`
submodule and run in its own CI.
