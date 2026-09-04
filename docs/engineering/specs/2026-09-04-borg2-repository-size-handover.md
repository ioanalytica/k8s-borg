# Handover: Borg 2 repository size and repo-info parity

Date: 2026-09-04. Scope: why Borg 2 repositories show `0` / `N/A` as repository
size in borg-ui, what Borg 2.0.0b23 can and cannot report, a proven
client-side way to measure the size, the two independent blockers found in the
live m3s installation, and starting points for making the repository-info
dialogs identical for Borg 1 and Borg 2.

Everything below was measured on 2026-09-04; commands are included so the
next session can re-verify instead of trusting this document.

## 1. Summary

1. **Borg 2.0.0b23 exposes no repository size through any command.** `repo-info`,
   `info`, `repo-list` and `compact` carry no size; the chunks index with refcounts
   is gone, so the Borg 1 notion "deduplicated size of all archives"
   (`cache.stats.unique_csize`) no longer exists client-side.
2. **The size can be measured exactly through borgstore's own API**:
   `get_backend(url)` plus a recursive `list()` walk sums to the byte-exact file
   total of the repository, for `file://`, `sftp://` and `rest://` alike.
3. **In the live m3s installation two independent blockers keep `total_size`
   NULL**, and the first one would also defeat any agent-side fix:
   - the operations chain skips `stats` because `history_index` was *skipped*
     (agents 0.1.3 have no diff support) and the runner treats a skipped
     dependency as failed;
   - the agent's `repository.disk_usage` job runs `du -sb <path>`, which cannot
     work for `rest://` / `sftp://` URLs.
4. The repository-info dialogs differ because the backend hands the UI two
   different JSON shapes (Borg 1 `info --json` with `cache.stats`; Borg 2
   `repo-info --json` without any statistics) and the frontend renders them
   with separate components (`RepositoryStatsV1.tsx` / `RepositoryStatsV2.tsx`).

## 2. What Borg 2.0.0b23 reports (measured)

Image: `ghcr.io/ioanalytica/k8s-borg:1.1.7-alpha.2` (`/usr/local/bin/borg2` → `borg 2.0.0b23`).
Scratch repository with two archives, 13 files, 646,132 bytes (`du -sb` in the
container; 605,172 bytes as the plain sum of file sizes).

Note: `--encryption none` is rejected by b23. Valid values:
`aes256-ocb, chacha20-poly1305, authenticated-sha256, authenticated-blake3, none-sha256, none-blake3`.

```
docker run --rm --entrypoint sh ghcr.io/ioanalytica/k8s-borg:1.1.7-alpha.2 -c '
B=/usr/local/bin/borg2; export BORG_PASSPHRASE=x BORG_REPO=/tmp/r
mkdir -p /tmp/src; head -c 300000 /dev/urandom > /tmp/src/f1; head -c 200000 /dev/urandom > /tmp/src/f2
$B repo-create --encryption=none-sha256; $B create a1 /tmp/src
head -c 100000 /dev/urandom > /tmp/src/f3; $B create a2 /tmp/src
$B repo-info --json; $B info --json a2; $B repo-list --json; $B compact -v; du -sb /tmp/r'
```

`repo-info --json` (complete):

```json
{
  "cache": {"path": "/root/.cache/borg/<repo-id>"},
  "encryption": {"encryption": "none-sha256", "id_hash": "sha256"},
  "repository": {"id": "<repo-id>", "last_modified": "2026-09-04T21:05:15.080124+00:00", "location": "/tmp/r"},
  "security_dir": "/root/.local/share/borg/security/<repo-id>"
}
```

`info --json a2` → `archives[0].stats` (complete):

```json
{"chunking_time": 0.0, "files_stats": {}, "hashing_time": 0.0, "nfiles": 3, "original_size": 600035, "store_stats": {}}
```

- No `compressed_size`, no `deduplicated_size`, no `unique_csize` anywhere.
- `repo-list --json` archive keys: `archive, comment, hostname, id, name, tags, time, username` — no sizes.
- `compact -v` prints object counts only ("Deleting 0 unused objects").
- The command list has no size/usage command; `repo-space` only *reserves* space.

Consequence for the data model: the Borg 1 fields the dialog shows today
(`Used on Disk`, `Unique Data`, `Total Chunks`, `Unique Chunks`) have **no Borg 2
equivalent**. Only "storage used" can be offered for Borg 2, and it must be
labelled as such, not as deduplicated size.

## 3. How borg-ui derives the size today

| Path | Code | Behaviour |
|---|---|---|
| Borg 1, any executor | `app/api/repositories.py` ~919–925, `app/core/borg_router.py:533–535` | `cache.stats.unique_csize` from `info --json` |
| Borg 2, server-executed | `app/core/borg_router.py:511–518` → `app/services/v2/repository_service.py:89–107` → `app/utils/fs.py:calculate_path_size_bytes` | `du` over ssh when `repository.host` is set, else local `du` |
| Borg 2, agent-executed | `app/api/repositories.py:844–970` (`_update_agent_repository_stats`), called from the `stats` executor `app/services/operations/executors/index.py` (`run_stats`, agent branch) | `repository.rinfo` (no size) → fallback job `repository.disk_usage` → agent runs `du -sb <repository_path>` (`agent/borg_ui_agent/repository_ops.py:151–156`) |

The agent fallback landed in upstream #875 (`d468ed4c`, 2026-09-03). The UI tag
`v2.3.0-alpha.1` (2026-08-16) predates it; the agent image `k8s-borg:1.1.7-alpha`
pins borg-ui `974cf2c9`, whose agent has no `repository.disk_usage` at all.

## 4. Live findings (read-only queries, 2026-09-04)

Queries were run with `kubectl -n borg exec k8s-borg-db-0 -c postgres -- psql -U postgres -d borg`.

### styxnet

All 14 repositories are Borg 1 (`ssh://u209739@borg01.ioanalytica.com:23/…`,
executor `agent`) and carry sizes (2.39 MB … 2.39 TB). Not affected.

### m3s — all seven repositories are Borg 2 on `rest://`

```
select id, name, borg_version, executor_type, path, total_size, archive_count from repositories order by id;
1 | k8s-borg-m3s06 | 2 | agent | rest://borg@k3s01/m3s/m3s06 | <null> | 24
… (7 rows, all borg_version=2, executor agent, rest://borg@k3s01/m3s/<name>, total_size NULL)
```

`agent_jobs` has **never** contained a `repository.disk_usage` job
(`select job_type, payload->>'job_kind', count(*) from agent_jobs group by 1,2` lists
backup.create, repository.prune/compact/list_archives/rinfo/check/info/…, no disk_usage).

Agents: all seven `agent_machines` are version `0.1.3`, online, and their
`capabilities` list does **not** contain `repository.disk_usage` (nor diff support).

Running images at the time of the query: `k8s-borg-ui:2.3.0-alpha.1`,
`k8s-borg-app:1.1.7-alpha` (m3s) / `1.1.7-alpha.2` (styxnet).

### Blocker 1: the operations chain never runs `stats`

One run (`run_id` of the latest `stats` operation):

```
25 | archive_sync  | completed |                        |
26 | history_merge | completed |                        | 25
27 | history_index | skipped   | agent_diff_unsupported | 26
28 | stats         | skipped   | dependency_failed      | 27
```

All seven repositories show the same pattern (operations 4/8/12/16/20/24/28,
each depending on a skipped `history_index`). Cause in
`app/services/operations/runner.py:28`:

```python
_FAILED_DEPENDENCY_STATUSES = ("failed", "cancelled", "skipped")
```

and `runner.py:213–222`: a dependency in that set makes the dependent skip with
`dependency_failed`. `stats` does not need `history_index`; a skipped optional
step therefore blocks size refresh for every agent whose Borg/agent lacks diff
support. This is an upstream (karanhudia/borg-ui) design question for the
#888/#897 chain: either `skipped` should satisfy dependents (skip ≠ fail), or
`stats` should not be chained behind `history_index`.

### Blocker 2: `du` cannot measure a store URL

Even with updated agents the fallback runs `du -sb rest://borg@k3s01/m3s/…`,
which fails; `total_size` stays unchanged (NULL). Same for `sftp://`.

## 5. Proven measurement through borgstore (byte-exact)

The Borg 2 repository was copied out of the container and walked on the host
with `borgstore 0.6.1` from PyPI:

```python
from borgstore.store import get_backend

def repository_bytes(url: str) -> int:
    backend = get_backend(url)      # dispatches on the scheme: file:, sftp:, rest:, rclone:, s3:
    backend.open()
    total = 0
    def walk(name: str) -> None:
        nonlocal total
        for item in backend.list(name):
            full = f"{name}/{item.name}" if name else item.name
            if item.directory:
                walk(full)
            else:
                total += item.size or 0
    try:
        walk("")
    finally:
        backend.close()
    return total
```

Result: `packs 602,708 + index 1,882 + config 582 + archives 0 = 605,172 bytes
over 13 files` — identical to the file-size sum. `Store(url=…)` itself is not
usable without Borg's levels `config` (raises "No or invalid config given");
the backend walk needs no layout knowledge.

Backend facts (borgstore 0.6.1 sources): the `rest` backend's `list()` yields
`ItemInfo(size=entry["size"])` from the server's JSON and needs `requests`
(optional import, HTTP basic auth from the URL); the `sftp` backend yields
`st_size` from `listdir_attr` and needs `paramiko`.

### Where borgstore is available

- **k8s agent image**: `/usr/local/bin/borg2` is a wrapper; the venv
  `/opt/borg-ui-agent/borg2/venv` (superproject `docker/Dockerfile`, line ~58:
  `pip install --pre "borgbackup==${BORG2_VERSION}" "borgstore[rclone,sftp,rest,s3]" mfusepy`)
  imports `borgstore` with rest and sftp backends. The agent's own venv
  (`/opt/borg-ui-agent/.venv`, deps `requests` + `websocket-client`) does not.
  ⇒ the agent can run the walk with `/opt/borg-ui-agent/borg2/venv/bin/python`
  without adding a dependency.
- **Bare-metal agents** (`install.sh`, `install_borg2` → `install_borg_from_server`,
  `BORG2_LINK=/usr/local/bin/borg2`): Borg 2 is a server-hosted standalone
  binary; no borgstore. Needs a fallback (clear "unsupported" result, or ship
  `borgstore[rest,sftp]` wheels through `/agent/dist/`).

## 6. Options and open decisions

Upstream (karanhudia/borg-ui):

- **(0) Chain semantics** — file an issue/PR: a skipped dependency must not
  fail `stats` (evidence in section 4). Without this no size fix reaches
  agent repositories whose `history_index` is skipped.
- **(1) Agent `repository.disk_usage` for store URLs** — detect the scheme,
  run the borgstore walk through the Borg 2 venv interpreter, print
  `"<bytes>\t<path>"` so the server parser (`fields[0].isdigit()`,
  `app/api/repositories.py:949–954`) stays untouched; keep `du -sb` for plain
  paths; on agents without borgstore return a clear error instead of `0`.
  Label the value "storage used".
- **(2) borgbackup feature request** — `repo-info` could sum object sizes via
  borgstore `list()`; the data is there.
- **(3) Deployment level** — Hetzner Storage Box quota/usage from the Robot
  API (unrelated to Borg; only relevant for sftp repositories on styxnet).

Deployment (Benjamin): tag `1.1.7-alpha.3` rebuilds both images from the
io/integration pin; the **agent** rollout (`k8s-borg-app`) is what gives the
agents diff + `disk_usage` capabilities — without it Blocker 1 stays.

## 7. Repository-info dialog parity — starting points

Goal: identical dialogs for Borg 1 and Borg 2, with honest labels for what
Borg 2 cannot know.

Frontend:

- `frontend/src/components/RepositoryInfoDialog.tsx` — the dialog.
- `frontend/src/components/RepositoryInfo.tsx`.
- `frontend/src/components/RepositoryStatsV1.tsx` / `RepositoryStatsV2.tsx` — the split rendering.
- `frontend/src/pages/Repositories.tsx` — where it is opened.
- Locale keys `dialogs.repositoryInfo.*`: `encryption, lastModified, repositoryLocation,
  storageStatistics, totalSize, usedOnDisk, uniqueData, totalChunks, uniqueChunks, files,
  archiveCount, latestBackupSize, firstBackup, latestBackup, noBackupsYet`; also
  `repositoryInfo.*` (`totalSize, archives, lastModified, na`).
  `usedOnDisk / uniqueData / totalChunks / uniqueChunks` are Borg 1 `cache.stats`
  concepts with no Borg 2 source.
- API client: `frontend/src/services/api.ts:938` `getRepositoryInfo → GET /repositories/{id}/info`.

Backend:

- `GET /repositories/{repo_id}/info` — `app/api/repositories.py:6200` (`get_repository_info`);
  agent results go through `_parse_agent_json_result` and
  `normalize_repo_info_encryption` (`app/core/borg2.py:106`, which re-adds an
  `encryption.mode` for b22+ output). Server-side Borg 2 uses `Borg2Interface.rinfo`
  (`app/core/borg2.py:375`, `repo-info --json`).
- `GET /{repo_id}/info` in `app/api/v2/repositories.py:529` (v2 API).
- The JSON handed to the UI is the raw Borg shape; parity means the backend
  should emit one normalised model: `{ location, encryption, last_modified,
  archive_count, first_backup, latest_backup, latest_backup_size?,
  storage_used_bytes?, storage_used_source: "borg1_cache_stats" | "du" |
  "borgstore_walk" | null, dedup_stats?: {unique_csize, total_csize, total_chunks,
  unique_chunks} (Borg 1 only) }` and the UI should render one component with
  per-field "not available for Borg 2" states instead of two components.

Side note found on the way (not size-related): the #902 Settings/sidebar
role gate uses `(rank.get(current) ?? 0) >= (rank.get('operator') ?? Infinity)`
while `useAuthorization.hasRole` uses `?? 0` on both sides; before the roles
query has loaded the "Background work" tab is hidden even for admins.

## 8. Re-verification checklist for the next session

1. Section 2 docker probe (needs the image locally; ~10 s).
2. `pip install borgstore` into a scratch venv, copy a b23 repo out with
   `docker cp`, run the walk from section 5 (expect the file-size sum).
3. m3s queries from section 4: `operations` (kind='stats', join on
   `depends_on_id`), `agent_machines.capabilities`, `agent_jobs` job kinds.
4. Check whether the agent rollout happened (`kubectl -n borg get deploy,sts -o
   jsonpath=…image…`) and whether `stats` still skips afterwards.
