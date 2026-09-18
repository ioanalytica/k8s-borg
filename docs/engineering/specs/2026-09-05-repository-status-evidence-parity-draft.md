# Draft: repository status from repository evidence, identical for Borg 1 and Borg 2

Date: 2026-09-05. Status: draft for discussion, not yet an upstream proposal.
Companion: `2026-09-04-borg2-repository-size-handover.md` (size only).

## 1. Problem

The repository card (upstream #902) shows two kinds of "last activity":

- the key stats row (`Last backup`, `Last check`) and the meta line
  (`Last compact`), read from `repositories.last_backup / last_check / last_compact`;
- the status strip (`Backup`, `Check`, `Prune`, `Compact`, `Index`, `Mirror`)
  from `GET /repositories/{id}/status-strip`.

Two live installations show the two failure modes:

| Installation | Repository | What the card says | What is true |
|---|---|---|---|
| styxnet (Borg 1, cluster `backupMode=cronjob`, `BORG_REGISTER_PLAN=false`) | `k8s-borg` (id 11) | Last backup 5 Sep, strip: Backup / Prune / Compact "22 days ago" (warning) | The k8s CronJob runs `borg create`, `prune`, `compact` every 6 h. The strip shows the last plan run through Borg UI on 2026-08-14 (`backup_jobs` 7716, `prune_jobs` 7636, `compact_jobs`). |
| m3s (Borg 2.0.0b23, plan mode) | `k8s-borg` (id 7) | Strip correct (plan runs through Borg UI), Total size `N/A`, Index "14 hours ago" | Size: two blockers (handover section 4). Index: `stats_refresh_interval_minutes` is 720 on m3s (60 on styxnet) and the timer restarts with the pod. |

Root cause of the first: every strip cell is the newest terminal row of
`operations` (kinds `backup/check/prune/compact`, categories `index/mirror`)
unioned with the legacy job tables through
`app/services/operations/legacy_status.py`. No cell reads the repository.
Overdue is `now - completed_at > OVERDUE_THRESHOLD_DAYS[cell]` with fixed
thresholds (backup 2, prune 14, compact 30, check 30, index 2, mirror 1 days).
The spec (`docs/engineering/specs/2026-09-03-repository-operations-and-archive-history.md`,
10.2) has no notion of externally created archives, although
`Archive.backup_operation_id` is nullable for exactly that case.

Goal: **same data sources and same rendering for Borg 1 and Borg 2 b23**, with
the repository as the single source of truth wherever Borg exposes the fact,
and job rows only as secondary evidence ("last run through Borg UI").

## 2. What Borg exposes (measured 2026-09-05)

Borg 1.4.5 (`/opt/homebrew/bin/borg`), Borg 2.0.0b23 and 2.0.0b24 (runtime-base
images `runtime-borg1-1.4.5-borg2-2.0.0b2{3,4}-r1`; every Borg 2 result below is
identical on both). Note 2026-09-06: the agent image tag `1.1.7-alpha.2` was
rebuilt and carries b24; both installations run b24.

| Fact | Borg 1 | Borg 2 b23 | Cheap? |
|---|---|---|---|
| Archive list with id + start | `list --json`: `archive, barchive, id, name, start, time` | `repo-list --json --format "{name}{id}{time}"`: `id, name, time` (`time` == `start`) | yes, both read directory entries only. Any further b23 key (`end`, `nfiles`, …) loads archive metadata, on remote stores whole packs per archive (agent comment in `repository_ops.py`). |
| Per-archive start/end/duration/nfiles/original_size | `info --json ::name` | `info --json aid:<id>`: `start, end, duration, stats.nfiles, stats.original_size` | one metadata load per archive |
| Per-archive compressed/deduplicated size | `info` `stats.compressed_size / deduplicated_size` | **not available** (`stats` carries only `nfiles, original_size, chunking_time, hashing_time, files_stats {}, store_stats {}`) | – |
| Repository size | `info --json` `cache.stats.unique_csize` (deduplicated, from the chunks index) | **no command** reports it; byte-exact via `borgstore` backend walk (handover section 5) | walk = one `list()` per directory |
| `repository.last_modified` | `info --json` | `repo-info --json` | last manifest write: `create`/`delete` (Borg 1 also `prune`; Borg 2 `prune` is a soft delete and does not move it); **never `compact` or `check`** (measured isolated 2026-09-06 on 1.4.5, b23, b24) |
| Prune evidence | none native | none native | archive disappearance between two listings (already reported by `archive_sync` as `removed_archive_ids`) |
| Compact evidence | none native | none native | only a Borg UI or agent job row |
| Check evidence | none native | none native | only a job row |
| Encryption | `info` `encryption.mode` | `repo-info` `encryption.encryption` + `id_hash` (`normalize_repo_info_encryption` re-adds `mode`) | yes |

Conclusion: for **backup** and **prune** the repository is the source of truth
in both versions and the data is already in the `archives` table plus the
`archive_sync` result. For **compact** and **check** there is no repository
evidence in either version; the honest rendering is "last run via Borg UI /
agent, or unknown", never "overdue" on its own. For **size** Borg 2 needs
the borgstore walk; the label must say "storage used", since it is not the
deduplicated size Borg 1 reports.

## 3. What Borg UI stores today

| Column / row | Writer | Borg 1 | Borg 2 | Agent |
|---|---|---|---|---|
| `archives.borg_id/name/start` | `archive_sync` (`apply_listing`) | yes | yes | yes |
| `archives.end/duration/nfiles/original_size/*_size` | `fill_archive_info` | server only | server only (`compressed/dedup` stay NULL) | **never** (`fill_archive_info` returns 0 for agents; styxnet: 420 rows, 0 filled) |
| `repositories.last_backup` | `write_repository_archive_columns` (max `archives.start`), `_finish_linked_backup_job`, `_update_agent_repository_stats`, `backup_service` | all | all | yes (three writers, see phase 1 note in the spec) |
| `repositories.last_check / last_compact` | job completion only | job | job | job |
| `repositories.total_size` | `stats` executor | `unique_csize` | server `du` / agent `disk_usage` | m3s: never, `stats` skipped `dependency_failed` behind skipped `history_index`; agent 0.1.3 lacks `disk_usage` |
| strip cells | `status_strip` route | operations + legacy jobs | same | same |
| info dialog `last_modified` (agent repos) | `get_repository_stats` | `repository.updated_at`, **not Borg's value** | same | – |

Removal detection works: on styxnet each `archive_sync` at 09:54 UTC reported
one `removed_archive_ids` entry per repository (daily prune by the CronJob).
On m3s nothing was detected because only the bootstrap run ever executed.

## 4. Proposed model

One normalised status per repository, computed server-side, rendered by one
component for both versions.

```
RepositoryStatus {
  backup:  { at, source: "archive" | "operation" | "legacy" | null, archive_id?, via_borg_ui: bool }
  prune:   { at, source: "removal" | "operation" | "legacy" | null, removed_count?, upper_bound: bool }
  compact: { at, source: "operation" | "legacy" | null }
  check:   { at, source: "operation" | "legacy" | null }
  index:   { at, source: "operation", running }
  mirror:  { at, source, running }              # rclone repositories only
  size:    { bytes, source: "borg1_cache_stats" | "borgstore_walk" | "du" | null, label: "deduplicated" | "storage_used" }
  last_modified: { at, source: "borg" }         # from info / repo-info, both versions
  overdue: per cell, see 4.3
}
```

### 4.1 Cell rules

- **Backup** = `max(archives.start)` for the repository (`source: archive`).
  The newest `backup` operation or `BackupJob` is attached as `via_borg_ui`
  when its `completed_at` is within the archive's `[start, end + tolerance]`,
  otherwise the archive stands alone (external backup). A failed Borg UI
  backup newer than the newest archive is shown as the failure state, since
  that is real information about the last attempt.
- **Prune** = `completed_at` of the newest `archive_sync` whose result has a
  non-empty `removed_archive_ids` (`source: removal`, `upper_bound: true`
  because the removal happened somewhere between the previous listing and
  this one). A `prune` operation or `PruneJob` newer than that wins as exact
  evidence. `delete_archive` and `wipe` also remove archives; the removal
  source therefore says "archives removed", not "prune ran".
- **Compact / Check** = job rows only (operations first, legacy second, as
  today). With no row: "unknown", not "never" and not overdue.
- **Index** unchanged.
- **Size**: Borg 1 `unique_csize`; Borg 2 borgstore walk through the agent
  (handover option 1) or server-side for server-executed repositories;
  `du` only for local `file://` paths. Label by `source`.
- **last_modified**: parse `repository.last_modified` from `info` /
  `repo-info` in `_update_agent_repository_stats` and the server `stats`
  path, store it (new column `repositories.borg_last_modified`), show it in
  the dialog instead of `updated_at`.

### 4.2 Same rendering

- One `RepositoryStats` component replaces `RepositoryStatsV1/V2`; every
  field renders from `RepositoryStatus`, with a "not reported by Borg 2"
  state for `compressed/deduplicated` sizes and chunk counts.
- The strip shows the same six cells for both versions and does not label
  where a value comes from (decision Benjamin 2026-09-06: best available
  source per cell, no provenance in the UI; `source` stays an internal
  field for precedence and debugging).
- Key stats `Last backup` and the strip `Backup` cell read the same value,
  so the contradiction in the styxnet screenshot cannot recur.

### 4.3 Overdue

- Backup: cadence from the series (`anomalies.median_gap` over the last 14
  archives, or the plan cron when a plan exists), overdue when
  `now - max(start) > 2 × cadence` (fallback: today's fixed 2 days when fewer
  than two archives exist).
- Prune: overdue only when a plan with `run_prune_after` exists and no
  removal or prune row is newer than the last backup that the plan's keep
  rules should have pruned; without a plan, no overdue (external prune policy
  is unknown).
- Compact / Check: overdue only relative to a plan or check schedule in
  Borg UI; otherwise "unknown".
- Index: unchanged (2 days), but see 5.4.

## 5. Blockers and prerequisites found on the way

1. **Chain semantics** (`runner.py:28`, `_FAILED_DEPENDENCY_STATUSES` includes
   `skipped`): `stats` is skipped behind a skipped `history_index` on every
   agent without diff support. Seen on m3s (Borg 2) **and styxnet (Borg 1)**.
   Without this fix no size and no `last_modified` refresh reaches agent
   repositories. Upstream issue candidate, independent of this draft.
2. **Agent `repository.disk_usage` for store URLs** (`rest://`, `sftp://`):
   borgstore walk via `/opt/borg-ui-agent/borg2/venv/bin/python`; agents
   0.1.3 on m3s have neither `disk_usage` nor diff (image `1.1.7-alpha`).
3. **Agent per-archive info**: `fill_archive_info` skips agent repositories,
   so `end`, `duration`, `nfiles`, `original_size` are never filled for them
   and the heatmap's size/duration anomalies are blind for every agent
   repository. Needs an agent job (`repository.archive_info` exists as a
   capability) with the same per-run cap.
4. **Reconcile cadence**: `stats_refresh_interval_minutes` drives the index
   (720 on m3s, 60 on styxnet); the timer restarts with the pod. The
   "Index" cell and the backup/prune evidence are only as fresh as this
   interval. Either the backup executor enqueues `archive_sync` as a
   follow-up (it should, spec phase 8), or the interval default for the
   index is decoupled from the old stats refresh setting.
5. **Three writers of `last_backup`** (`write_repository_archive_columns`,
   `_finish_linked_backup_job`, `_update_agent_repository_stats`): the draft
   makes the archives table the only writer.

## 6. Verification queries (read-only)

```
-- strip inputs for one repository
select kind,status,trigger,completed_at,skip_reason from operations o
 where repository_id=:id and completed_at=(select max(completed_at) from operations
 where repository_id=o.repository_id and kind=o.kind);
select status,completed_at from backup_jobs  where repository_id=:id order by completed_at desc limit 1;
select status,completed_at from prune_jobs   where repository_id=:id order by completed_at desc limit 1;
select status,completed_at from compact_jobs where repository_id=:id order by completed_at desc limit 1;
-- repository evidence
select count(*), max(start) from archives where repository_id=:id;
select completed_at, result from operations where kind='archive_sync' and repository_id=:id
   and result::text not like '%"removed_archive_ids": []%' order by completed_at desc limit 3;
select stats_refresh_interval_minutes, background_paused from system_settings;
```

Borg probes: section 2 of the size handover for b23; for `last_modified`
run `create`, `prune`, `compact` with `sleep 2` between them and read
`info --json` (Borg 1) / `repo-info --json` (Borg 2) after each.

## 7. Open questions for upstream

- Is "external archive" a concept the operations spec wants? The archives
  table already models it; the strip and phase 8 do not.
- Should `skipped` satisfy dependents in the runner, or should `stats` not
  depend on `history_index` at all?
- `last_modified` column: new column versus deriving it on read from the
  newest `archive_sync`/`stats` result JSON.
- Where does the Borg 2 storage-used number live in the API: `total_size`
  (string, formatted) as today, or a new `storage_used_bytes` + `source`?

## 8. Complete solution: server, agent, installer, rollout

Decision (Benjamin, 2026-09-05): solve this end to end. An agent update is
only worth it if Borg UI itself can do the same for Borg 2 repositories on
any remote store, not only through the k8s agent. This section lists what
that takes, split by where the code lives.

### 8.1 Where borgstore is importable today

| Runtime | Borg 2 | borgstore importable by the process that would run the walk |
|---|---|---|
| Borg UI server image (`Dockerfile.runtime-base`) | `/opt/borg2-venv/bin/borg`, linked as `/usr/local/bin/borg2` | only inside `/opt/borg2-venv` (`borgstore[rclone,sftp,rest,s3,blake3]==0.6.1`); the app's own site-packages (`requirements.txt`) has no borgstore |
| k8s-borg agent image (`docker/Dockerfile`) | `/opt/borg-ui-agent/borg2/venv`, wrapper `/usr/local/bin/borg2` | only inside that venv; the agent venv (`requests`, `websocket-client`) has none |
| Bare-metal agent (`app/api/agent_installer.py`) | standalone PyInstaller binary from the server (`install_borg_from_server`), `/usr/local/bin/borg2` | **nowhere**: a PyInstaller binary cannot be imported; the agent is pip-installed from the server wheelhouse (`/agent/dist/`, `--no-index`, pins in `agent/constraints.txt`) |

Consequence: shelling out to "the Borg 2 venv's python" works in the two
container images and nowhere else. Superseded by section 8.5: the
chunk-index sum needs `borg` importable (same venvs), the store-level
tools need nothing new, and `borgstore[sftp,rest]` as a declared dependency
is kept only as the option if a uniform walk is ever wanted.

### 8.2 Storage-used by repository scheme (Borg 2)

| `repository.path` | Server-executed | Agent-executed | Note |
|---|---|---|---|
| local path / `file://` | walk (or `du`) | walk (or `du`) | both byte-exact; walk keeps one code path |
| `sftp://` (Hetzner Storage Box) | walk via paramiko | walk | today: server `du` only when `repository.host` is set (ssh), else `du <url>` fails |
| `rest://user@host/path` (ssh + `borgstore-server-rest --stdio`, key bound by `command=",restrict`) | index sum only (walk through borgstore possible, no shell, no HTTP) | same | today: `du <url>` fails on both sides; corrected 2026-09-06 after reading borgstore (`rest://` is not HTTP; `http(s)://` is) |
| `http(s)://` (borgstore REST over HTTP) | walk via `requests` (`Accept: application/vnd.x.borgstore.rest.v1`) | walk | |
| `rclone:` / `s3:` | walk (rclone binary on PATH, boto) | walk | extras already in both venvs |
| `ssh://` (remote `borg serve`) | **no walk**: the store sits behind Borg's RPC; keep `du` over ssh (`calculate_path_size_bytes`) | same via the agent's ssh | requires shell access on the remote; label `source: du` |

The value is "storage used" (sum of object sizes in the store), not Borg 1's
deduplicated `unique_csize`. The API carries `storage_used_bytes` and
`storage_used_source` so the UI can label it; the legacy formatted
`total_size` string stays filled for the card until phase 9 removes it.

### 8.3 Workstreams

Upstream (karanhudia/borg-ui), in dependency order:

1. **Runner: skipped dependency does not fail dependents** (`runner.py:28`, filed as karanhudia/borg-ui#917),
   or `stats` no longer depends on `history_index`. Without it nothing below
   reaches agent repositories. Smallest PR, ships first.
2. **Repository size, read-only** (`app/services/storage_usage.py`, new):
   one function `repository_size(repository) -> (bytes, objects | None, source)`
   with this order: (a) Borg 1 `info --json` `cache.stats.unique_csize`;
   (b) Borg 2 chunk-index sum through `Repository.list()` in the Borg 2
   venv (`source: borg_index`), replaced by `repo-info --stats --json` when
   borgbackup/borg#10329 lands; (c) store-level fallback per scheme
   (`rclone size --json` for `sftp:`/`s3:`/`rclone:`, `requests` GET for
   `rest:`, `du` for local and `ssh://`; `source: storage_used`); (d)
   explicit "unknown", never `0`. Used by `RepositoryV2Service.calculate_total_size_bytes`
   and the `stats` executor, which stores `storage_used_source`.
   No new Python dependency: (b) runs as a small script under the Borg 2
   interpreter, (c) uses tools already shipped.
2b. **`compact --stats -v` on every Borg 2 compact** (server
   `Borg2Interface.compact`, agent `repository.compact`): parse the five
   INFO lines (`--log-json` `log_message` entries) into
   `{source_size, source_files, archive_count, deduplicated_size,
   repository_size, object_count, compression_factor, compaction_saved}`,
   persist them on the compact job / operation result and refresh
   `repositories.total_size` (labelled by source `compact_stats`). Text is
   rounded to three significant digits; store the parsed bytes as Borg
   printed them, do not pretend more precision.
3. **Agent job `repository.storage_usage`** (agent 0.1.4): same order as
   workstream 2 on the agent side, printing JSON
   `{"bytes":…, "objects":…, "source":…}`; capability advertised in
   `agent_machines.capabilities`. Server prefers it, falls back to
   `repository.disk_usage` for older agents, and to "unknown" for
   unsupported schemes (never writes `0`). Bare-metal agents (PyInstaller
   Borg 2, no importable `borg`) get (c) only until #10329 ships.
4. **Agent per-archive info**: `fill_archive_info` dispatches
   `repository.archive_info` (capability exists on 0.1.3) for agent
   repositories with the same `INDEX_ARCHIVE_INFO_PER_RUN` cap, so `end`,
   `duration`, `nfiles`, `original_size` fill for agent repositories and the
   heatmap anomalies work there. Borg 2 leaves `compressed/deduplicated`
   NULL by design.
5. **`last_modified` from Borg**: parse `repository.last_modified` in
   `_update_agent_repository_stats` (rinfo result) and in the server `stats`
   path (`info` / `repo-info`), store as `repositories.borg_last_modified`,
   show it in the dialog instead of `updated_at`.
6. **Status model + strip + dialog** (section 4): `RepositoryStatus` route
   replacing `status-strip`'s job-only semantics, one `RepositoryStats`
   component, cadence-based overdue. Depends on 1 to 5 for the size and
   `last_modified` fields, not for backup/prune.
7. **Reconcile cadence**: `backup` completion (agent and server) enqueues an
   `archive_sync` follow-up so evidence is fresh within minutes, independent
   of `stats_refresh_interval_minutes`.

k8s-borg (this repository):

- Bump the borg-ui pin to the io/integration state that carries 1 to 5,
  tag `1.1.7-alpha.3`, roll out **both** images (`k8s-borg-app` gives the
  agents 0.1.4, `k8s-borg-ui` gives the server the walk and the runner fix).
- `docker/Dockerfile`: nothing to add for the walk once borgstore is an
  agent dependency; keep the borg2 venv extras for `borg2` itself.
- Set `stats_refresh_interval_minutes` on m3s to 60 until workstream 7 lands
  (UI setting, not a chart value).

### 8.4 Order of verification

1. Server side on m3s after the UI rollout: `stats` no longer `skipped`;
   `repositories.total_size` filled for all seven `rest://` repositories;
   `storage_used_source = borgstore_walk`.
2. Agent side after the app rollout: `agent_machines.capabilities` contains
   `repository.storage_usage`; `agent_jobs` shows the kind with `return_code 0`.
3. styxnet (Borg 1, sftp via agent): unchanged `unique_csize` path, but
   `archives.original_size` now filled through `repository.archive_info`.
4. A bare-metal agent installed from `/agent/install.sh` on a clean VM:
   `python -c "import borgstore"` inside the agent venv succeeds; the walk
   runs against an `sftp://` repository without the server.
5. Strip: styxnet `k8s-borg` shows Backup and Prune from archive evidence
   with the CronJob still outside Borg UI; m3s repositories unchanged.

### 8.5 Alternatives to the borgstore walk (measured 2026-09-05)

The walk is not the only source. Measured on b23 in the agent image:

| Source | Covers | Exact | Needs | Verdict |
|---|---|---|---|---|
| `borg2 compact --stats -v` | every scheme, since Borg does the work | rounded to 3 significant digits ("Repository size is 502 kB in 6 objects"), plus "Deduplicated size", "Source data size", "Compression factor" | only a flag on the compact Borg UI / the agent already runs; parse the INFO log line (`--log-json` wraps it as `log_message`) | **native Borg 2 equivalent of Borg 1 `cache.stats`**; refuses `--dry-run` ("Ignoring --stats"), so it is available exactly when a compact runs, i.e. after every plan run |
| `rclone size --json <remote>` | `sftp://`, `s3:`, `rclone:` via on-the-fly backend config (`:sftp,host=…,user=…,port=…,key_file=…:path`) | byte-exact, JSON `{count, bytes}` | rclone, already in the server image, the agent image and `install_rclone` of the bare-metal installer | good for sftp/s3; not for `rest://`; sftp on-the-fly config not yet verified against a Storage Box |
| `GET <rest-url>/<dir>/` with `requests` | `rest://` | byte-exact (`[{name,size,directory,…}]`) | `requests`, already a dependency of server and agent; ~15 lines recursive client | good for rest; nothing else |
| borgstore backend walk | every store scheme | byte-exact | `borgstore[sftp,rest]` as dependency | uniform, but the only option that adds a dependency |
| `create --stats -v` / `create --json` | – | reports store backend traffic only, no repository size | – | not usable |
| `du` | local paths, `ssh://` with shell | exact | nothing | unchanged |

Reading (decision Benjamin, 2026-09-05): `compact --stats` cannot be the
primary source. It only exists when a compact runs, it changes the
repository, and it is rounded. It is still the only place where Borg 2
reports source data size, deduplicated size, compression factor and
compaction savings, so **every Borg 2 compact that Borg UI or the agent
issues gets `--stats -v`** and Borg UI parses and persists the five values
as a compact result (`operations.result` / `compact_jobs`, plus the
repository columns they refresh). The primary, on-demand source for the
repository size is read-only: the chunk-index sum below where Borg is
importable, `repo-info --stats` once borgbackup/borg#10329 ships, and the
store-level tools per scheme where neither is available.

**Read-only variant (measured 2026-09-05, extended 2026-09-06: works on an
`aes256-ocb` repository without passphrase, the index needs no key; with
`lock=False` it reads while a backup holds the exclusive lock, with the
default shared lock it times out).** No b23 CLI command reports the
size without writing: `repo-info` and `info` carry none (`info --help`:
"for the repository-wide deduplicated size, use borg compact --stats"),
`compact --dry-run` prints "Ignoring --stats", `analyze` reads archives.
The number itself is read-only available: every write operation keeps a
chunk index in the store's `index/` fragments, and `Repository.list()`
yields `(chunk_id, storage_size)` from it under a shared lock without
loading a pack. Summing it reproduces compact's "Repository size" exactly
(402434 bytes = "402 kB in 8 objects", 15 ms on the scratch repo; `du` of
`packs/` is ~5 % higher through pack headers). This is a Python API path
(`from borg.repository import Repository`), so it needs an importable Borg 2:
the server's `/opt/borg2-venv` and the k8s agent's borg2 venv, not the
bare-metal PyInstaller binary. It is also the concrete upstream borgbackup
feature request: `repo-info --stats` (or `compact --dry-run --stats`) from the
index only, no compaction. Posted as borgbackup/borg#10329 (2026-09-05).

### 8.6 Size sources at a glance

Role per source (P = primary on-demand read, C = persisted by-product of
every Borg 2 compact, F = fallback, - = not applicable):

| Runtime | Borg 1 | Borg 2: index sum | Borg 2: `repo-info --stats` (#10329) | Borg 2: `compact --stats -v` | Store tools (rclone / REST GET / du) |
|---|---|---|---|---|---|
| Server, local or `ssh://` path | P `info` `cache.stats` | P (`/opt/borg2-venv`) | P when shipped | C | F (`du`) |
| Server, `sftp:` / `rest:` / `rclone:` / `s3:` | - | P (`/opt/borg2-venv`) | P when shipped | C | F |
| k8s agent (container) | P via `repository.rinfo` | P (agent borg2 venv) | P when shipped | C | F |
| Bare-metal agent (PyInstaller Borg 2) | P via `repository.rinfo` | - (no importable `borg`) | P when shipped | C | F until #10329 |

Fields per source:

| Field | Borg 1 `cache.stats` | Index sum | `repo-info --stats` (proposed) | `compact --stats -v` | Store tools |
|---|---|---|---|---|---|
| repository size (object bytes) | `unique_csize` | exact | exact | rounded | no (file bytes incl. headers/index) |
| object / chunk count | `total_unique_chunks` | exact | exact | rounded text | file count only |
| source data size + files | `total_size` | - | proposed | rounded | - |
| deduplicated size | `unique_size` | - | proposed | rounded | - |
| compression factor | derivable | - | proposed | printed | - |
| compaction saved | - | - | - | printed | - |
| lock | shared | shared | shared | exclusive | none |
| writes to repository | no | no | no | yes | no |
| when | on demand | on demand | on demand | at compact only | on demand |

### 8.7 Workstream register (state 2026-09-14)

Measured end state 2026-09-09 ~06:30Z after the 1.1.7-alpha.7 rollout: every
enrolled agent on both installations reports 0.1.4 with
`repository.storage_usage`; on the Borg 2 installation all seven `rest://`
repositories carry `total_size` with source `borg2_index` (22 MB to 2.35 GB)
and `borg_last_modified`; on the Borg 1 installation all 14 repositories carry
`borg1_cache_stats`; `stats` operations complete (175/0 and 292/4 in the last
twelve hours, one `dependency_failed` behind a failed `archive_sync`);
`history_index` is still skipped `agent_diff_unsupported` everywhere (W14,
#953), which no longer blocks `stats`. The original symptom (card
`Last backup` today, strip "22 days ago") cannot recur: the strip is gone
(#975) and the card row reads the status model (#967).

Update 2026-09-11: waves A to C are merged upstream and deployed as
1.1.7-alpha.9 (io/integration `a7420def` = upstream/main 7df23469 plus the
open #1016). Upstream phases 7 to 10 of the operations runner landed in
between (restore, backup, legacy job tables collapsed into `operations`,
per-repository index mode), so `legacy_status.py` and the `*_jobs` tables
this draft still names are gone; wave D builds against the operations
model only. Rows 18 to 22 record the follow-ups that grew out of the
rollout.

Update 2026-09-14: the backend half of the one-component work is merged
(#1030, stored `storage` payload), #1016 closed W14, and #1042 closed W20
and W21. What remains of the parity work is the frontend of #981 (W6 with
W13), the per-archive sizes on Borg 2 (W15, partly waiting for a Borg 2
beta that contains borgbackup/borg#10336) and the external W8. Rows 23 to
27 record findings and issues from the 1.1.7-alpha.9 soak; 24 to 27 are
reliability follow-ups rather than parity work.

| # | Workstream | Where | State | Depends on | Size |
|---|---|---|---|---|---|
| 1 | Runner: `skipped` dependency must not skip dependants (or `stats` not behind `history_index`) | borg-ui backend | MERGED upstream #948 (2026-09-08, with W4); #917 closed | - | S |
| 2 | Read-only repository size with source order (Borg 1 `cache.stats`, Borg 2 index sum, `repo-info --stats`, store tools, unknown) | borg-ui backend | MERGED upstream #950 (2026-09-07, with W5); #934 closed | 1 for background refresh | M |
| 2b | `--stats -v` on every Borg 2 compact, parse and persist the five values, refresh `total_size` with source `compact_stats` | borg-ui backend + agent | MERGED upstream #974 (2026-09-09, `f6194afd`): agent parses its own `compact --stats` tail into the completion report, server takes it or parses the job log once, statistics in `operations.result["stats"]`, `total_size` filled only where nothing measures; `--stats` gated on Borg 2.0.0b15 by a version probe on both sides; #931 closed | - | S |
| 3 | Agent job `repository.storage_usage` (agent 0.1.4), capability, server fallback chain, never `0` | borg-ui agent + backend | MERGED upstream #968 (2026-09-08); #936 closed | 2 | M |
| 4 | Per-archive info for agent repositories via `repository.archive_info` in `fill_archive_info` | borg-ui backend | MERGED upstream #948 (2026-09-08, with W1); #932 closed | - | S |
| 5 | `borg_last_modified` from `info` / `repo-info`, stored; `/repositories/{id}` and `/stats` return it (dialog already shows Borg's value) | borg-ui backend | MERGED upstream #950 (2026-09-07, with W2); #934 closed | 1 | S |
| 6 | `RepositoryStatus` model: backup from archives, prune from removals, compact/check from jobs, one stats component, cadence-based overdue, single writer of `last_backup` | borg-ui backend + frontend | backend MERGED upstream #967 (2026-09-08, `repository_status`, `/status`); the strip retired by #975 (2026-09-09); stored size payload MERGED upstream #1030 (2026-09-13: `total_size_bytes`, `total_size_measured_at`, `storage` object on `GET /repositories` and `GET /repositories/{id}`). OPEN: the single stats component for card, archive header and info dialog (with W13), karanhudia/borg-ui#981. State 2026-09-14: nothing built, no frontend reads `storage`; `useRepositoryStats`, `RepositoryStatsV1/V2` and `RepositoryInfo` still read the live `unique_csize`, which the v2 info route fills only for local paths . Karan's own attempt, upstream PR #1065 (branch `feat/981-unify-repository-statistics`, 5 commits, 20 files), was CLOSED UNMERGED on 2026-09-14 with CodeRabbit changes requested; his comment hands #981 to us | 2 and 5 for size/last_modified only | L |
| 7 | `archive_sync` follow-up after backup completion so evidence is fresh independent of `stats_refresh_interval_minutes` | borg-ui backend | MERGED upstream #949 (2026-09-08); #933 closed | - | S |
| 8 | `repo-info --stats [--json]` read-only from the chunk index | borgbackup | borgbackup/borg#10329 still open (2026-09-14). borgbackup/borg#10336 (`create --json` deduplicated size, #10335) MERGED 2026-09-07 but in no release yet: newest beta is 2.0.0b24 of 2026-09-02 | - | upstream |
| 9 | Pin bump, tag `1.1.7-alpha.3`, roll out both images (agents 0.1.4 + server) | k8s-borg | DONE and moved on: chart 1.1.7-alpha.9 (k8s-borg 9e5a846, 2026-09-11) on io/integration `a7420def` = upstream/main 7df23469 + #1016; both clusters on it, Alembic head `b8c9d0e1f2a3` plus the three upstream revisions of phases 9 and 10 applied at first start | 1-5 | S |
| 10 | m3s `stats_refresh_interval_minutes` 720 -> 60 (UI setting) | deployment | done 2026-09-06 | - | XS |
| 11 | Optional: runtime-base venv layout (Borg 1 shares site-packages with the app) | borg-ui Dockerfile.runtime-base | parked; the chunk-index sum made the venv question moot for the size | - | M |
| 12 | Optional: `borgstore[sftp,rest]` as declared dependency for a uniform store walk | borg-ui + agent | parked; not needed since the index sum and per-scheme tools replaced the walk | - | M |
| 13 | Archive viewer header (`RepositoryStatsGrid` via `useRepositoryStats`) shows `Repository Size = 0 B` on Borg 2: it reads `rinfo_stats.unique_csize` from the live `repo-info` instead of the stored size. Fold into the W6 "one stats component": header, card and info dialog read the stored size with its source label; no size = "unknown", never `0 B` | borg-ui frontend | issue karanhudia/borg-ui#981; the stored `storage` payload it needs exists since #1030 (2026-09-13); still OPEN 2026-09-14, header unchanged | 2, 6 | S |
| 14 | Archive history on agent repositories: `history_index` has no agent job and marked every archive `skipped` / `agent_diff_unsupported`; the Changes tab offered a rebuild that always skipped, and the file panel asserted "No earlier archive contains this path." from an index never built | borg-ui backend + frontend | CLOSED: #953 fixed by upstream #1016 (MERGED 2026-09-11): `history_capability` (available / plan_locked / agent_unsupported) as third gate of `chain_for_repository`, no history stage for agent repositories. Stage two, an agent diff job, filed as karanhudia/borg-ui#1052 (2026-09-14) with measurements: Borg 1, ~566k files, month-apart pair 58 s and 37 MB JSON (~131k stored rows, ~18 MB); Borg 2 over `rest://`, ~900 files, ~3 s | overlaps 1 | M |
| 15 | Archive Info tab on Borg 2 shows `Compressed size = Unknown` and `Unique to this archive = Unknown`. Borg 2 has no compressed size; the per-archive deduplicated size exists only in the `create --stats` text until borgbackup/borg#10336 ships. Fix path: (a) UI states "not reported by Borg 2" instead of "Unknown"; (b) deduplicated size per archive from the backup result through the archive-to-backup-operation link; (c) backup details NULL instead of 0 for what Borg 2 does not report | borg-ui backend + agent + frontend (+ borgbackup release) | OPEN, state 2026-09-14: (a) `ArchiveInfoTab` renders every null size as `common.unknown`, no version-aware state; (b) the link exists upstream (`backup_facade.py` assigns `archives.backup_operation_id` by nearest start), but on m3s only 35 of 245 Borg 2 archives are linked, and borg#10336 is in no Borg 2 release yet; (c) on m3s all 1,145 Borg 2 backups of the last 7 days store compressed and deduplicated size as 0, while all 245 Borg 2 archives correctly carry NULL | 4 (#948) for the fill path, 6 for the tile wording | M |
| 16 | Plan prune/compact fails "agent job could not be queued (dispatch failed)" when the backup follow-up chain (#949) is listing the repository: admission refuses a write beside active read work and `_fail_orphaned_maintenance_job` fails the `*_jobs` row at once instead of waiting like the runner (#948). Measured 8/685 prunes, 3/677 compacts in three days, first with the wave rollout; no data loss, next cycle catches up | borg-ui backend | CLOSED: fix MERGED upstream #1011 (2026-09-10, a plan's prune or compact waits out transient read work before refusing) | 7 (#949), 1 (#948) | S |
| 17 | Inline plan prune/compact (phase 5 `start_inline_maintenance`, created `running`) stays `running` forever when its agent job cannot be queued: `_fail_orphaned_maintenance_job` only knows the legacy `*_jobs` models, so the operation is never closed, and admission then refuses every backup of the repository until a restart. Seen twice on 2026-09-09 (trigger = the #982 race). Fix: resolve through `resolve_maintenance_job`, plan path reports the cause, runtime safety net for running exclusive operations without pid or agent job | borg-ui backend | CLOSED: fix MERGED upstream #1008 (2026-09-10, the inline operation is closed when its agent job cannot be queued) | 16 (#982) | S |
| 18 | Dashboard activity timeline read only the legacy tables after phase 5 moved check/compact/prune to `operations`: lanes empty for the day | borg-ui backend | MERGED upstream #1004 (2026-09-10) | - | S |
| 19 | `stats` recorded the admission 409 as `failed` instead of deferring like `archive_sync` (2-3 red `stats` per wave); a listing timed out at 504 left its queued agent job blocking later work | borg-ui backend | issue #1002 CLOSED, fix MERGED upstream #1012 (2026-09-10) | 16 | M |
| 20 | Index operations of one repository run side by side (duplicate `stats`, `list` next to `rinfo`) | borg-ui backend | CLOSED: #1003 fixed by upstream #1042 (MERGED 2026-09-13, index serialization and lane waits combined) | - | M |
| 21 | Queued stages say "Waiting for the backup" whatever exclusive operation holds the lane | borg-ui backend + frontend | CLOSED: #1001 fixed by upstream #1042 (MERGED 2026-09-13); #1045 (MERGED 2026-09-13) names the running index work in the queue payload | - | S |
| 22 | Direct `BorgRouter.update_stats()` refreshes (wipe, prune, config import, manual) bypass the `stats` operation and its source order | borg-ui backend | CLOSED 2026-09-11: resolved by phase 9 (#1010) which removed the direct refresh; every path enqueues the `stats` chain (verified on main 7df23469, comment on #963) | 2 | M |
| 23 | Archive-to-backup-operation link covers few archives: upstream links by nearest start, but on m3s only 35 of 245 Borg 2 archives carry `backup_operation_id` (2026-09-14). Prerequisite for W15 (b): a deduplicated size from the backup result reaches only linked archives | borg-ui backend | OPEN, not filed; cause not analysed | - | S |
| 24 | Reconcile never runs when the process restarts more often than `stats_refresh_interval_minutes`: the loop sleeps first, no catch-up; run times move with every restart and collide with external writers | borg-ui backend | filed as karanhudia/borg-ui#1055 (2026-09-14); two fixes offered for Karan to choose: anchor on the last reconcile operation, or cron with timezone plus catch-up | - | S |
| 25 | Agent failures lose Borg's reason (the stderr log races the fail call) and a lock held by another process fails background work instead of deferring (Borg 1 legacy rc 2, agent sets no modern exit codes) | borg-ui backend + agent | filed as karanhudia/borg-ui#1056 (2026-09-14), refs #626 | - | M |
| 26 | Index work may start while a plan run on the repository is active but has no operation yet (pre-backup scripts) | borg-ui backend | filed as karanhudia/borg-ui#1057 (2026-09-14) | 25 | S |
| 27 | External writer (cluster CronJob) invisible to Borg UI until the next reconcile: trigger `POST /api/repositories/{id}/resync` after each run; the CronJob gets no Borg UI connection env today | k8s-borg chart + image | filed as ioanalytica/k8s-borg#3 (2026-09-14) | 24 for a long reconcile interval | S |

## 9. Implementation plan (2026-09-06)

Constraints that shape the order: one PR per workstream against
`upstream/main` via the fork (CodeRabbit first); anything that touches the
agent needs an agent release (wheelhouse comes from the server image, so
agent changes ship with a UI image and reach k8s agents only through a
k8s-borg tag); upstream phases 5 to 8 will rewrite the compact and backup
paths, so changes there must be small, self-contained functions that phase 5
can call rather than restructure. Workstream 10 (m3s interval) is done.

### 9.1 Dependency graph

```
W1 runner ─────────────┬──> W2 read-only size (+W5 last_modified) ──> W3 agent storage_usage ──┐
                       │                                                                       ├──> W9 k8s-borg tag
W2b-server compact --stats ──────────────────────────────> W2b-agent ─────────────────────────┘
W4 agent archive_info (independent, no agent release)
W7 archive_sync follow-up (independent)
W6-backend RepositoryStatus (backup/prune independent; size/last_modified fields nullable until W2/W5)
      └──> W6-frontend one component + strip on the new route
W8 borgbackup repo-info --stats (external, no dependency; W2 gains a source when it ships)
```

### 9.2 Waves

| Wave | PRs (parallel within the wave) | Needs merged | Agent release | Verifies on |
|---|---|---|---|---|
| A | W1+W4 in one PR (runner skip semantics and agent per-archive info: "index chain: agent repositories get stats and per-archive info", closes #917 and #932); W2b-server (`--stats -v` on server compact, parser as `app/services/borg2_compact_stats.py`, `compact_jobs.stats` JSON + `total_size`); W7 `archive_sync` follow-up after backup | - | no | after UI image: `stats` completes on agent repos; `archives.original_size` fills; index fresh minutes after a plan run; compact stats persisted for server-executed Borg 2 repos |
| B | W2+W5 in one PR (`storage_usage` source order, `borg_last_modified` column + dialog, `stats` executor writes both); W6-backend (`GET /repositories/{id}/status` with the section 4 model, old `status-strip` kept and served from the new model) | W1 (W2 needs `stats` to run), W2b-server (shares the parser for `compact_stats` source) | no | agent repos show size from index sum via server for server-executed repos; strip on the new route matches the card |
| C | one agent PR: W3 `repository.storage_usage` + W2b-agent (`--stats` on agent compact, server parses job log), agent version 0.1.4, capability list, server fallback chain | W2 | yes | after k8s-borg tag `1.1.7-alpha.3` (both images): m3s `total_size` filled, `agent_jobs` shows the new kind, `capabilities` lists it |
| D | W6-frontend with W13 (#981): one `RepositoryStats` component replacing V1/V2 and the size tile, card, archive header and info dialog read the stored `storage` payload, labels by source, "unknown" and "not reported by this Borg version" states; W15 (a) tile wording rides along | W6-backend (#967), stored payload (#1030), both merged | no | card, archive header and info dialog show the same size on every repository of both installations; no `0 B` for a missing value |
| E | W15 (c) NULL instead of 0 in backup details for Borg 2; W23 link coverage; then W15 (b) once a Borg 2 beta ships borgbackup/borg#10336 | D for the display, a Borg 2 release for (b) | yes for (b) (agent reads the new JSON field) | Borg 2 archives show a deduplicated size from their backup; backup details carry NULL, not 0 |
| ongoing | W8 borgbackup/borg#10329; when it ships, W2 adds `repo-info --stats` as source and bare-metal agents lose the store-only limitation | - | yes (agent uses the new command) | - |

### 9.3 Notes per PR

- **W1+W4** are separate issues (different mechanism, one needs a spec
  decision) but one PR: both touch only the index executors and the runner,
  and one verification run on an agent repository proves both.
- **W1** must land first only for the *background* effect of W2 and W5;
  their code can be written and reviewed in parallel on branches. If Karan
  prefers the chain-order fix over the runner rule, W2 is unaffected.
- **W2b-server** and **W2b-agent** are split so the server half does not
  wait for an agent release; the parser is one function used by both halves
  and by phase 5 later. The agent half rides in the wave C agent PR.
- **W2 + W5** are one PR because both extend `run_stats` and the rinfo
  parsing; splitting them would touch the same lines twice.
- **W13 rides with W6-frontend**: `useRepositoryStats` is the third reader
  of a size (card, dialog, archive viewer header); when the status model
  lands, the hook takes `total_size`/`total_size_source` from it and the
  `rinfo_stats` branch for Borg 2 goes away. Until then the header keeps
  lying with `0 B` on every Borg 2 repository.
- **W6-backend** shipped before the frontend (#967, #975), and #1030
  (2026-09-13) added the stored `storage` payload, so **W6-frontend / W13
  (#981)** reads that payload only, never a per-version Borg output field.
- **W3** advertises the capability, so a mixed fleet (0.1.3 and 0.1.4) is
  handled by the server fallback; no flag day.
- **io/integration** carries main plus the open PRs of the current wave for
  the k8s-borg pin; W9 tags only after wave C is merged upstream, since the
  agent image is what carries 0.1.4.
- Migration numbers (W2b `compact_jobs.stats`, W5 `borg_last_modified`) are
  reconciled at merge time, not before (open PRs collide on `NNN_`).

### 9.4 Verification order

1. Wave A on the UI image alone (no agent change): m3s and styxnet
   `operations` show `stats | completed`; `archives` info columns fill at
   20 per run; a plan run is followed by `archive_sync` within minutes.
2. Wave B: `repositories.borg_last_modified` set for all repos; new status
   route returns backup from `archives` on the styxnet cron repository.
3. Wave C after the k8s-borg tag: `agent_machines.capabilities` contains
   `repository.storage_usage`; seven m3s repos carry `total_size` with
   `storage_used_source = borg_index`; compact stats present in
   `compact_jobs.stats` for agent compacts.
4. Wave D: card, archive header and info dialog show the same size on every
   repository in both installations; no size reads `0 B`.
5. Wave E: Borg 2 backup details carry NULL for unreported sizes; linked
   Borg 2 archives show a deduplicated size once the Borg beta ships.
