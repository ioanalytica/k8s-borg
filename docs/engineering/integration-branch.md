# Integration branch and database revisions

`borg-ui` is pinned to the fork's `io/integration` branch. The integration built
on 2026-09-12 combines upstream main `a19503fa` with PRs #1025, #1029, #1030,
and #1031. The original PR branches remain unchanged.

PR #1030 adds Alembic revision `a9b8c7d6e5f4`; PR #1031 adds `f2a3b4c5d6e7`.
Both descend from `e1f2a3b4c5d6`. Integration adds the no-op merge revision
`8c7d6e5f4a3b`, which depends on both and restores a single `head`.

## Future rebuilds and return to upstream

Once deployed, databases record `8c7d6e5f4a3b`. Keep its migration file and
ancestors available in later integration builds, even after the source PRs
merge upstream. Before changing the submodule pin, compare the deployed
revision with the target's complete Alembic graph and verify the upgrade on a
copy of the database. A fresh-install test alone does not cover this path.

Do not switch a database stamped with this integration revision directly to
an upstream checkout that cannot resolve it. Do not blindly stamp a different
revision: equivalent schemas and completed data migrations must be verified
first. An eventual handoff depends on the revisions actually merged upstream
and must be prepared explicitly, with a database backup and upgrade tests.
