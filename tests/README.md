# tests

Tests for the shell scripts that ship in the images, in three layers: fast unit
tests on the host, end-to-end tests against real Borg repositories inside the
agent image, and end-to-end tests of the database dumps against real database
servers. All run in `.github/workflows/lint-test.yml` on every push and pull
request.

```sh
brew install shellcheck bats-core helm   # or: apt-get install shellcheck bats, plus helm

./run-tests.sh                        # all layers, with a summary
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
./tests/e2e/db/run.sh                 # database dumps, every server version (needs docker)
./tests/e2e/db/run.sh postgres:17     # a single server version
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
| `s3-mount-bucket.bats` | `s3-mount-bucket`: the s3fs options with and without a region (`endpoint=`), and that a bucket whose listing fails or does not come back in time fails, with the mount aborted, s3fs ended, the mount detached and its empty directory removed; an s3fs that refuses to mount fails before any listing; the kill after a failed listing matches only that bucket's s3fs, also with a dot in the bucket name |
| `s3-mount-buckets.bats` | `s3-mount-buckets`: every listed bucket is mounted; under `S3_ON_MOUNT_FAILURE=skip` (the default) one bucket that cannot be mounted is skipped with a warning and the others are mounted (exit 1), none mounted stops the start (exit 2); under `fail` the first such bucket stops it; an unknown policy is refused; `--check` reports the same without mounting |
| `s3-remount-buckets.bats` | `s3-remount-buckets`: every listed bucket is unmounted and mounted again in order; a busy mount is detached lazily and its s3fs ended before the new mount, and the kill matches only that bucket's s3fs (a dot in the name matches only a dot); a bucket that is not mounted is cleaned up and mounted; a bucket that cannot be mounted again does not stop the others and is a warning under `skip`, an error under `fail` or when none can be mounted; no bucket file, no mount |
| `s3-verify-listing.bats` | `s3-verify-listing`: a key the S3 API lists but the mount does not show is reported with a limited sample, the bucket is mounted again and checked once more, and only a bucket still incomplete fails; objects created or deleted during the check, extra files on the mount and `_$folder$` markers do not count; a bucket that lost its mount is mounted again (and fails when it cannot be under `S3_ON_MOUNT_FAILURE=fail`; under `skip` it is left to `s3-mount-buckets --check`, unless it was found incomplete first); a listing that cannot be written or a failed comparison fails instead of passing; a failing API listing fails without a new mount; the credentials reach rclone through the environment |
| `chart-s3-mount-failure.bats` | `s3.onMountFailure` as `S3_ON_MOUNT_FAILURE` in the CronJob and the console pod: `skip` by default, `fail` passed on, anything else refused, absent without S3; in plan mode `s3-remount-buckets` and `s3-check-mounts` are published to the cluster agent, `s3-remount-buckets` is the first pre-backup hook, both run before the database dumps and continue on error; without S3 neither is published |
| `register-backup-plan.bats` | `register-backup-plan`: the pre-backup hooks of the plan in the order given, `continue_on_error` only for the names in `BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE`, no hooks without pre-backup scripts; post-backup hooks run always; with `BORG_PLAN_OWNED_AGENT_SCRIPTS` the plan keeps its other hooks (agent and library scripts), ours run last before and first after the backup, are not added twice, and are removed once no longer configured |
| `datastore-snapshot.bats` | `datastore-snapshot`: k3s etcd, k3s SQLite and kubeadm detected under the host root, etcdctl with each one's client certificate against the node IP (or `DATASTORE_ETCD_ENDPOINT`, or localhost), the k3s token and kubeadm PKI copied along, owner-only modes; the SQLite copy of a live WAL database through a read-only directory is complete and a single file; a node without a datastore is no error; a failed etcdctl, a broken database, a missing token or certificate fail with 2 and leave nothing; `clean` removes only its own directories |
| `chart-datastore-snapshot.bats` | `node.datastoreSnapshot`: off by default; the node pods tolerate control-plane `NoSchedule` taints; a memory-backed snapshot volume with its size limit; the host root stays read-only with no other host path; etcd at `$(HOST_IP)` without the host network, or the host network with localhost, or an explicit endpoint; the snapshot directory in the node include patterns; in agent mode both scripts published (the user's win on a collision) and attached as hooks, and the owned hook names set even when off |
| `chart-s3-verify-listing.bats` | `s3.verifyListing` as `S3_VERIFY_LISTING` in the cluster CronJob: on by default, off when set to `false`, absent without S3; in plan mode `s3-verify-listing` is published to the cluster agent and runs right after `s3-remount-buckets`, ahead of `s3-check-mounts`, all continuing on error; with `s3.verifyListing=false` or without S3 it is neither published nor attached |
| `chart-console-reaper.bats` | the console pod shares its process namespace (the pause container is PID 1 and reaps orphaned processes such as an s3fs that ended after its unmount), also as a managed agent in plan mode |
| `borg-files-cache-flag.bats` | the S3-mounted gate for `--files-cache=mtime,size` (negative cases only — the positive one needs a real fuse.s3fs mount) |
| `repo-serve.bats` | `borg-repo-serve`, the forced command of the repository server: Borg 1/Borg 2 dispatch by the client's request, pinned path and permissions, refusal of everything that is not a `serve` request |
| `repo-server-entrypoint.bats` | `prepare-repo-server.sh` and `run-repo-server.sh`: what a plain `authorized_keys` line becomes, the client list, modes of what is staged, and every input that has to stop the start |
| `chart-repo-server.bats` | the chart's repository server: nothing rendered by default, no other object touched when enabled, Service types, storage, and the values that are refused |
| `chart-repo-base.bats` | the chart's repository base: `rest://` refused in `borg.repoBase.value` for Borg 2, a base from an existing Secret left to the wrapper, `BORG_REMOTE_PATH` for both majors, no object rendered by the validations |
| `chart-encryption.bats` | the chart's `borg.encryption`: nothing rendered when empty, `BORG_ENCRYPTION` in the three workloads that create repositories, a mode the major lacks refused with the valid ones, the keyfile modes rendered, `BORG_KEYS_DIR` in the three workloads for every mode and below their per-node mount of the uiAgent claim, and the chart's list per major equal to what `borg-encryption.sh` accepts (Borg 1: `BORG1_ENCRYPTION_MODES`, pinned to Borg 1.4.5) |
| `reconcile-failure-reason.bats` | `reconcile-borgui` against a fake server: every request bounded in time (the health check more tightly), a failed run naming curl's message or the HTTP status with what the server said (no rejected input, known secrets masked, one short line), a refused k8s write or login named, the `FATAL` line kept with its revision as `lastError` in the status ConfigMap and dropped by the next successful run, notification warnings with the server's reason and without the URL |
| `chart-reconcile.bats` | the reconcile Job's TTL (a day by default, a value), `terminationMessagePolicy: FallbackToLogsOnError`, and the rendered `wait-for-reconcile` script run against a fake k8s API: it shows the `lastError` of its own revision once, ignores an earlier revision's, proceeds once reconciled, bounds its requests |
| `borgstore-pin.bats` | the agent image installs exactly the borgstore the submodule states, with the `blake3` extra; the submodule's two statements of the Borg 2 version agree; `borg-versions.py` stops on a pin that belongs to another Borg 2 |
| `backup-cluster-databases.bats` | `backup-cluster-databases`: only the engines in `BORG_DB_ENGINES` run, in their order, none when it is empty, every wrapper of the image (itself aside) when it is unset; an engine's warning (rc 1) is passed on after the others ran, a failure stops the run with its rc, an engine without a wrapper fails with rc 2 |
| `chart-db-engines.bats` | only the engines a release configures (`enabled` and an instance or `existingSecret`) are dumped, for every engine of the chart's `k8s-borg.databases.supported`: in plan mode only they are published to the cluster agent and attached as pre-backup hooks, in CronJob mode only they are in `BORG_DB_ENGINES` and mounted; none configured renders none and an empty `BORG_DB_ENGINES`; an enabled engine without instances or `existingSecret` fails the render in both modes, naming the engine |
| `chart-db-credentials.bats` | the credentials resolver of secretRef database instances, its script taken from the rendered chart and run with a stub `kubectl`: the MariaDB defaults file and the pgpass line with their passwords escaped, mode 600, `skip-ssl` for a MariaDB instance with `tls: false` |
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
| `clients.bats` | what the clients say to Borg, each case against a local repository and against one on the repository server: `rest://` refused from 2.0.0b25 on with no directory left behind, `BORG_REMOTE_PATH`, every encryption mode of `borg-init` with backup, prune, list and info, a keyfile repository read and written by a new pod (fresh `HOME`) through `BORG_KEYS_DIR` alone and unreadable without it, `none` and `authenticated-blake3` refused for Borg 2, what a failed `borg-init` is blamed on (an option Borg does not know, a refused path, an unknown key, a host that does not answer), the passphrase for `break-lock` and `delete`, the exit code of `borg-mount`, no mount process left after the unmount of a remote repository |
| `repo-server.bats` | the repository server with the image's own `sshd` as an unprivileged user and its own Borg as the client: create/backup/list below the client's directory, refusal outside it, no shell and no foreign command, permissions, unknown key, host key across a restart |
| `s3fs.bats` | S3 sources against a single-node Garage in the container, with objects written as rclone writes them (no directory objects): the image's s3fs lists such a directory completely after its stat cache entry expired (the s3fs 1.97 regression), `s3-verify-listing` passes a complete mount, reports a key the mount cannot show and mounts a bucket again whose s3fs was killed; run as a plan hook through the agent's own `script.run` code, it mounts such a bucket again and its s3fs outlives the hook, also a cancelled one (a session of its own, none of the script's output pipes held, so the agent sees the script end); `s3-remount-buckets` run the same way gives the bucket a new s3fs that outlives the hook, the old one ended, also when a shell keeps the old mount busy; `borg-backup` `borg-backup` archives every object, fails a run whose mount misses objects after archiving, and skips the check with `S3_VERIFY_LISTING=false`; `s3-mount-buckets` skips a bucket that does not exist (no mount entry, no s3fs, no directory left) and mounts the rest, and stops when none can be mounted; `borg-backup` ends with a warning while a listed bucket is not mounted and fails under `S3_ON_MOUNT_FAILURE=fail` |

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

## Database end-to-end tests (`tests/e2e/db/`)

`run.sh` starts, for each server version, three database servers from Docker
Hub (`postgres:<version>-alpine`, `mariadb:<version>`) on a Docker network of
their own — `src`, seeded and dumped, and the empty `dst` and `dst2` — and runs
the engine's bats file next to them in the e2e image (`k8s-borg:e2e`, built by
`tests/e2e/run.sh`). Server versions run in parallel (`E2E_DB_JOBS`, default
3); the default matrix is PostgreSQL 13–18 and MariaDB 10.11, 11.4 and 11.8.

Each run seeds `src` with what a restore must bring back — roles or users with
passwords, memberships and grants down to columns, databases with their own
owner, settings and character sets, non-ASCII text and names, binary data,
large objects, views, functions, procedures, triggers and events, content in
`postgres` and `template1` — and takes a fingerprint of it. It dumps `src`
with `backup-cluster-<engine>` and a credentials file in the chart's format
(a password with the characters the resolver escapes), archives and extracts
the dumps with Borg, restores them, and compares the restored server or
database with the fingerprint.

| File | Subject |
| --- | --- |
| `postgres.bats` | `backup-postgres`: `globals.sql` and one uncompressed custom-format dump per database (template0 aside), mode 600, unchanged through Borg; `restore-postgres --all` into an empty server equal to the source (roles, password hashes, memberships, role settings, databases with owner, settings, grants and comment, every database's objects, privileges, content and large objects), and `template1` handing its content to a new database again; one database in place with `-j` while a session is open, `--as` over an existing database without touching the original, `postgres` and `template1`, `--globals` alone; the PostgreSQL 13–16 rejections of PostgreSQL 18's `pg_restore`; a user without superuser rights (PostgreSQL 14+): roles without passwords, rc 1, also through `backup-cluster-postgres`; `backup-cluster-databases` dumping only the engines in `BORG_DB_ENGINES`; failing dumps (no privileges, wrong password, no server) with rc ≥ 2 and the previous dump left alone; failing restores and refused arguments; removal of the old `*.gz` dumps; deduplication of a second and a slightly changed archive |
| `mariadb.bats` | `backup-mariadb`: one uncompressed dump per database with routines, triggers and events, the full dump, mode 600, unchanged through Borg; `restore-mariadb --all` into an empty server equal to the source (users with password hashes, roles, database, table and column grants, every database's tables, views, routines, triggers, events, counters and content) and the restored users able to log in; one database in place, `--as` over an existing database, with its view and trigger on its own tables, without touching the original; the `mysql` schema refused without `--all`; a backup user with global read privileges only; `backup-cluster-databases` dumping only the engines in `BORG_DB_ENGINES`; failing dumps and restores with rc ≥ 2; removal of the old `*.gz` dumps; deduplication |

The test container does not get the docker socket, so it cannot start a
fresh server of its own: the restore of the whole instance gets `dst`, the
restore of the globals `dst2` (the failing restores use `dst2` after it); the
restores of single databases go into `src` itself.

`E2E_DB_SCRIPTS_FROM_CHECKOUT=1` bind-mounts the checkout's `backup-*` and
`restore-*` scripts and `tests/e2e` over a published image's, so a change to
the dump scripts can be tested without building an image:

```sh
E2E_IMAGE=ghcr.io/ioanalytica/k8s-borg:<tag> E2E_DB_SCRIPTS_FROM_CHECKOUT=1 ./tests/e2e/db/run.sh
```

## Deliberately not covered here

Remote repositories other than the image's own repository server (sftp://,
s3://, a foreign ssh:// server), the mounted-S3 files-cache case, and the borg
version pins. A database dump restored into another server major than the
one it was taken from, and engines without dump scripts (MySQL, MongoDB,
Valkey). Python and frontend tests live in the `borg-ui`
submodule and run in its own CI.
