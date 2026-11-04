# tests

Tests for the shell scripts that ship in the images, in three layers: fast unit
tests on the host, end-to-end tests against real Borg repositories inside the
agent image, and end-to-end tests of the database dumps against real database
servers. All run in `.github/workflows/lint-test.yml` on every push and pull
request; a pull request that changes documentation alone (`scripts/docs-only.sh`:
Markdown at the top level, `LICENSE`, `examples/`, `site/`) skips the two
end-to-end layers.
The site's page "Try it locally" runs as written in a k3d cluster, in a
workflow of its own (see "Try it locally" below).

```sh
brew install shellcheck bats-core helm jq yq node   # or: apt-get install shellcheck bats jq python3-yaml, plus helm >= 3.16, yq 4 (mikefarah/yq) and node >= 22.18
python3 -m venv .venv && . .venv/bin/activate && pip install PyYAML   # if python3 lacks PyYAML

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
./tests/e2e/run.sh 2 prune.bats       # only these files of tests/e2e, Borg 2
./tests/e2e/db/run.sh                 # database dumps, every server version (needs docker)
./tests/e2e/db/run.sh postgres:17     # a single server version
./tests/try-locally/run.sh ./chart    # the page Try it locally in k3d, this chart (needs docker, k3d)
./tests/try-locally/run.sh            # the same with the latest release
./tests/try-locally/run.sh --published DIR   # a chart pulled from GHCR; its images must be there
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
| `chart-s3-mount-failure.bats` | `s3.onMountFailure` as `S3_ON_MOUNT_FAILURE` in the CronJob and the console pod: `skip` by default, `fail` passed on, anything else refused (by the values schema, and by the chart with `--skip-schema-validation`), absent without S3; in plan mode `s3-remount-buckets` and `s3-check-mounts` are published to the cluster agent, `s3-remount-buckets` is the first pre-backup hook, both run before the database dumps and continue on error; without S3 neither is published |
| `node-skipped-mounts.bats` | `node-skipped-mounts`: from mount table fixtures shaped after a node pod's, the node's own disk file systems below a root on another device (btrfs: another subvolume) that Borg reaches, not roots themselves (`\040` unescaped); not kubelet volumes, NFS, tmpfs, overlay or squashfs, not a bind mount of the root's own file system, nothing below a tmpfs or overlay; only the configured kubelet directory (`KUBELET_DIR`) is left out; `NODE_FS_TYPES` sets the types; an unreadable file lists nothing and is no failure |
| `set-check-schedule.bats` | `set-check-schedule`: a configured cron is set and recorded as its own (`BORG_CHECK_SCHEDULE_OWNED`), also when already set, a changed one replaces it and its record, and a record that cannot be written leaves a warning; with no cron configured its own schedule is removed (also when paused), one given another cron in Borg UI since, one of another repository's record and an unreadable one are not (the latter keeps the record), and without a record Borg UI is not asked; `off` removes a schedule set by hand and keeps the pod off the default |
| `run-agent.bats` | `run-agent.sh`: an agent the server knows keeps `set-check-schedule`'s record of its check schedule; one that enrols anew (stale config or none) drops it before `set-check-schedule` runs; a pod with database engines creates `DB_BACKUP_LOCATION` before it registers its plan, one without engines or without a plan does not, and one that cannot create it says so in a warning and registers the plan anyway |
| `register-backup-plan.bats` | `register-backup-plan`: the pre-backup hooks of the plan in the order given, `continue_on_error` only for the names in `BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE`, no hooks without pre-backup scripts; post-backup hooks run always; with `BORG_PLAN_OWNED_AGENT_SCRIPTS` the plan keeps its other hooks (agent and library scripts), ours run last before and first after the backup, are not added twice, and are removed once no longer configured; a node plan carries `--one-file-system` (once, after the operator's flags), a cluster plan does not; a node with no existing root disables its plan (without a PUT, also when missing roots are kept, not again when disabled, none created), a disabled one is enabled again once a root exists, and a cluster plan without roots is left unchanged; a node plan names the node's partitions below a root in a warning; with database engines, a dropped root on `DB_BACKUP_LOCATION` (the directory, one above it or one below it) is named in a warning, also when it was the plan's only root, and none below a root that is kept, without engines or for a directory that exists; the plan takes the pod's own cron, else the default, and `off` keeps it off the default |
| `datastore-snapshot.bats` | `datastore-snapshot`: k3s etcd, k3s SQLite and kubeadm detected under the host root, etcdctl with each one's client certificate against the node IP (or `DATASTORE_ETCD_ENDPOINT`, or localhost), the k3s token and kubeadm PKI copied along, owner-only modes; the SQLite copy of a live WAL database through a read-only directory is complete and a single file; a node without a datastore is no error; a failed etcdctl, a broken database, a missing token or certificate fail with 2 and leave nothing; `clean` removes only its own directories and fails with 2 when it cannot |
| `chart-datastore-snapshot.bats` | `node.datastoreSnapshot`: off by default; the node pods tolerate control-plane `NoSchedule` taints; a memory-backed snapshot volume with its size limit; the host root stays read-only with no other host path; etcd at `$(HOST_IP)` without the host network, or the host network with localhost, or an explicit endpoint; the snapshot directory in the node include patterns; in agent mode both scripts published (the user's win on a collision) and attached as hooks, and the owned hook names set even when off |
| `sqlite-copy.bats` | `sqlite-copy` against a fake Kubernetes API: a claim resolved to a local volume (copied on the node its affinity names, skipped elsewhere), a hostPath volume (copied where the file is), a CSI or other volume (the kubelet's mount for a pod on this node, below a configurable kubelet directory; skipped when not mounted); the copy of a database a writer keeps changing, in WAL mode through a read-only directory and with a rollback journal, is consistent, keeps its journal mode, a single file, mode 600; only the claim and its volume are asked for, with the ServiceAccount token; a claim missing or not bound, a missing volume, an API that refuses or does not answer, a file missing on the node with the volume, no database, a lock held past `SQLITE_BUSY_TIMEOUT`, a path out of the volume (`..`, absolute, a symlink) fail with 2, leave nothing and do not stop the other databases; `save` replaces earlier copies, `clean` removes them |
| `chart-node-sqlite.bats` | `node.sqlite`: off by default (no ServiceAccount, `/node` as before); the list of databases in the config and the copy directory in the node include patterns; the copies on an `emptyDir` with its size limit; `/node` read-only with `HostToContainer`; the node ServiceAccount with `get` on exactly the listed claims (one Role per namespace) and on PersistentVolumes, Roles of its own for a release of the same name in another namespace, and bound to the reconcile-status Role under a reconcile gate; in agent mode the scripts published and attached as hooks, before the datastore snapshot and removed after it; an empty list, a missing field, an invalid namespace or claim name and a path that is absolute or has `..` fail the render |
| `backup-redis.bats` | `backup-redis` with `redis-rdb-sync` as a stub: the key=value config file (comments, CRLF, every bad line refused before a connection), user/TLS/CA passed to every connection (`INFO` and `CLUSTER NODES` through `redis-rdb-sync --query`) and the password only through `REDISCLI_AUTH`, one RDB file for a standalone server, one per primary of a cluster named after its first slot range plus `CLUSTER NODES`, with TLS the nodes by their announced hostname (an auxiliary field is none), a missing `+info` or `+cluster\|nodes` named, a server whose `INFO` reports `dragonfly_version` refused with rc 2 and a pointer to the site's Dragonfly section before any `SYNC`, rc 2 with the previous dump intact when one primary fails, files of an earlier layout removed only after a successful run |
| `redis-rdb-sync.bats` | `redis-rdb-sync` against a fake server (`helpers/fake-redis.py`): a sized and a diskless (EOF mark, split across reads, after keepalives) SYNC answer written byte for byte, the handshake, a Valkey told its own version and a Redis none, AUTH with user from `REDISCLI_AUTH`; a wrong or missing password, a refused SYNC, a dropped link, a cut transfer, a payload that is no RDB file or lacks its EOF record, and no server each end in rc 2; `--query` prints an answer and fails on an error answer; with TLS the CA and the server's name are checked (an address the certificate does not carry, another CA: rc 2, no AUTH sent), `--insecure` checks neither |
| `chart-s3-verify-listing.bats` | `s3.verifyListing` as `S3_VERIFY_LISTING` in the cluster CronJob: on by default, off when set to `false`, absent without S3; in plan mode `s3-verify-listing` is published to the cluster agent and runs right after `s3-remount-buckets`, ahead of `s3-check-mounts`, all continuing on error; with `s3.verifyListing=false` or without S3 it is neither published nor attached |
| `mongodb.bats` | `backup-mongodb` and `restore-mongodb` with stub tools: a replica set dumped with `--oplog`, a standalone server without, a sharded cluster refused, uncompressed and one collection at a time, mode 600, a failed dump keeping the previous archive with rc ≥ 2; `--all` with `--drop` and the oplog replayed only when the archive holds one (`--no-oplog` without), one database dropped then restored, `--as` into another name, `admin`/`local`/`config` and names that are no database names refused before anything is dropped, every failure rc ≥ 2; `--from` reading another instance's archive (a path or a missing archive refused); `mongorestore`'s lines about the databases it skips left out (that message alone, as a whole line), its other lines and its failure kept |
| `restore.bats` | `restore-postgres`, `restore-mariadb` and `restore-mysql` with stub clients: `--from` reading another instance's dumps while connecting with the given credentials file (`--all`, `--globals`, a database, `--as`), a path or an instance without dumps refused before anything is dropped; `restore-postgres --use-list` handing `pg_restore -L` the list, with `-C` under the database's own name and without it for `--as`; the list checked against the dump first, and a list with a line `pg_restore` cannot match, one without entries, a missing list and `--use-list` with `--all` or `--globals` refused before anything is dropped |
| `chart-mongodb.bats` | `databases.mongodb` in the chart: the static Secret, the `/root/.mongodb` mount, `backup-cluster-mongodb` published and attached to the plan, a get-only Role per referenced namespace, the validation of `secretRef` (`uriKey` alone, or host, password key and one user); the rendered resolver run with a stub kubectl: the connection string of a key with a `.` as is, a built URI with the user percent-encoded and the password a single-quoted YAML field, a missing key stopping the resolver |
| `chart-ui-security.bats` | the Borg UI container's privileges by `borgUI.fuse`: privileged by default, as before; with a FUSE device plugin's resource not privileged, `SYS_ADMIN`, privilege escalation, AppArmor unconfined, seccomp `RuntimeDefault` and one device in the limits, which the reconcile Job does not request; with FUSE off no escalation, no `SYS_ADMIN` and no device; a `containerSecurityContext` the user set wins and `{}` renders none; a device resource with FUSE off is refused |
| `examples-helm.bats` | `examples/helm/k8s-borg.yaml`: every key its HelmRelease sets is one `chart/values.yaml` knows (an empty map there takes any key), it renders as is, as standalone backups without Borg UI and with the cluster backup as a Borg UI plan, and it pins the chart version of `Chart.yaml` (a release; while `Chart.yaml` carries a prerelease — any version with a `-` suffix — the example stays on the last release) |
| `changelog-section.bats` | `scripts/changelog-section.sh`, the body of a release: the entry of one version without its heading and the blank lines around it, a version matched whole (`1.2.3` is not `1.2.3-beta.1`), the last section ending at the end of the file, nothing for a version without a section, and an entry in `CHANGELOG.md` for the chart version |
| `docs-only.bats` | `scripts/docs-only.sh`, which lets a pull request skip the end-to-end jobs: Markdown at the top level, `LICENSE`, `examples/` and the documentation site in `site/` are documentation; a path below `docker/`, `chart/`, `tests/`, `scripts/` or `.github/`, the `borg-ui` submodule, Markdown anywhere below the top level, any other file and an empty list are not |
| `site-includes.bats` | the documentation site's includes (`tests/helpers/site.bash`): every file a page includes exists, every region it names is marked once and not empty, every region of `README.md` and `chart/README.md` is closed and shown on a page, every file a page imports as code exists; and every address of the site in the repository (the chart's messages, `values.yaml` and its schema, both READMEs, the examples) names a page of `site/` and a heading on it |
| `site-links.bats` | where a link of the site's pages and of the files they include leads (`siteHref` of `site/.vitepress/links.ts`, run by node): a repository path, also one that starts with a dot (`.github/`), to its file or directory on GitHub with its anchor, or to the page that shows the file; an address of the site to a path on it; a link relative to the page, an anchor, an absolute path, an address with a scheme and a path the repository does not have stay as written; and `scripts/site-relative-links.sh`, which the site build runs on what it built: absolute paths, anchors, a query or an empty link, addresses with a scheme and links relative to the page pass, a link relative to the repository fails, named with its page (`href` quoted either way; `data-href` is no link), and a directory without pages or a page given instead is a usage error |
| `site-workflow.bats` | `.github/workflows/site.yml`: pushes and pull requests run on the same paths, which cover `site/`, the workflow, the scripts its build runs and every file the site includes, imports or its config reads; the build checks the links of what it built before anything is uploaded; only a push to `main` uploads and deploys, and only the deploy job may write to Pages; every job has a time limit |
| `lint-test-workflow.bats` | `.github/workflows/lint-test.yml`: every check the ruleset on `main` requires is a job under its own name; the Borg suites run side by side to the end, Borg 1 alone writing the image cache back; each major runs every file of `tests/e2e` exactly once, so a new file in no part of Borg 2 fails it, and the matrix is `include` alone, with no two jobs of one name; `e2e` waits for every Borg job with `always()` and, run on every combination of results, passes only when they all passed or a documentation-only pull request skipped them; only the end-to-end jobs skip, on the verdict `true` alone, which only a pull request writes, never a tag build; no `paths` filter; every job has a time limit, `e2e-db`'s beyond `run.sh`'s own per-version limit plus the slowest suite; the decision run on real merges: a documentation change passes whatever `main` did since, a script renamed to Markdown does not, and a `HEAD` that is not the merge fails it |
| `try-locally.bats` | `tests/try-locally/` and `.github/workflows/try-locally.yml`: every block of the page the run takes is there, a section ends at the next heading and not at a comment in a block, the page's URL and released chart are replaced everywhere (the checkout's `examples/k3d`, the chart of the command line, or the release without one), the steps have the shape the run reads (one cluster by name, a single port-forward, the plans the page names); an image the registry does not know counts as unpublished, an unreachable registry fails; a chart directory's images are its appVersion and Borg UI tag; pull requests run on the chart, `examples/k3d/`, the page, the run and the workflow and install the checkout's chart, the weekly and manual runs the release, a version (the called run's one input, or a manual one) the chart pulled from GHCR, as a published one; `run.sh` ends with a notice on a chart whose images are not published, and fails on a published chart whose images are missing; `build.yml` calls it for each tag after the signing, with the tag as the version, and no job waits for it; the concurrency group is the job's, by event, ref and inputs, and only a pull request's run is replaced; a time limit, and the k3d the page says it is tested with |
| `e2e-run.bats` | `tests/e2e/run.sh` against a fake docker: without arguments every file of `tests/e2e` runs once per major, with arguments only the files and majors given; a major other than 1 and 2, a file `tests/e2e` does not have and a path are refused before docker runs |
| `e2e-db-timeout.bats` | `tests/e2e/db/run.sh` against a fake docker: a test container that hangs past `E2E_DB_TIMEOUT` is stopped, and the version fails with its name, the tests' output so far and what the container was running; a server start that hangs is ended, so nothing is created after the cleanup; a version that finishes in time passes without waiting for the watchdog, which does not outlive it, nor that of a version that fails before its tests; the summary gives the run's time and each version's phases; only the test's own sleeps count (each runs as its `$TMP/bin/sleep`), so that two runs of the suite on one machine do not fail each other: a sleep the test left is seen, one of another run is not |
| `chart-console-reaper.bats` | the console pod shares its process namespace (the pause container is PID 1 and reaps orphaned processes such as an s3fs that ended after its unmount), also as a managed agent in plan mode |
| `chart-node-start.bats` | the start command of the node pods, run under `/bin/sh` with stubs: in interval mode `/run.sh` again after `node.backupIntervalSeconds`, after a successful and after a failed run; as an agent no loop, the container ends with the status of `/run.sh` (also 0) for the kubelet to start it again, and `sh` stays its parent (PID 1, which reaps orphaned processes) |
| `chart-schedules.bats` | `borg.checkSchedule` / `borg.backupSchedule`: the hostnames the console and node pods set and their `<key>_check_schedule` / `<key>_backup_schedule` entries, `off` also unquoted (YAML's `false`); a schedule change rolls the console pod (`cluster.mode=agent`, its backup schedule in plan mode only) and the node pods (`node.backupMode=agent`), and no other pod or object; the install notes (`helm install --dry-run=client`) name perHost keys no agent pod applies and none for `cluster.nodeName` or `k8s-borg-<node>` keys |
| `borg-files-cache-flag.bats` | the S3-mounted gate for `--files-cache=mtime,size` (negative cases only — the positive one needs a real fuse.s3fs mount) |
| `repo-serve.bats` | `borg-repo-serve`, the forced command of the repository server: Borg 1/Borg 2 dispatch by the client's request, pinned path and permissions, refusal of everything that is not a `serve` request |
| `repo-server-entrypoint.bats` | `prepare-repo-server.sh` and `run-repo-server.sh`: what a plain `authorized_keys` line becomes, the client list, modes of what is staged, and every input that has to stop the start |
| `chart-repo-server.bats` | the chart's repository server: nothing rendered by default, no other object touched when enabled, Service types, storage, and the values that are refused |
| `offsite-copy.bats` | `borg-offsite-copy`, the external copy of the repository server, with a stub rclone: which directories are Borg 1 or Borg 2 repositories (at any depth, nothing below one, no symlink followed), data first, then the rest, then `sync`, lock files excluded, the rclone options in every call; a repository a client wrote to or still holds a lock on copied again and the run failed when it never settles, the other repositories copied all the same; nothing deleted on the remote for an empty or missing data directory |
| `chart-repo-server-offsite.bats` | the chart's `repoServer.offsite`: nothing rendered by default, no other object touched when enabled, the CronJob as the server's unprivileged user with the volume read-only on the server's node, schedule, time zone, `suspend` and the rclone options, every file from a value or an existing Secret, and the values that are refused |
| `chart-repo-base.bats` | the chart's repository base: `rest://` refused in `borg.repoBase.value` for Borg 2, a base from an existing Secret left to the wrapper, `BORG_REMOTE_PATH` for both majors, no object rendered by the validations |
| `chart-persistence.bats` | the access modes of the chart's claims (`persistence.cache`, `.ui`, `.uiAgent`): `ReadWriteMany` by default and also when the key is missing (as `--reuse-values` from an older chart leaves the values), a value set for one claim changes that claim only, a static PV (`createPV`) offers the modes of its claim, an existing claim is used as it is; Borg UI's claim and its static PV only with `borgUI.enabled`, kept by default (`helm.sh/resource-policy: keep`), none for an existing claim |
| `chart-encryption.bats` | the chart's `borg.encryption`: nothing rendered when empty, `BORG_ENCRYPTION` in the three workloads that create repositories, a mode the major lacks refused with the valid ones, the keyfile modes rendered, `BORG_KEYS_DIR` in the three workloads for every mode and below their per-node mount of the uiAgent claim, and the chart's list per major equal to what `borg-encryption.sh` accepts (Borg 1: `BORG1_ENCRYPTION_MODES`, pinned to Borg 1.4.5) |
| `reconcile-failure-reason.bats` | `reconcile-borgui` against a fake server: every request bounded in time (the health check more tightly), a failed run naming curl's message or the HTTP status with what the server said (no rejected input, known secrets masked, one short line), a refused k8s write or login named, the `FATAL` line kept with its revision as `lastError` in the status ConfigMap and dropped by the next successful run, notification warnings with the server's reason and without the URL |
| `admin-login.bats` | the admin login of `reconcile-borgui` and of the agents' password fallback (`borgui_bearer` in `borgui-common.sh`) against a fake server, for a password with surrounding whitespace (the final newline of `--set-file` or `--from-file`): tried as it is first, so an admin an older Borg UI created with the newline logs in at the first try, then without the whitespace (Python's `strip`, as Borg UI creates the admin since 2.3.0); a password without it tried once; the default password rotated to the stripped form, a password of whitespace only never sent empty; a configured password that is the default one, also once stripped, accepted with a warning, also when the PAT is reused; the stripped form masked in a failure reason |
| `chart-reconcile.bats` | the reconcile Job's TTL (a day by default, a value), `terminationMessagePolicy: FallbackToLogsOnError`, and the rendered `wait-for-reconcile` script run against a fake k8s API: it shows the `lastError` of its own revision once, ignores an earlier revision's, proceeds once reconciled, bounds its requests |
| `rclone-pin.bats` | the agent image's rclone ARG defaults equal `docker/rclone.env`, and rclone comes from its fetch stage, not Alpine |
| `renovate-config.bats` | `.github/renovate.json`, the dependency update bot: the `borg-ui` submodule, the chart's image tags and dependency, and the runtime base's Python stay excluded; every action is pinned to a commit with its release in a comment; the custom managers find every version pin of `docker/Dockerfile`, `docker/rclone.env` and the workflows (`PYTHON_VERSION` aside), the MySQL digest with its version; `renovate-config-validator --strict` accepts the config where it is installed (`.github/workflows/renovate-config.yml` runs it on every change) |
| `borgstore-pin.bats` | the agent image installs exactly the borgstore the submodule states, with the `blake3` extra; the submodule's two statements of the Borg 2 version agree; `borg-versions.py` stops on a pin that belongs to another Borg 2 |
| `backup-cluster-databases.bats` | `backup-cluster-databases`: only the engines in `BORG_DB_ENGINES` run, in their order, none when it is empty, every wrapper of the image (itself aside) when it is unset; an engine's warning (rc 1) is passed on after the others ran, a failure stops the run with its rc, an engine without a wrapper fails with rc 2 |
| `chart-db-engines.bats` | only the engines a release configures (`enabled` and an instance or `existingSecret`) are dumped, for every engine of the chart's `k8s-borg.databases.supported`: in plan mode only they are published to the cluster agent and attached as pre-backup hooks, in CronJob mode only they are in `BORG_DB_ENGINES` and mounted, and the console pod has them in `BORG_DB_ENGINES` too; none configured renders none and an empty `BORG_DB_ENGINES` on both; an enabled engine without instances or `existingSecret` fails the render in both modes, naming the engine; the install notes warn, in both modes, when no `R` root of `cluster.include` is `borg.dbBackupLocation` or one above it (compared as paths: a trailing `/` and `..` count as written out), also when the only root is below it or merely starts like it, and not without a configured engine or without the cluster backup |
| `chart-db-credentials.bats` | the credentials resolver of secretRef database instances, its script taken from the rendered chart and run with a stub `kubectl`: the MariaDB defaults file and the pgpass line with their passwords escaped, mode 600, `skip-ssl` for a MariaDB instance with `tls: false`, the MySQL defaults file in its own directory with `ssl-mode=DISABLED` and `get-server-public-key` for `tls: false`, the pgpass line from CloudNativePG's Secret shape (the host from the values, not the Secret's short one); the Redis key=value file with the password verbatim, TLS, CA and `insecure` as configured, no `user` line for the default user, a line break or CR in a Redis user or password refused (also a trailing one), a Redis value with `$(…)`, backticks or `'` written as it is and not run; a Redis instance with at most one of `user`/`usernameKey`, the other engines exactly one; releases of the same name in two namespaces get Roles and RoleBindings of their own in a namespace both list |
| `agent-version-stamp.bats` | `docker/agent-version-stamp.sh` against throwaway borg-ui repositories: the pin's `git describe` distance when `agent/` or `pyproject.toml` changed since the nearest release tag, nothing at a tag, without an agent change or before `scripts/agent_version.py`, a failure without a release tag or for an agent version that is not X.Y.Z; on the real pin, no stamp or the distance in the UI tag; `build.yml` computes it once and hands the same value to the agent and the server image, which `build-image.yml` stamps before building |
| `chart-versions.bats` | the image versions stated in `chart/values.yaml`, `chart/Chart.yaml` (including the `artifacthub.io/images` annotation, which has to list every image `values.yaml` names, registry and tag included) and `.github/workflows/build.yml` agree, the UI image tag is `git describe` of the borg-ui pin, and the chart version follows `appVersion[-N]` |
| `release-signing.bats` | `build-image.yml` attaches an SBOM and max-mode SLSA v1 provenance to every platform image and takes no secret into the build arguments that provenance publishes; the merge job's own script, run against a stub `docker`, passes on the digest `imagetools create` reported for the index it pushed and fails when a platform lost its SBOM or provenance or no digest was reported; the chart job's push script, with a stub `helm`, passes on the digest `helm push` printed and fails without one; the chart job waits for the gate and every image job and pushes the chart as its last step, so the sign job signs it right after; `build.yml`'s sign job, the only job with an OIDC token but the Pages deployment of `site.yml`, signs the index of every image job and the chart by those digests, never a tag, and verifies them with the identity `README.md` gives, within a time limit; the GitHub Release comes after it and attaches the chart job's own package; cosign and its installer are pinned to releases |
| `release-prerelease.bats` | every version with a -suffix (a beta, a `-N` chart revision) is a GitHub prerelease and never the Latest release, the images' `latest` tag moves only for a version without one, and no metadata-action rule (`type=ref,event=tag`, `latest=true`) adds it behind that check |
| `artifacthub.bats` | the chart's Artifact Hub listing: `home` is the documentation site, the license annotation is the SPDX identifier of `Chart.yaml`, the category one Artifact Hub knows, every link has a name and URL, `support` goes to the issues and the links into the site name pages it has, every annotation is an `artifacthub.io/` one and `changes`/`prerelease` are left to the release; `scripts/artifacthub-annotations.sh` writes the lead sentences of the version's `CHANGELOG.md` entry as plain text (quotes and backslashes escaped, `### Project and CI` left out, none without an entry) and `prerelease` true for a -suffix, refuses a second key and a file without `annotations:`, and the chart with them still lints; the chart job of `build.yml` writes them before it packages and pushes `artifacthub-repo.yml` to the tag `artifacthub.io` with Artifact Hub's media types before the chart, oras checked against its sums; `artifacthub-repo.yml` has a repository ID and keeps every -suffix version off Artifact Hub, no release |
| `values-schema.bats` | `chart/values.schema.json`, which Helm checks the values against and Artifact Hub shows: draft-07, and `values.yaml` passes it (`helm lint`); every `@param` of `values.yaml` is in it, every key in it is one of `values.yaml`, each leaf with the same default, each key with a type and a description or title; no `required` and no `additionalProperties: false`, so the removed `app` and `config` sections still get the chart's message; an `enum` exactly where `validations.yaml` refuses other values, with the chart's own message behind it under `--skip-schema-validation`; values in the forms `--set`, `--set-string` and Flux deliver pass (text as a number, numbers as text, switches as 0/1 or text, an unquoted `off` as `false`, fractions where the consumer reads them), and so do maps and lists empty as the other kind, and every value the templates render through `common.tplvalues.render` as text; a text for a list, a list for a switch and a fraction for a count are refused; the packaged chart carries it |
| `cve-scan-workflow.bats` | `.github/workflows/cve-scan.yml`, the daily Trivy scan, and its list of images, `scripts/cve-scan-images.sh`: every image `values.yaml` names (the script, which reads it with yq and jq, agrees with the awk extractor `chart-versions.bats` holds the Artifact Hub list to), ours and the runtime base at `latest`, the others at their registry (Docker Hub without one) and tag; a third-party image without a tag (empty or no key) or with one YAML reads as a number (Helm renders `1.10` as `1.1`) and two images of one name stop the list; our images keep the names of their alert categories, and no name carries a tag; every image is scanned to the end; code scanning gets CRITICAL and HIGH alone, with a fix or without, under `trivy-<name>`; one step fails on a finding, on a CRITICAL or HIGH vulnerability with a fix alone (no secrets), less the ones `.github/cve-scan-accepted.yaml` lists, which only that step reads, from the file the scan job checks out; every entry there names its vulnerability, paths or purls, a statement and an expiry date at most three months after the file last changed; the summary, run on Trivy reports, lists those CRITICAL first and counts them, is one line for an image without them or without packages Trivy knows, names a scan that wrote no report as failed, and names a finding the accepted file lists that still failed the run; the run is daily, every job has a time limit, and no permission is granted workflow-wide |

`chart-versions.bats` and `agent-version-stamp.bats` describe the borg-ui pin (`docker/ui-app-version.sh`),
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
different `mount` argument shape. In CI the majors run side by side, and Borg 2
in two parts by file, since it takes twice as long: `e2e (Borg 1)`,
`e2e (Borg 2, part 1)` and `e2e (Borg 2, part 2)`. The check `e2e` passes when
all of them do. The parts are the matrix of `e2e-borg` in
`.github/workflows/lint-test.yml`, each with its files; a new file goes into
one of them, or `lint-test-workflow.bats` fails. `run.sh 2 <file>…` runs one
part locally.

| File | Subject |
| --- | --- |
| `lifecycle.bats` | `borg-init` (create, idempotent, real failure), `borg-backup` (archive contents, name template, node vs cluster patterns, empty-pattern skip, a node backup skips a mount below a root, names it in a warning and archives a root on another file system, a cluster backup follows the mount), `borg-list`, `borg-info`, `borg-break-lock`, `borg-mount` (no mount process left after the unmount), `borg-delete` |
| `prune.bats` | `borg-prune`: retention window, `KEEP_*` overrides, and the combined prune+compact exit code on real borg output |
| `clients.bats` | what the clients say to Borg, each case against a local repository and against one on the repository server: `rest://` refused from 2.0.0b25 on with no directory left behind, `BORG_REMOTE_PATH`, every encryption mode of `borg-init` with backup, prune, list and info, a keyfile repository read and written by a new pod (fresh `HOME`) through `BORG_KEYS_DIR` alone and unreadable without it, `none` and `authenticated-blake3` refused for Borg 2, what a failed `borg-init` is blamed on (an option Borg does not know, a refused path, an unknown key, a host that does not answer), the passphrase for `break-lock` and `delete`, the exit code of `borg-mount`, no mount process left after the unmount of a remote repository |
| `repo-server.bats` | the repository server with the image's own `sshd` as an unprivileged user and its own Borg as the client: create/backup/list below the client's directory, refusal outside it, no shell and no foreign command, permissions, unknown key, host key across a restart |
| `repo-server-offsite.bats` | the repository server's external copy, run as the server's user without a passphrase, to Garage (S3) and to an SFTP target that runs `borg serve`: a client that never talked to the server checks each copy (Borg 2 directly over `s3:` and `sftp://`, Borg 1 downloaded from S3 and over `ssh://` on the target), a backup during a throttled copy makes the job copy again, an empty data directory leaves the copy as it was, the server rebuilt from the copy (no file readable by others; a Borg 1 client that saw a newer state refuses it until it forgets the repository; `borg check` after the next backup), and `BORG_RELOCATED_REPO_ACCESS_IS_OK` for a client that knew the repository on the server |
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
Hub (`postgres:<version>-alpine`, `mariadb:<version>`, `mysql:<version>`,
`percona/percona-server:<version>`, `mongo:<version>`, `redis:<version>`,
`valkey/valkey:<version>`) on a Docker network of
their own — `src`, seeded and dumped, and the empty `dst` and `dst2` — and runs
the engine's bats file next to them in the e2e image (`k8s-borg:e2e`, built by
`tests/e2e/run.sh`). Server versions run in parallel (`E2E_DB_JOBS`, default
3); the default matrix is PostgreSQL 13–18, MariaDB 10.11, 11.4 and 11.8, MySQL
8.4, Percona Server 8.4 (`percona:8.4`), MongoDB 7 and 8.2 (8.0.21+, 8.3 and 9.0 refuse kernels 6.19+), Redis 7 and 8, Valkey 8 and 9, and SQLite as
written by the SQLite of Alpine, Debian 12 and Debian 11 (`sqlite:alpine`,
`sqlite:bookworm`, `sqlite:bullseye`). MySQL and Percona Server run with GTIDs
on. For MongoDB, `src` and `dst` are single-member replica sets with
authentication (a key file), which the tests initiate, and `dst2` is a
standalone server; the tests reach them with the image's pymongo
(`helpers/mongodb.py`), as the image has no MongoDB shell. For Redis and
Valkey, `dst2` is replaced by a cluster of three primaries `c1`–`c3`, TLS
only, with a certificate `run.sh` makes for their hostnames (`openssl`). The
tests write to the cluster once every node knows the others by these
hostnames (before that, a node redirects to one as `?`), and stop a
`valkey-cli` call that takes longer than 60 s (`RD_TIMEOUT`).

SQLite has no server. Its `src` is the application: two writers under
constant load, one in WAL mode and one with a rollback journal
(`tests/e2e/helpers/sqlite-writer.py`), on a Docker volume that the test
container mounts read-only where a node sees a pod's volume, once as a local
volume and once as the kubelet's mount of a CSI volume. A fake Kubernetes
API (`tests/e2e/helpers/fake-k8s-api.py`) serves the claims and volumes.

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
| `postgres.bats` | `backup-postgres`: `globals.sql` and one uncompressed custom-format dump per database (template0 aside), mode 600, unchanged through Borg; `restore-postgres --all --from` into an empty server equal to the source (roles, password hashes, memberships, role settings, databases with owner, settings, grants and comment, every database's objects, privileges, content and large objects), and `template1` handing its content to a new database again; one database in place with `-j` while a session is open, `--as` over an existing database without touching the original, `postgres` and `template1`, one database from a `--use-list` list of `pg_restore -C -l` without a table's content (created again with its grants and comment), a list with a line that matches no entry refused before the drop, and into another name, `--globals` alone; the PostgreSQL 13–16 rejections of PostgreSQL 18's `pg_restore`; a user without superuser rights (PostgreSQL 14+): roles without passwords, rc 1, also through `backup-cluster-postgres`; `backup-cluster-databases` dumping only the engines in `BORG_DB_ENGINES`; failing dumps (no privileges, wrong password, no server) with rc ≥ 2 and the previous dump left alone; failing restores and refused arguments; removal of the old `*.gz` dumps; deduplication of a second and a slightly changed archive |
| `redis.bats` | `backup-redis` (Redis and Valkey, the ACL user `site/features/databases.md` documents): one RDB file of the standalone server, in Valkey 9's own format there, and one per primary of the TLS-only cluster (nodes known by their announced hostnames, which the certificate carries and no IP address) named after its slots with `CLUSTER NODES`, mode 600, unchanged through Borg; the RDB file as `dump.rdb` of a server started on it equal to the source (every type, two databases, non-ASCII and binary values, TTLs, on Valkey 9 a hash field's TTL), and the primaries' files restored one after another equal to the cluster; failing dumps (no `+sync`, wrong password, no server) with rc ≥ 2 and the previous dump left alone; a cluster node reached by an address its certificate does not name fails with rc 2, `insecure=true` dumps it; `backup-cluster-databases` dumping Redis only when `BORG_DB_ENGINES` names it; deduplication of an unchanged instance and of one changed key |
| `mariadb.bats` | `backup-mariadb`: one uncompressed dump per database with routines, triggers and events, the full dump, mode 600, unchanged through Borg; `restore-mariadb --all --from` into an empty server equal to the source (users with password hashes, roles, database, table and column grants, every database's tables, views, routines, triggers, events, counters and content) and the restored users able to log in; one database in place, `--as` over an existing database, with its view and trigger on its own tables, without touching the original; the `mysql` schema refused without `--all`; a backup user with global read privileges only; `backup-cluster-databases` dumping only the engines in `BORG_DB_ENGINES`; failing dumps and restores with rc ≥ 2; removal of the old `*.gz` dumps; deduplication; `backup-mysql` and `restore-mysql` refusing a MariaDB server |
| `mysql.bats` | MySQL and Percona Server: `backup-mysql` writing the same files with MySQL's `mysqldump`, without GTIDs and without the values of generated columns; `restore-mysql --all --from` into an empty server equal to the source (users with password hashes, plugins and password options, roles and default roles, dynamic, database, table and column grants, generated, invisible and JSON columns, functional indexes, checks, views, routines, triggers, events with their definers, counters and content) without the source's GTIDs; one database in place, one after another into a fresh server, `--as` with view, trigger and generated columns on its own tables; a login without TLS as the resolver writes it; `backup-mariadb` and `restore-mariadb` refusing a MySQL server; the rest as `mariadb.bats` |
| `mongodb.bats` | `backup-mongodb`: one uncompressed archive with the oplog, mode 600, unchanged through Borg; `restore-mongodb --all --from` into an empty replica set equal to the source (users with their credentials, custom roles, every database's collections with options, validators, capped and view definitions, indexes and content) and the restored users able to log in — the users first, so that the oplog replay keeps its session, without `mongorestore`'s lines about the databases it skips; one database in place, `--as` over an existing database, with its view on its own collection, without touching the original; the `backup` role dumping everything, the users included, and the `restore` role restoring a database; a standalone server dumped without an oplog; the Community operator's connection string with `admin` in its path; refusals (`admin`, a database the archive lacks) before anything is dropped; `backup-cluster-databases` dumping only the engines in `BORG_DB_ENGINES`; failing dumps and restores with rc ≥ 2 and the previous archive left alone; deduplication |
| `sqlite.bats` | `sqlite-copy` with the application writing: the databases change while they are copied, read-only below `/node`; 20 rounds of copies of both databases from both kinds of volume, each one consistent (integrity check, the writer's invariant), in its journal mode, a single file, mode 600; a copy holds every transaction committed before it; the copies unchanged and mode 600 through Borg, and the application writing on again from a restored copy; `clean` removes them |

The test container does not get the docker socket, so it cannot start a
fresh server of its own: the restore of the whole instance gets `dst` (with a
credentials file named after that server and `--from`, the instance's dumps
into another server), the
restore of the globals `dst2` (the failing restores use `dst2` after it); the
restores of single databases go into `src` itself. The Redis/Valkey `dst`
restarts on its own (`--restart always`) and shares its data directory with
the tests (`/restore`): a restore places `dump.rdb` there and shuts the server
down without saving, and it starts again on the file.

`E2E_DB_SCRIPTS_FROM_CHECKOUT=1` bind-mounts the checkout's `backup-*`,
`restore-*`, `mongodb-admin`, `sqlite-copy` and `redis-rdb-sync` scripts and
`tests/e2e` over a published image's (and installs `valkey-cli` where the image
has none), so a change to the dump scripts can be tested without building an
image:

```sh
E2E_IMAGE=ghcr.io/ioanalytica/k8s-borg:<tag> E2E_DB_SCRIPTS_FROM_CHECKOUT=1 ./tests/e2e/db/run.sh
```

A server version's output is printed when it is done, in one piece, so in a
CI log all its lines carry the time it finished. The summary at the end gives
each version's phases instead: pulling its server image, starting its
servers, its tests, and within them when the servers answered (`# servers
ready after Ns` in the tests' output). On the GitHub runner (4 vCPU) the
suite is bound by CPU: with more than 3 versions at a time each one only takes
longer. One that hangs would print nothing. After `E2E_DB_TIMEOUT` seconds (default 600; the slowest,
MongoDB 7, takes under 3 minutes in CI) `run.sh` stops it: the version fails
with the output its tests had printed, the processes running in the test
container, the output so far of the test that is stuck, and the servers' state
and logs. Stuck before its tests started (a server image that does not
arrive), it ends the docker command it was waiting for, so that nothing is
created after its cleanup.

## Try it locally (`tests/try-locally/`)

`run.sh` runs the page `site/guide/try-locally.md` by its own shell blocks,
read from the page (`lib.bash`): it creates the page's k3d cluster, takes the
files from the checkout's `examples/k3d/` instead of the page's raw URLs and,
given a chart directory, installs that instead of the release. Where the page
clicks in Borg UI, the run takes the admin token from Secret `k8s-borg-ui-pat`
and, through the page's port-forward, starts the node plan and, after the
database step, the cluster plan, and waits for each run. `borg list` and
`borg extract` in the pods then check the datastore snapshot (`state.db`), the
k3s token, `node/etc/os-release` against the node's own and the dump
`shop.dump`. The page's restore in Borg UI is left out. A failed run prints
the pods, events and logs before the cluster goes.

`.github/workflows/try-locally.yml` runs it, not among the checks the ruleset
requires: on pull requests that change the chart, `examples/k3d/`, the page or
the run, with the pull request's chart; on Mondays and by hand with the
latest release; and after each tag's build, which calls it once the tag's
images and chart are in GHCR and signed, with the chart pulled at the tag's
version and the page of the tag's commit (by hand, a version checks a page
change against a prerelease the same way). A chart that names images not
published yet is not run: the job ends with a notice, and the tag's run
checks the page; a pulled chart (`--published`) whose images are missing
fails instead. The tag's run stands beside the release, which does not wait
for it; a red run on an rc means the page or the release needs a fix before
`X.Y.Z` is tagged. The run takes two to three minutes on a laptop with
the images pulled fresh. Locally it needs a free port 8081 and no k3d cluster named
`k8s-borg`; its kubeconfig is its own, `KEEP_CLUSTER=1` keeps the cluster.

## Deliberately not covered here

Remote repositories other than the image's own repository server (sftp://,
s3://, a foreign ssh:// server), the mounted-S3 files-cache case, and the borg
version pins. A database dump restored into another server major than the
one it was taken from, and a Redis/Valkey cluster restored into a cluster.
SQLite copies on a real cluster: the kubelet's mounts and the
`HostToContainer` propagation they need are stood in for by directories and
Docker volumes here; they were checked once on a throwaway k3d cluster
(issue #53). Python and frontend tests live in the `borg-ui`
submodule and run in its own CI.
