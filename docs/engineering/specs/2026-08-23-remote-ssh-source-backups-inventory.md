# Remote SSH Source Backups: Inventory, Scope, and Options

## Status

Proposal for decision. Written while working through the issue series
#834–#839 (Navino16, 2026-08-20) against `main` at `3b4de76c`.

Already addressed from that series, each as its own PR:

| Issue | Problem | PR |
| --- | --- | --- |
| #836 | remote path mapped borg warning exits to `failed` | #843 |
| #837 | `VAR=… sudo borg` loses the environment to `env_reset` | #844 |
| #838 | no borg output stored, passphrase logged in clear | #845 |
| #839 | FUSE/SSHFS requirement undocumented where users land | #846 |

Still open from the series: #834 (`is_backup_source` cannot be enabled from the
UI) and #835 (`use_sudo` applied to `create` only). Related older issues: #783
(remote repository creation expects Borg on the remote host), #760 (AppArmor
denies `fusermount3` on Ubuntu).

This document is about #834 and the question behind it: how much more should
be invested in the server-orchestrated SSH source paths, given that the
managed agent exists.

## Context: three ways to back up another machine

Borg UI can back up data that lives on a different host in three ways. They
differ in where `borg create` runs and what the Borg UI server must be able to
do on the source host.

### 1. SSHFS pull mode

The server mounts the remote filesystem with SSHFS inside the container and
runs `borg create` itself. Route strategies `server_sshfs_pull` and
`server_sshfs_pull_then_borg_ssh` in `app/services/backup_route_planner.py`.

- Needs FUSE access in the container (`/dev/fuse`, `SYS_ADMIN`, AppArmor
  exception, or `privileged: true`) — #839/#846, #760.
- All source data flows through the Borg UI host; high-I/O reads happen over
  the network before borg ever sees them.
- Filesystem semantics are SSHFS semantics: symlink fidelity had to be
  repaired (#764), ownership and special files are approximations.
- Needs the server's SSH key accepted on the source, with read access to
  everything that should be backed up; `use_sudo` runs the remote
  `sftp-server` through sudo to widen that.

### 2. Remote Direct Backup (`execution_mode=remote_ssh`)

The server SSHes into the source host and runs `borg create` there, pushing to
an SSH repository. Route strategy `remote_direct`; chosen only when the plan's
sources are all `remote` on one connection **and** the repository is an SSH
repository on that same connection.

- Needs Borg installed on the source host, at a path the server knows.
- Needs the server's SSH key accepted on the source; with `use_sudo`, needs
  passwordless sudo that also preserves `BORG_*` (#844).
- The server holds the repository passphrase and hands it to the remote
  process on the command line (redacted in logs since #845).
- `use_sudo` is honored by `create` only; `list`/`prune`/`check`/`restore`
  connect as the plain user, so a sudo-created repository is unreadable
  afterwards (#835, open).
- Only `borg create` is delegated; restores, checks, prunes run server-side
  against the SSH repository.

### 3. Managed agent

`borg-ui-agent` runs on the source host, connects **outbound** to Borg UI,
executes borg locally and streams progress and logs back (`docs/managed-agents.md`).

- No inbound SSH to the source, no server key on the source, no FUSE, no
  sudo plumbing: the agent runs as a chosen service user (installing user,
  dedicated user, or root) with the privileges it needs and nothing else.
- Warning semantics (#774), log streaming, restore and restore-check
  delegation (#730), repository operations (#745), pre/post scripts (#750),
  unprivileged whole-machine backups (#766), installer version parity (#802)
  are all already there.
- Cost: one more component per source host, outbound reachability to the
  Borg UI URL, and Borg on the host (the installer handles that).

The table below is the same comparison, feature by feature, as of `main`:

| Concern | SSHFS pull | Remote direct | Managed agent |
| --- | --- | --- | --- |
| `borg create` runs on | server | source host | source host |
| Server needs SSH into source | yes | yes | no |
| Container privileges | FUSE set or `privileged` | none | none |
| Root-owned source paths | `use_sudo` on sftp-server | `use_sudo` (create only, #835) | service user choice |
| Warning exit semantics | yes | yes since #843 | yes (#774) |
| borg output kept | yes | yes since #845 | yes (streamed) |
| Restore runs on | server (SSHFS) | server | agent (#730) |
| Repository ops (prune/check/compact) | server | server (as plain user) | agent (#745) |
| Symlink/ownership fidelity | SSHFS (#764) | native | native |
| Passphrase leaves the server | no | yes (remote argv/env) | yes (job payload) |

## Inventory: what `is_backup_source` is today (#834)

### Data model

`SSHConnection` has `is_backup_source`, `borg_binary_path`, `borg_version`,
`last_borg_check` (migration 044, Phase 1 of remote backups) and `use_sudo`
(074). `remote_backup_service.execute_remote_backup()` refuses to run unless
`is_backup_source` is true:

```
SSH connection {id} is not enabled as backup source
```

raised as a bare `Exception`, so the job fails with that text and no hint where
the flag lives.

### API

The mainline connection API does not know the flag:

- `GET /api/ssh-keys/connections` returns `use_sftp_mode`, `use_sudo`,
  `default_path`, `ssh_path_prefix`, `mount_point`, status fields — **not**
  `is_backup_source`, `borg_binary_path`, `borg_version`, `last_borg_check`.
- `PUT /api/ssh-keys/connections/{id}` (`SSHConnectionUpdate`) accepts
  `use_sftp_mode`, `use_sudo`, paths — **not** the flag, **not** the path.

A separate side API exists for it, router-authorized like everything else:

- `PATCH /api/ssh-keys/connections/{id}/backup-source?enable=true|false` —
  on enable runs `verify_remote_borg()` (an SSH round-trip executing
  `<borg_binary_path or /usr/bin/borg> --version`), stores `borg_version`,
  `borg_binary_path`, `last_borg_check`; 400
  `backend.errors.ssh.cannotEnableAsBackupSource` when Borg is not found.
- `POST /api/ssh-keys/connections/{id}/verify-borg` — the verify alone.
- `GET /api/ssh-keys/connections/backup-sources` — the enabled connections.

### Frontend

Zero references to any of the three side endpoints, to `is_backup_source`, or
to `borg_binary_path` in `frontend/src`. The Edit Remote Machine dialog
(`pages/ssh-connections-single-key/dialogs/EditConnectionDialog.tsx`) offers
exactly two checkboxes, *SFTP deployment mode* and *Use sudo*, both saved
through the PUT.

### Consequences

1. A connection created and tested in the UI has `is_backup_source = 0`; the
   first remote-direct run fails with the message above; the only way out is
   the PATCH via curl (Navino's workaround) — or reading the source.
2. `borg_binary_path` is never user-settable. `verify_remote_borg()` honours a
   preset path, but nothing presets it; it only ever stores the path it just
   probed, i.e. `/usr/bin/borg`. The documented "use the connection's Borg
   binary path for a wrapper script" (`docs/ssh-keys.md`, Remote Direct
   Backups) has no UI or API behind it, and a host with Borg under
   `/usr/local/bin` (pip install) cannot be enabled at all.
3. The enable verify demands Borg on the remote host even for connections
   that will only ever be SSHFS pull sources, where no remote Borg is invoked
   (Navino's point 2; the same expectation blocks remote repository creation
   in #783).

## Scope question

The narrow reading of #834 is "add a checkbox". The honest reading is that
Phase 1 of remote backups (migration 044, January 2026) was built backend-first and never wired
to the UI, and that the remote-direct path accumulated a cluster of defects
(#835–#838) that the agent path solved by design. Before adding UI, decide how
much of this path should remain a first-class feature.

## Options

### A. Minimal UI wiring

Checkbox in the Edit dialog that calls the existing PATCH when toggled; list
endpoint gains the four fields so the checkbox can show state.

- Pro: smallest diff, no API semantics change.
- Con: the checkbox cannot ride the existing PUT mutation — a second mutation
  with its own error path, only when the value changed; `borg_binary_path`
  stays unsettable; the verify keeps blocking pull-mode sources.

### B. Extend the mainline API, keep the side API as a façade

`GET` returns the four fields; `SSHConnectionUpdate` gains
`is_backup_source: Optional[bool]` and `borg_binary_path: Optional[str]`.
When the PUT flips the flag to true it runs the verify **before applying any
field** (with the path from the same request, if given) and returns the
existing 400 on failure, so a PUT is all-or-nothing. One helper implements
"enable" (verify → flag, version, path, timestamp); the PUT and the old PATCH
both call it. PATCH/verify-borg/backup-sources stay for existing scripts.

- Pro: the frontend becomes a plain checkbox plus an optional "Borg binary
  path" field on the existing form and mutation; wrapper paths and
  non-default install locations start working; fully unit-testable without
  a browser (Pydantic model, PUT behaviour with a mocked verify, response
  fields, helper dedup).
- Con: still invests in the remote-direct path; the verify still blocks
  pull-mode-only sources unless combined with C.

### C. Decouple the flag from the Borg verify

`is_backup_source` becomes a plain consent flag ("this machine may be used as
a backup source"). Borg presence is verified when it matters: when a plan
would route `remote_direct` (at plan save, surfaced in the wizard) or lazily
at run time with a clear error. SSHFS pull sources enable without remote Borg.

- Pro: matches what the docs describe as the default (pull mode); removes
  the #783-shaped confusion; composes with B.
- Con: a product decision about what the flag means; changes the contract of
  the PATCH (no longer verifies) unless kept as "enable and verify".

### D. Set the flag implicitly when a connection is chosen as a plan source

Navino's second suggested expectation. The wizard marks the connection as a
source on save; verify runs there if the route will be remote-direct.

- Pro: no separate switch to forget.
- Con: a plan save silently changes connection-level state; wizard work on
  top of B/C; the flag as a concept becomes vestigial — if going this far,
  drop it rather than auto-set it.

### E. Steer to the managed agent; keep remote SSH as the documented edge path

Make the message actionable (`enable this connection as a backup source under
Remote Machines → Edit`), document that remote SSH source backups are the
path for hosts that cannot run an agent, and recommend the agent for
everything else in `docs/ssh-keys.md`, the plan wizard's source step, and the
Remote Machine card. Do A or B only as the minimum that stops the feature from
being unreachable.

- Pro: honest about where the platform's design effort went; a user like the
  reporter (Debian/Raspberry Pi hosts, Docker workloads, root-owned config,
  dangling container symlinks) gets everything #834–#839 asked for and more
  from one install command, without FUSE, sudo, or the server's key on the
  host.
- Con: not what the issue literally asks; requires saying so in the reply.

## Recommendation

E as the stance, with B as the engineering change, and C put to the owner as
an explicit question rather than decided in passing.

Reasoning:

- What the remote-direct path asks of an installation — the server's SSH key
  on every source, often with passwordless sudo, the repository passphrase
  travelling to the remote command line, FUSE privileges for the pull
  variant — is exactly the inversion the agent was built to avoid: the backup
  server should not need root-equivalent reach into every machine it protects.
  A backup design where compromise of the coordinator implies compromise of
  every source is questionable on its own terms; the agent's outbound,
  per-host enrollment is the better answer for a user with several Linux
  hosts.
- The remote SSH paths still have a place: NAS appliances and hosts that
  cannot run Python or a service, and the "repository on the same box as the
  source" case. They should work and be honest about their requirements —
  which is what #843–#846 did — but they should not be where new design
  effort goes.
- B is the smallest change that makes the flag reachable *and* removes a
  documented-but-impossible setting (`borg_binary_path`); it is testable
  without a browser, and leaves the UI as two ordinary form fields that the
  owner can add in minutes or that can follow in a second PR.
- C decides whether pull-mode-only sources must host Borg. That is the
  owner's call; it should be asked in the #834 reply, not buried in a PR.

## Proposed next steps

1. Reply on #834 with this inventory in short form: what is missing, that
   `borg_binary_path` is not settable either, the agent recommendation for
   the reporter's setup, and the C question.
2. If the owner wants the path kept: PR for B (backend, tests, the actionable
   error message, docs), UI fields as a follow-up or by the owner.
3. #835 (`use_sudo` on list/prune/check/restore) stays open: the consistent
   fix is either honoring `use_sudo` everywhere the repository is touched or
   refusing `use_sudo` on remote-direct sources; both are larger than #834
   and both are moot under the agent. Decide with #834.

## Open questions

- Should `is_backup_source` require Borg on the remote host, or only when a
  plan will actually run `borg create` there (option C)?
- Is remote-direct mode meant to stay a first-class path, or the edge path
  for hosts that cannot run an agent? The answer decides whether #835 is worth
  fixing across five services.
- Should the plan wizard's source step point at managed agents when a user
  picks an SSH connection as a source?
