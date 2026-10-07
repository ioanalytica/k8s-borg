# Changelog

## Unreleased

* **The chart README explains how to apply a changed Secret** (#27). The
  reconcile Job runs once per Helm revision, so a changed Secret referenced
  through `existingSecret` (a notification password, the OIDC client secret,
  the license) reaches Borg UI only with the next revision. The new section
  *Changing a referenced Secret* gives the `helm upgrade` and
  `flux reconcile … --force` commands and notes that the agent pods roll.
* **S3 sources list every file again.** The image's s3fs 1.97 (Alpine's
  package) showed only two entries of a directory without a directory object
  of its own, which is how rclone and most S3 writers leave directories,
  once that directory's stat cache entry had expired (15 minutes by default):
  the check that recognizes such a directory stored its two-key probe as the
  directory's listing. Borg then archived those two files. This hit
  long-lived mounts (the app pod) and any backup walk that reached a
  directory more than 15 minutes after listing its parent. The image now
  builds s3fs 1.97 from the release with the upstream fix (s3fs-fuse #2929,
  not yet in a release) instead of installing the package.
* **Cluster backups check the S3 mounts first.** Before `borg create`, each
  mounted bucket's files are compared with the bucket's listing through the
  S3 API (rclone). A bucket whose mount misses objects, or that is no longer
  mounted, is mounted again and checked once more; if objects are still
  missing, the backup is written anyway and the run fails, naming the bucket
  and some of the missing keys.
  `s3.verifyListing: false` switches the check off.

### Upgrade notes

* New value `s3.verifyListing` (default `true`). Each check costs two
  listings of the bucket through the S3 API and one walk of its mount, once
  per cluster run; a bucket that is mounted again is checked again, which
  repeats all three.
* A run that fails the check exits with an error after archiving, so the
  CronJob's pod restarts it (`backoffLimit: 5`) with a new mount.

## 1.1.9-beta.8

* **Borg UI follows upstream main: 2.3.10-34-g49099c8c0, agent 0.1.20.**
  The `borg-ui` submodule moves from cdd5712c9 to upstream main 49099c8c0.
  Borg 1.4.5 and Borg 2.0.0b25 are unchanged (same runtime base), and so is
  the database schema (Alembic head c8e1f4a7b2d9).
* **Usage analytics no longer go to Umami.** Borg UI's usage analytics
  (page views and feature usage, with hashed instance and user keys) now go
  to the Borg UI project's own ingest service, described in borg-ui's
  `docs/trust.md`. They start on for every user: a banner on first login
  asks whether to keep them, and page views from before the answer are
  sent. Declining, or switching analytics off in Preferences, stops them;
  the banner answer and the switch-off are each sent as one event.
* CI runs on Ubuntu 26.04 with Helm 4.3.0 pinned; the chart and the image
  contents are not affected.

### Upgrade notes

* No value changes; the rendered manifests differ only in the image tags.
* The UI image tag is `2.3.10-34-g49099c8c0`; the UI itself still shows
  2.3.10.
* Managed agents get an upgrade offer from 0.1.19 to 0.1.20; the pods' agent
  comes with the 1.1.9-beta.8 agent image. 0.1.20 changes only the macOS
  installer; agents on Linux get the new version number and nothing else.
* Repository updates through the API refuse keys Borg UI does not apply
  (HTTP 422) instead of ignoring them. `register-repo` sends only the path
  when it moves a record and is not affected.
* Usage analytics stay as each user set them. A user who never answered the
  banner, and every new user, has them on until declining.
* Borg UI accepts only 1 or 2 as a repository's Borg major (an unset one
  still counts as 1); another value used to run as Borg 1 and is now
  refused. `register-repo` sends `borg.version` as the major, so a value
  other than 1 or 2 now fails the registration.

### Borg UI changes since the previous pin

* A repository update reports what it stored: unknown keys are refused, the
  edit form no longer sends the Borg major and encryption, a changed path is
  initialized only when the new location holds no repository, a locked or
  unreachable repository is refused instead of initialized over, and a
  refused update keeps the old name (#1359).
* Agent 0.1.20: a macOS install puts the directories where it found `borg`,
  `borg2` and `rclone` on the launchd jobs' PATH, so a Borg installed outside
  the fixed directories is found (#1355).
* Prune preview for Borg 2: no size ranking, no per-candidate re-measure, and
  "Space freed" reads "not available", since Borg 2 reports no size a
  deletion would free (#1362).
* Usage analytics move from Umami to Borg UI's own ingest (#1206, see above).
* The server refuses a Borg major other than 1 or 2 instead of running it
  as Borg 1 (#1347).
* Frontend dependency updates (#1335); visual snapshot CI (#1364).

## 1.1.9-beta.7

* **Borg UI follows upstream main: 2.3.10-27-gcdd5712c9, agent 0.1.19.**
  The `borg-ui` submodule moves from our integration branch (54ee5563, UI
  2.3.8, agent 0.1.17) to upstream main cdd5712c9, which contains everything
  that branch carried. Borg 1.4.5 and Borg 2.0.0b25 are unchanged (same
  runtime base), and so is the database schema (Alembic head c8e1f4a7b2d9).
* **The UI image tag names the pinned commit.** `borgUI.image.tag` is
  `git describe` of the pin (`2.3.10-27-gcdd5712c9`); a plain `X.Y.Z` only
  when the pin is exactly the release tag `vX.Y.Z`. borg-ui's `VERSION` file
  says 2.3.10 for every main commit since that release, and a tag reused for
  a new pin overwrote the image an older chart still pointed at.
  `docker/ui-app-version.sh` computes the string for CI and
  `docker-build-server.sh`; the release fails when the chart names another.
* **New value `borg.encryption`**, the mode of the repositories the pods
  create (empty = the major's default: `repokey-blake2` for Borg 1,
  `repokey-aes-ocb` for Borg 2). A mode the chosen `borg.version` lacks fails
  the render with the valid list. Keyfile modes are refused for now: their
  key would live in the pod and be lost on restart (#20). An existing
  repository is never touched.
* **New value `borgUI.notifications`**: the reconcile Job creates or updates
  Borg UI notification channels by name. An `email` entry is assembled from
  relay, login, sender and recipients with the password from a Secret; any
  other Apprise service takes its whole URL from a Secret (`serviceUrl`).
  Only the settings an entry names are enforced, channels under other names
  are never touched, nothing is deleted. Failures are warnings; the Job still
  completes.
* **`register-repo` records the mode `borg-init` created.** Borg 2
  repositories were recorded as `repokey-blake2` (a Borg 1 name); they are
  now recorded under Borg UI's name (`repokey-aes-ocb` by default,
  `authenticated` for `authenticated-sha256`). `borg-init` and
  `register-repo` share the mapping in `borg-encryption.sh`.
  `authenticated-blake3` is refused: Borg UI has no name for it.
* **A pod moves its own record to a changed `BORG_REPO`.** After a change of
  the repository base the pod used to find its old record by name and keep
  working on the old URL. Now it sends the new path to Borg UI and requests
  a resync, as long as the record belongs to this node's agent, has the same
  Borg major and the same encryption mode, and the new path is `ssh://`.
* **`borg-init` blames a repository it cannot reach on the repository.**
  Borg 2's run-time errors (denied key, refused path, host down) were
  reported as "a bug in borg-init"; only a first line `usage: ` now counts as
  a rejected command line.
* **`borg-mount` no longer leaves a Borg 2 process behind after the
  unmount.** Borg 2 now mounts in the foreground of its own session and
  `borg-mount` returns once the mount is up; `BORG_MOUNT_TIMEOUT` (seconds,
  default 300) ends a mount that does not come up.

### Upgrade notes

* `borg.encryption` and `borgUI.notifications` are empty by default; with
  both empty the rendered manifests do not change.
* A pod now **stops at start with a message** naming both sides where it
  used to carry on silently: a record with its name but another path that
  belongs to another agent or to none, has the other Borg major, or a local
  `BORG_REPO`; `BORG_REPO` held by another record; Borg UI refusing the move;
  and a move whose record carries another encryption mode. The last one hits
  every Borg 2 record registered by an earlier release (stored as
  `repokey-blake2`) as soon as the repository base changes: correct the
  record's mode, or remove the record without deleting data so the pod
  registers it anew. A pod whose record already has the path `BORG_REPO` is
  not affected.
* `BORG_ENCRYPTION=authenticated-blake3` now stops `borg-init` and
  `register-repo`.
* The UI image tag has the form `2.3.10-27-gcdd5712c9`. The UI itself still
  shows 2.3.10 (it reads borg-ui's `VERSION`); the full string is in the
  image tag and its `org.opencontainers.image.version` label.
* Managed agents get an upgrade offer from 0.1.17 to 0.1.19; the pods' agent
  comes with the 1.1.9-beta.7 agent image.

### Borg UI changes since the previous pin

* Repository wizard and archive views for Borg 2.0.0b25 (#1349).
* Managed agents are a Community feature; the license gate is gone (#1317).
* Agent 0.1.18: upload limit for Borg 2 repositories behind rclone (#1343);
  agent 0.1.19: `set-server` moves the upgrade record when it may write it
  (#1337); the reinstall dialog names this server for a moved endpoint
  (#1340); manual installs land where the service templates start the
  agent (#1339); disk usage measured portably on macOS (#1348).
* Agent repositories and Borgmatic imports record their Borg major (#1350).
* A backup reuses its live agent job instead of queuing a second (#1341); a
  refused agent job keeps its parameters in background jobs (#1338).
* A repository command that times out ends its Borg child (#1342); a local
  repository directory that cannot be created answers 400 (#1356).
* `--patterns-from` and `--exclude-from` allowed in custom flags (#1319);
  the command preview shell-quotes path, sources and excludes (#1358).
* 422 responses no longer echo the submitted input (#1318).
* Await-less API handlers run in the threadpool, agent job completion I/O
  off the event loop (#1321–#1325).
* App templates for Vaultwarden, Plex, Paperless-ngx, Nginx Proxy Manager
  and Jellyfin (#1310).
* apprise 2.0.0 (#1334): notification URLs with the removed email options
  `use_pgp=`/`pgpkey=` or invalid settings now fail instead of degrading.

## 1.1.9-beta.6

* **New value `s3.region`**, the SigV4 region of the S3 endpoint. It reaches
  s3fs as `endpoint=<region>` (env `S3_REGION`). S3 servers that check the
  region, such as Garage, refuse every request s3fs signs for its default
  `us-east-1`. Empty keeps the s3fs options as before.
* **A bucket that does not answer now stops the pod's start.** s3fs reports
  success and leaves a mount behind even with a wrong region, wrong
  credentials, a missing bucket or an unreachable endpoint; the first access
  then blocks until s3fs is killed, while s3fs keeps polling the server. The
  new `s3-mount-bucket` lists every fresh mount within `S3_PROBE_TIMEOUT`
  seconds (default 30); on failure it removes the mount, ends s3fs and stops
  with the bucket, endpoint and region in the message.
* Borg UI unchanged: 2.3.8, agent 0.1.17.
