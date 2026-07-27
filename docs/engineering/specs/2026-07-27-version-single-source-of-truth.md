# Version Single Source of Truth

Status: target picture. Concerns the k8s-borg build pipeline (`docker/`) and how
it consumes the `borg-ui` submodule. Some steps land as upstream-bound changes in
`borg-ui`; those are marked.

## Problem

One Borg version, one Python version, one runtime-base revision — each is a
single fact, and each is written down by hand in many places across two repos.
Nothing keeps the copies in step, so they drift, and the drift is only ever found
at build or run time.

Every one of these bit us in a single afternoon of rebuilding for Borg 1.4.5:

- The runtime-base **tag** is a hand-typed string in three files. `docker/Dockerfile-server`
  sat at `-r4` while `borg-ui/docker/runtime-base.env` said `-r5`; the build
  scripts read the env file, so `-r4` pointed at an image tag that need not exist.
- The **Borg version** is hand-typed in five files (two runtime-base Dockerfiles ×
  two ARG lines, two server files, the env file). A manifest-only bump to 1.4.5
  would have left the server compiling 1.4.4 and the installer offering neither.
- The **Python version** is hand-typed across the Dockerfiles. `borg-ui/Dockerfile`
  built the backend on `python:3.10-slim` but copied `python3.12/site-packages` —
  a path that does not exist in a 3.10 image, so the recipe would not build at all.
- The **agent version** lives in both `pyproject.toml` and `agent/borg_ui_agent/__init__.py`.
  The wheel takes the pyproject value; only `__init__.py` was bumped, so a fresh
  server shipped an agent (0.1.2) a release behind its own code (0.1.3).

Underneath all of it: the tag is *copied*, never *computed*; and the runtime-base
and server recipes are *duplicated* between `borg-ui/` and `docker/`, so they have
drifted in both directions.

The app version already solved its half of this: it lives once, in `borg-ui/VERSION`,
and every chart, workflow, and image tag derives from it (`tests/chart-versions.bats`
guards it). This spec extends that discipline to the Borg / Python / tag / agent
versions.

## The facts, and their one home

The primitive facts move into one file the build reads — evolve the existing
`borg-ui/docker/runtime-base.env`, which already holds most of them:

```
# borg-ui/docker/runtime-base.env  — the versions this image is built from
BORG1_VERSION=1.4.5
BORG2_VERSION=2.0.0b21
BORGSTORE_VERSION=0.4.1
PYTHON_VERSION=3.12
RUNTIME_BASE_REVISION=5
```

What leaves the file: the hand-written `BORG_RUNTIME_BASE_TAG`. It is not a fact,
it is a *function* of the facts (see below). `PYTHON_VERSION` and
`RUNTIME_BASE_REVISION` are new — the revision finally gets a named home instead
of living only inside a tag string.

The agent version is a separate lifecycle (it versions the agent package, not the
image) and stays with the package: `pyproject.toml` is the source, and
`agent/borg_ui_agent/__init__.py` derives it (`importlib.metadata.version`) rather
than repeating the literal. `tests/unit/test_agent_version_consistency.py` already
guards the two until that derivation lands. *(borg-ui change.)*

## The tag is a function, not a field

The runtime-base tag is computed in exactly one place, from the file above:

```
runtime-borg1-${BORG1_VERSION}-borg2-${BORG2_VERSION}-r${RUNTIME_BASE_REVISION}
```

No `BORG_RUNTIME_BASE_TAG=…`, no `…:runtime-borg1-1.4.5-…-r5` literal, lives in any
Dockerfile, env file, or build script. A tiny shared helper (bash for the build
scripts, and the existing `docker/borg-versions.py` extended to emit it) is the
only implementation. This is where the r4/r5 split becomes structurally impossible.

## Everything else derives

- **Build scripts** (`docker/docker-build-*.sh`) source the file, compute the tag,
  and pass every version plus `BASE_IMAGE` and `PYTHON_VERSION` as `--build-arg`.
  The image name and tag come from `-t`; branding from `--label`. Nothing the fork
  needs is baked into a Dockerfile — it is all injected at build time, which is the
  whole reason the copies existed.
- **Dockerfiles** take `ARG PYTHON_VERSION` / `ARG BORG*_VERSION` with the file's
  values as defaults; `FROM python:${PYTHON_VERSION}-slim` and
  `COPY …/python${PYTHON_VERSION}/site-packages` interpolate them. A CI test pins
  those defaults to the file. *(borg-ui change.)*

  The defaults **stay** — they are not emptied. An ARG with no default forces every
  caller to pass it, and a plain `docker build .`, the two `docker-compose*.yml`
  files, and an IDE build would then produce `python:-slim` / `borgbackup==` and
  fail. Keeping the default makes the truth file the *source* of the default and the
  CI test its enforcer, so those callers follow the truth with no change and no
  literal of their own.
- **Compose** (`docker-compose.yml`, `docker-compose.dev.yml`) carries no version
  literal today — it inherits the Dockerfile ARG defaults, including the
  `BASE_IMAGE` runtime-base tag. Because the defaults are truth-pinned, both files
  track the versions file automatically. Building a *different* version is opt-in:
  `docker compose --env-file docker/runtime-base.env …` (wired into `scripts/dev.sh`),
  with `build.args` referencing `${BORG1_VERSION}` etc.; the default path needs
  neither. *(borg-ui files.)*
- **CI** (`.github/workflows/build.yml`) is already most of the way there: its
  `prep` job sources the versions file and passes `borg1`/`borg2` as build-args —
  the model consumer. Two leaks remain, both closed here: it *reads* the stored
  `BORG_RUNTIME_BASE_TAG` (→ compute it in `prep` from the parts, via the shared
  helper), and it hard-codes `BORGSTORE_VERSION=0.4.1` in the runtime-base job
  (→ flow it from the file like the Borg versions). After the cut it builds the
  submodule Dockerfiles rather than the copies. `lint-test.yml` (agent smoke build)
  and `build-image.yml` (generic reusable) are unaffected; borg-ui's own
  `docker-*.yml` build the upstream image and derive the same way.
- **`borg_binaries.json`** is generated by `refresh_borg_binary_manifest.py`, which
  reads the versions file rather than the Dockerfile ARG; `--latest` writes the file
  and regenerates the manifest. `docker/borg-versions.py` already reads the
  generated manifest. *(borg-ui change.)*
- **Tests** derive their expectations from the file; the two remaining hard-coded
  version literals (`test_dockerfile_borg2_fuse.py`, `test_agent_installer_api.py`)
  read it instead. This is the same direction as the guards already written this
  cycle (`tests/runtime-base-tag.bats`, the tag↔versions test, the agent-version
  test).

## No copied recipes

The `docker/` copies of the runtime-base and server Dockerfiles exist so the fork
can build its own images, under its own registry and tags, without disturbing the
upstream project — and because the fork's improvements (hermetic frontend build,
the borgstore backends, the arm64 OpenSSL fix) ran ahead of upstream. Those
improvements are now *in* the submodule (they are the PRs this fork is built on),
so after the `python:3.10 → 3.12` fix, `borg-ui/Dockerfile` and
`borg-ui/Dockerfile.runtime-base` are the complete, canonical, buildable recipes —
functional supersets of the copies.

So the copies go:

- **Drop** `docker/Dockerfile-runtime-base` and `docker/Dockerfile-server`.
- **Point** the build scripts at the submodule Dockerfiles, overriding registry/tag
  (`-t`), base image (`--build-arg BASE_IMAGE`), and branding (`--label`).
- **Keep** `docker/Dockerfile` — the k8s-pod agent image is the one recipe that is
  genuinely the fork's own.

Registry, tags, and branding are build-time inputs; there is no recipe left to fork.

## What enforces it

Drift stops being unlikely and becomes impossible, because a green build requires
agreement. Extending the guards already in place:

- `runtime-base-tag.bats` — `Dockerfile-server` (or, after the cut, the build
  script's computed tag) equals the versions file. *(exists)*
- tag ↔ Borg versions, and the standalone versions, agree. *(exists, borg-ui)*
- agent `pyproject.toml` == `__version__`. *(exists, borg-ui)*
- **new**: exactly one Python minor version across all Dockerfiles — would have
  caught the stray 3.10.
- **new**: every Dockerfile `ARG *_VERSION` default equals the versions file.

## Migration order

Each step leaves the tree buildable; nothing is a flag day.

1. **Python 3.12 fix** in `borg-ui/Dockerfile` (done — the submodule recipe would
   not otherwise build) so the copies can be dropped without regressing.
2. **Drop the copies**; rewire `docker/docker-build-*.sh` onto the submodule
   Dockerfiles with `--build-arg` / `-t` / `--label`. Solves the acute tag/recipe
   sprawl first.
3. **Versions file + computed tag**: add `PYTHON_VERSION` / `RUNTIME_BASE_REVISION`,
   remove the stored tag, compute it in the shared helper.
4. **Parametrize** the Dockerfile ARGs and flip the refresh script to read the file.
5. **Tests** derive from the file; add the two new guards.

## Open decisions

- **Where the shared tag helper lives.** `docker/borg-versions.py` already reads the
  manifest and emits shell; extending it to emit the tag keeps one implementation,
  but the build scripts are bash and could compute it inline from the sourced file.
- **Whether upstream wants `PYTHON_VERSION` parametrized.** The 3.12 literal fix is
  unarguable; the ARG indirection is a fork convenience that may or may not suit an
  upstream PR.

## Non-goals

Consolidating the agent image (`docker/Dockerfile`) into the submodule — it is
deliberately the fork's own. Changing which Borg or Python versions are built (this
is about *where they are stated*, not *what they are*). The chart/app-version
pipeline, which `borg-ui/VERSION` already single-sources.
