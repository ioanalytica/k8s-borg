# Plan: retire the repository status strip, keep its information in the card's metadata row

Date: 2026-09-08. Status: proposal posted on upstream #937
(https://github.com/karanhudia/borg-ui/pull/937#issuecomment-5581817114),
waiting for Karan's answer. Built the same day on the fork branch
`refactor/status-strip-into-card-row` and opened as fork PR
https://github.com/ioanalytica/borg-ui/pull/63 against `io/integration`
(one commit, all gates green, six local review rounds applied; sections 3
and 4 reflect the built state). The upstream PR follows once #967 has
landed.

## 1. Situation

Upstream #937 (`refactor/drop-repository-status-strip`, approved, parked on
our request on 2026-09-06) removes the operation status strip from the
repository card. Karan's two reasons hold:

- the strip restated Backup and Check from a different source than the card's
  key stats, which contradicted the card for repositories backed up outside
  Borg UI (#935);
- every mounted strip polled `GET /repositories/{id}/status-strip` every 30 s,
  and that route ran two `operations` queries plus one legacy-table query per
  cell, roughly 15 to 18 queries per repository per refresh.

What we wanted to keep is the information, not the strip. In the thread Karan
proposed the shape himself: keep the values "in the same format" as the
`Last Compact` entry the card already has, in one row instead of a second one.

Since then the evidence model landed as upstream **#967**
(`app/services/operations/repository_status.py`, `GET /repositories/{id}/status`,
`/status-strip` served from it as an alias). Karan reviewed it on 2026-09-08
and, in his point 2, named the per-card poll again: the model now reads the
archives table on every poll. That makes the data-path fix urgent on its own.

Fork state that matters:

| Branch / PR | Relation to the strip machinery |
|---|---|
| upstream #967 (`feat/repository-status-model`, head 523a66c6, content-identical to the io/integration pin d4687b21) | the only consumer: imports `latest_legacy_terminal` from `legacy_status.py` and `anomalies.OVERDUE_THRESHOLD_DAYS`; already dropped `anomalies.overdue()` |
| fork #56 rework (`feat/borg2-compact-stats-ops`, compact `--stats` on the operations runner) | none. It writes `repositories.last_compact` and the stats; the card's `Last Compact` reads that column. #937 does not touch any file #56 touches |
| upstream #948, #949, #966, #968 | none |

So the question "does #56 still need the machinery" is answered: no. The only
thing #937 would break is #967, and #967 is where the replacement lives.

## 2. Goals

1. No second row on the card; the strip, its route and its polling go.
2. `Last Prune` and `Last Index` appear in the card's metadata row after
   `Last Compact`, same format, same `Never` state, full timestamp as tooltip.
   Backup and Check are already key stats; Mirror is already the rclone badge.
   Prune and Index are the only strip cells without a home.
3. One data path per page, not per card: the values ride in the repositories
   list payload, computed once for all listed repositories, refreshed by the
   SSE stream instead of a timer.
4. Row and `GET /repositories/{id}/status` read the same evidence rules, so the
   contradiction of #935 cannot reappear between the row and the route.
5. No new route, no new columns, no migration.

## 3. Design

### 3.1 Backend

New function in `app/services/operations/repository_status.py` (the #967
module), working on a set of repositories:

```
last_runs(db, repositories) -> dict[int, LastRuns]
LastRuns = { last_prune: datetime | None, last_index: datetime | None }
```

- Eight queries for the whole page, restricted to the listed ids: grouped
  `max(completed_at)` for `operations` kind `prune` (dry runs excluded by
  `params.dry_run`), `prune_jobs`, and `operations` category `index`, each
  over `SUCCESS_STATUSES` (`completed`, `completed_with_warnings`); one
  page of `REMOVAL_CANDIDATES` (32) listings per repository that reported
  removed archives, by window function, with the next page read only for
  repositories whose whole page was explained; the listing before each
  window; and, per deletion table (`delete_archive` and, from phase 6,
  `wipe` operations in any terminal status, legacy `delete_archive_jobs`,
  `repository_wipe_jobs` that started their delete phase), the first
  listing at or after each deletion inside the window as a correlated
  minimum. On PostgreSQL the array length sits behind a `json_typeof`
  CASE so a non-array value cannot fail the statement. Nothing is decoded
  in Python. A failed or cancelled run does not move a "last" value; that
  matches the `last_check` and `last_compact` columns, which only
  successful completions stamp.
- The removal listing is found by a SQL-side test on the JSON list's
  length (`json_array_length`, spelled per dialect for SQLite and
  PostgreSQL; a Postgres-gated unit test holds the second spelling, and CI
  sets `BORG_TEST_POSTGRES_URL` in every unit shard). #967's
  `latest_removal` decoded results row by row in Python, newest first,
  which for a repository that never prunes walked every listing in
  retention; the SQL form replaces it for the status route as well.
- Prune uses #967's precedence: removal evidence stands unless a Borg UI
  prune is newer. New in this PR, shared by the status route's prune cell
  (`prune_removal_evidence`): a deletion or wipe explains the first
  listing after it, that listing is skipped and the next older unexplained
  one counts, so one archive deleted from the Archives page neither reads
  as "Last Prune: today" nor turns a nightly cron prune into "Never". A
  prune dry run (a completed `prune` operation with `params.dry_run`) is
  not prune evidence either; the v1 route records the preview as such an
  operation, the v2 route records nothing.
- Index = newest successful operation of category `index`, as the strip
  showed it. Whether it should mean `archive_sync` only is the one question
  left open with Karan (section 6).
- `legacy_status.py` gains the grouped variant for `prune_jobs`; the
  single-repository function that #967's `job_evidence` uses stays. The
  file thereby keeps a live importer, which was #937's stated reason for
  deleting it.

`GET /repositories/` (`app/api/repositories.py`, `get_repositories`) calls
`last_runs` once before its per-repository loop and adds two payload fields,
formatted like the neighbours. When the computation fails the two keys are
left out (and the transaction rolled back), so the card shows no entry
rather than "Never" and the list is still served:

```
"last_prune": format_datetime(runs.last_prune),
"last_index": format_datetime(runs.last_index),
```

Removed, as in #937: the `/status-strip` route and `STRIP_CELLS` (already
replaced by #967's `CELLS`; the alias route goes), `docs/api.md` row, the
Postman request, `TestStatusStrip`. Kept: `GET /repositories/{id}/status`
and the whole evidence model, as the per-repository contract for the dialog
unification of #935. It is no longer polled by anything.

### 3.2 Frontend

- `RepositoryCard.tsx`: two `metaItems` entries directly after
  `repositoryCard.lastCompact`, built exactly like it (`formatDateShort`,
  `common.never`, `formatDateTimeFull` tooltip), rendered only when the
  payload carries the field: a backend that predates it (a remote target
  on an older version) sends nothing, and nothing must not read as "Never".
  Remove the `OperationStatusStrip` import and render.
- `types/index.ts`: `last_prune?: string | null`, `last_index?: string | null`
  on `Repository`.
- Locales, all four, key-parallel: `repositoryCard.lastPrune`,
  `repositoryCard.lastIndex`. Remove `operations.strip.*` and the now-dead
  `operations.background.never` / `operations.background.syncing` (verified
  on main 323fc784: the strip is their only reader).
- Remove `OperationStatusStrip.tsx`, its story and test, `archivesAPI.getStatusStrip`,
  the `StatusStrip*` types in `types/operations.ts`, the strip case in
  `services/__tests__/api.test.ts`. Update the comment in
  `useOperationEvents.ts` as #937 does (the connection cap is the reason for
  sharing, not the strip).
- Freshness: `Repositories.tsx` subscribes with `useOperationEvents` and
  invalidates `['repositories']` on successful completions of category
  `index` and kind `prune` (a deletion shows through its index follow-up;
  check and compact move nothing on the card; failed runs move nothing
  either), debounced by 2 s because index chains finish in bursts
  (`stats`, `archive_sync`, `history_merge`), with a 10 s maximum wait so
  a nightly window where chains end back to back still refreshes. Without
  this, `Last Index` would be stale until the next focus refetch, since
  the list query has no interval.

### 3.3 Spec and docs

- Spec 10.2 (`docs/engineering/specs/2026-09-03-repository-operations-and-archive-history.md`)
  is rewritten as "moved into the card's metadata row": the evidence model
  from #967 stays as the section's core, the strip paragraph becomes the
  history, and the row is described as its rendering. #937's edits to the
  surrounding sections (2 scope list, glossary, 9.2 route table, 9.4 SSE
  consumers, 11.x, 18 file table, Appendix B decision, 19.1 phase 3 row)
  are carried over with the wording adjusted from "withdrawn" to "moved".
- `docs/api.md`: drop the `/status-strip` row; the repositories list row
  mentions the two new fields.
- `docs/architecture/job-system.md`: check for strip mentions at build time.

## 4. Cost

| | Before | After |
|---|---|---|
| Per card, per 30 s | 1 request, 15 to 18 queries (#937's count), plus the archives window query of #967 | nothing |
| Per page load | list query as today | list query plus 6 grouped queries, no per-repository work, no JSON decoding in Python |
| Refresh trigger | timer per card | SSE terminal event, debounced, one list refetch |

## 5. Sequencing

1. Wait for Karan's answer on #937 and for #967 to land on main. The
   replacement touches `repository_status.py`, `archive_index.py`,
   `test_api_archive_index.py` and spec 10.2, all of which #967 changes;
   building on top of its branch and rebasing after the merge avoids a
   three-way conflict.
2. Branch from `upstream/main` (or stacked on `feat/repository-status-model`
   until then), name `refactor/status-strip-into-card-row`.
3. Build backend, frontend, docs as in section 3, one commit.
4. Gates (all green on 2026-09-08 for commit `71d7ad81`, after six local
   review rounds plus CodeRabbit CLI; round 1: filter test, debounce maximum
   wait, removal scan in SQL, guarded list computation, spec Pro rows and
   SSE consumer list, deletion rule; round 2: wipe jobs as deletion
   evidence, rollback in the guard, absent fields not shown as "Never",
   Postgres test isolation, per-repository scoping test; round 3: dry-run
   prunes excluded, newest unexplained listing instead of only the newest
   one, Postgres test resets the shared schema like its siblings; round 4:
   cancelled wipe previews explain nothing (`started_at`), legacy delete
   jobs consulted, listing window bounded, fields omitted on failure,
   refetch on successful runs only; round 5: deletions in any terminal
   status count, explained pages turn to the next page instead of "Never",
   `json_typeof` guard on PostgreSQL, one reload instead of N refreshes
   after the rollback, running prune previews still show as running,
   deletion window bounded on both sides; CodeRabbit: timer capped at the
   maximum wait, `threshold_days` and `age_seconds` in the 10.2 and 9.2
   contracts, both entries disabled for index mode `off`, phase
   attribution of the card row; round 6: ids captured before the rollback,
   page cap, route test for the dry-run exclusion, paging test that
   discriminates): backend unit suite in a scratch checkout
   (`pytest tests/unit`);
5. PR body: supersedes #937, cites Karan's point 2 on #967, the cost table
   above, the spec amendment. Ask Karan to close #937 in favour of it.
6. Afterwards: io/integration is rebuilt on main plus the open PRs as usual;
   the k8s-borg pin moves only on Benjamin's word. No agent change, no chart
   change, no migration, so no tag is needed for this PR alone.

## 6. Open points

- **`Last Index` semantics**: whole `index` category (strip parity, proposed)
  or `archive_sync` only (the listing that refreshes the archive table).
  Asked on #937; category parity unless Karan prefers the listing.
- **Overdue in the row**: deliberately none. The row shows dates; "is this
  repository behind" stays with the dashboard and, per repository, with
  `GET /repositories/{id}/status` and its `overdue` per cell. If a badge is
  wanted on the card later, it belongs in the same list payload, as Karan
  wrote in #937.
- **External prune** (Karan's third worry): the row inherits #967's removal
  evidence, so a repository pruned from cron shows the removal date, not
  `Never`. Compact and Check keep their job-row-only nature; the card's
  existing `Last Compact: Never` for external compacts is unchanged and
  honest, since Borg records no compact timestamp in either version.

## 7. Verification after deployment

- Card of a repository backed up and pruned outside Borg UI: `Last Prune`
  shows the date of the listing that saw archives disappear; `Last Index`
  shows the newest index run; no strip.
- Card of a plan-driven repository: `Last Prune` equals the plan's last prune
  completion; a failed prune afterwards does not move it.
- Network tab on the repositories page: no `/status-strip` or `/status`
  requests; one list request per page load and per terminal SSE event burst.
- A repository with zero prune and index history shows `Never` in both
  entries, as `Last Compact` does today.
