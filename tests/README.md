# tests

Tests for the shell scripts that ship in the images, in two layers: fast unit
tests on the host, and end-to-end tests against real Borg repositories inside
the agent image. Both run in `.github/workflows/lint-test.yml` on every push and
pull request.

```sh
brew install shellcheck bats-core     # or: apt-get install shellcheck bats
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
| `borg2-wrapper.bats` | the `borg2` wrapper: always-borg2, modern exit codes, missing `/etc/borg-fuse.env` |
| `borg-files-cache-flag.bats` | the S3-mounted gate for `--files-cache=mtime,size` (negative cases only — the positive one needs a real fuse.s3fs mount) |

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
| `lifecycle.bats` | `borg-init` (create, idempotent, real failure), `borg-backup` (archive contents, name template, node vs cluster patterns, empty-pattern skip), `borg-list`, `borg-info`, `borg-break-lock`, `borg-mount`, `borg-delete` |
| `prune.bats` | `borg-prune`: retention window, `KEEP_*` overrides, and the combined prune+compact exit code on real borg output |

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

Remote repositories (ssh://, sftp://, s3://), the mounted-S3 files-cache case,
and the borg version pins. Python and frontend tests live in the `borg-ui`
submodule and run in its own CI.
