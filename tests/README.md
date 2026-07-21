# tests

Tests for the shell scripts that ship in the images, in two layers: fast unit
tests on the host, and end-to-end tests against real Borg repositories inside
the agent image. Both run in `.github/workflows/lint-test.yml` on every push and
pull request.

```sh
brew install shellcheck bats-core     # or: apt-get install shellcheck bats

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
| `borg2-wrapper.bats` | the `borg2` wrapper: always-borg2, modern exit codes, missing `/etc/borg-fuse.env` |
| `borg-files-cache-flag.bats` | the S3-mounted gate for `--files-cache=mtime,size` (negative cases only — the positive one needs a real fuse.s3fs mount) |
| `chart-versions.bats` | the image versions stated in `chart/values.yaml`, `chart/Chart.yaml` (including the `annotations.images` block) and `.github/workflows/build.yml` agree, and the chart version follows `appVersion[-N]` |

`chart-versions.bats` reads `borg-ui/VERSION`, so the submodule has to be
checked out. Its extractors are plain sed/awk rather than `yq`, so the check
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
