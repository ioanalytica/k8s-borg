# Changelog

## Unreleased

* **Archive names in UTC.** The default archive name template is now
  `<node>-{utcnow:%Y-%m-%d-%s}` (was `{now:…}`) in `register-backup-plan`
  and `borg-backup`. `{now}` is local time, which repeats an hour when
  daylight saving time ends: a backup that runs again in the repeated hour
  gets the name of the one an hour before and fails with "Archive … already
  exists". On the Alpine images `{now:%s}` was also not the Unix time but
  the local wall time read as UTC. The `borg.archiveNameTemplate` comment
  recommends `{utcnow:…}` for custom templates. Existing archives keep their
  names; after the update the timestamps in new names move back by the UTC
  offset once.

* **rclone 1.75.2 in the agent image**, the current stable release, which
  includes the 1.75.1 fixes for CVE-2026-88013 to -88018 and CVE-2026-88044
  to -88046 (two of them critical: auth-proxy bypasses in `rclone serve s3`
  and the rc server). The image takes the official static build from
  downloads.rclone.org in a fetch stage instead of Alpine's package: Alpine
  3.24 ships 1.74.1 without fixes for these CVEs, and its `v1.74.1-DEV`
  build string kept scanners from reporting them. `docker/rclone.env` pins
  version and checksums (from the release's PGP-signed `SHA256SUMS`);
  `tests/rclone-pin.bats` keeps the Dockerfile's ARG defaults equal to it.
  The UI image's rclone comes from borg-ui's runtime base and moves to
  1.75.2 with the `borg-ui` pin.

* **Borg UI without `privileged` where FUSE allows it** (`borgUI.fuse`). The
  Borg UI server mounts through FUSE for server-side backups of SSH sources,
  cloud mirrors of SSH repositories and "Mount archive"; browsing and
  restoring do not need it. FUSE needs `/dev/fuse` allowed by the device
  cgroup, `SYS_ADMIN` and the setuid `fusermount3`, and containerd lets only
  privileged containers and devices assigned by a device plugin open
  `/dev/fuse` (a hostPath mount of it fails with "Operation not
  permitted"). So the UI keeps FUSE and stays privileged by default, and
  two new ways run it unprivileged:
  * `borgUI.fuse.deviceResource` names a FUSE device plugin's resource
    (e.g. `squat.ai/fuse`). The UI pod requests one unit and runs with
    `capabilities.drop: [ALL]` plus `CHOWN`, `DAC_OVERRIDE`, `FOWNER`,
    `SETGID`, `SETUID`, `SYS_ADMIN`, privilege escalation for
    `fusermount3`, seccomp `RuntimeDefault` and AppArmor `Unconfined`
    (containerd's default profile denies `mount`). The reconcile Job does
    not request the device.
  * `borgUI.fuse.enabled: false` drops FUSE: the same capabilities without
    `SYS_ADMIN`, no privilege escalation, seccomp `RuntimeDefault`. The three
    FUSE features then fail, and so does `sudo` in the container, which
    package install commands such as `sudo apt-get` rely on; everything
    else works.

  Both profiles were checked against the published `k8s-borg-ui:2.4.0`
  image: the server starts and logs in with either, `borg mount` works
  with the device profile, and fails without `SYS_ADMIN`, with
  `no-new-privileges` or with `/dev/fuse` only bind-mounted.
  `borgUI.containerSecurityContext` now defaults to `~`; a value you set
  still replaces the computed one, and an explicit `{}` still renders no
  securityContext, so existing releases render unchanged.

## 1.1.9

* **Borg UI 2.4.0.** The `borg-ui` submodule moves to the v2.4.0 release.
  The agent version stays 0.1.21 and the database schema is unchanged.
* **Agent version between Borg UI releases** (#77). When the `borg-ui` pin
  lies past a release and changed the agent, both images carry the agent
  version with the pin's distance from that release appended (Borg UI
  2.3.10-64-g… → agent 0.1.21.64), so enrolled agents are offered the new
  code.
* **Credentials resolver image: `alpine/kubectl:1.37.1`.** The init
  container that resolves `secretRef` database credentials defaulted to
  `bitnamilegacy/kubectl:latest`, a frozen mirror that no longer gets
  security fixes and whose `latest` tag cannot be tracked. Its script is now
  POSIX sh and runs in BusyBox's ash, so the default is the small, maintained
  and version-pinned `alpine/kubectl`. A `databases.credentialsResolver.image`
  of your own needs `kubectl`, `sh`, `base64`, `od` and `awk`; Bash is no
  longer required.

## 1.1.9-rc.1

* **Borg UI 2.3.10-62-ga7219d4d6.** The `borg-ui` submodule moves back to
  upstream main (a7219d4d6). Agent 0.1.21 and the database schema are
  unchanged.

## 1.1.9-beta.13

* **Borg UI unchanged:** 2.3.10-52-g2e4031646 (the beta.12 pin), agent
  0.1.21, database schema unchanged.
* **Database dumps for every common engine, the cluster datastore, SQLite on
  application volumes, and an external copy of the repository server.** The
  agent image gains `etcdctl`/`etcdutl`, MongoDB's `mongodump`/`mongorestore`,
  the MySQL 8.4 client, `valkey-cli` and the helpers below. Node backups stay
  on the node's own file systems.
* **License: AGPL-3.0-only throughout** (#44). The chart's SPDX headers and
  `Chart.yaml` said Apache-2.0 while the repository's `LICENSE` was the
  AGPL-3.0; all of them now say `AGPL-3.0-only`. The README describes what the
  chart deploys today and lists the licenses of the third-party software in
  the images.
* **Repository server: an external copy, `repoServer.offsite`** (issue #54).
  * A CronJob mirrors every repository below the data directory to an rclone
    remote — S3-compatible storage, an SFTP target such as a Hetzner Storage
    Box, or any other — for the case that the server's storage fails. Off by
    default. A mirror, not a second backup: deletions and compactions reach
    the copy with the next run.
  * `borg-offsite-copy` copies one repository at a time; one that does not
    exist locally is never touched on the remote, so a server on a new, empty
    volume does not empty the copy. No lock and no passphrase: Borg 2 seals
    its locks with the repository key. Each repository is copied in Borg's
    write order (segments or packs, then what refers to them, then the
    deletions) and copied again when a client wrote to it or held a lock
    meanwhile; a run that cannot settle a repository fails, the others are
    copied all the same.
  * The job reads the server's volume read-only, as the server's user, on its
    node, without root or capabilities. `rcloneConfig`, `sshKey` and
    `knownHosts` each from a value or an existing Secret; `schedule`,
    `timeZone`, `suspend`, `bwlimit`, `transfers`, `retries`, `extraArgs`.
  * `chart/README.md` describes the restore: the server rebuilt from the copy
    (with umask 077 — rclone leaves the files readable for everyone), Borg 1
    clients that saw a newer state, and reading a copy directly with Borg 1
    and Borg 2 for each kind of target.
  * Tested end to end against Garage and an SFTP target that runs `borg
    serve`, for Borg 1 and Borg 2.

* **Redis and Valkey: consistent RDB snapshots** (issue #52).
  * New engine `databases.redis` (off by default), for Redis and Valkey
    alike: instances with a static key=value `config` (`host`, `port`,
    `user`, `password`, `tls`, `cacert`, `insecure`), an `existingSecret`,
    or a `secretRef` resolved by the credentials resolver; the default user
    when no user is set.
  * `backup-redis` streams the server's own RDB snapshot over the
    replication protocol: `<instance>.rdb` of a standalone server, or one
    `<instance>-slots-<range>.rdb` per primary of a cluster with
    `<instance>-cluster-nodes.txt`. Mode 600, no extra compression, every
    failure rc 2. A failed dump leaves the previous one in place: a
    cluster's files are renamed into place one after another once all are
    complete, so only a failing rename could leave a mixed set.
  * `redis-rdb-sync` does what `valkey-cli --rdb` does and tells a Valkey
    server its version, without which Valkey 9 cannot send a hash field with
    a TTL of its own. It makes every connection of a dump, `INFO` and
    `CLUSTER NODES` included, and with TLS checks the server's name: `host`,
    and a cluster's nodes by their announced hostname or their IP address.
    `valkey-cli` joins the image, for work from the console pod.
  * The backup user needs `+info +sync +replconf +cluster|nodes`. A restore
    places the RDB file as the server's `dump.rdb` and starts it; documented
    in `chart/README.md`, "Restoring Redis and Valkey", not scripted.
  * Tested end to end against Redis 7 and 8 and Valkey 8 and 9, standalone
    and as a cluster of three primaries.

* **CloudNativePG credentials** (issue #48). A `secretRef` to CloudNativePG's
  `<cluster>-superuser` Secret (`usernameKey: username`,
  `passwordKey: password`, `host: <cluster>-rw.<ns>.svc`) works as it is; the
  chart README gains a table of the PostgreSQL operators' Secrets, and
  `values.yaml` an example. Tested against CloudNativePG 1.30.1 with the
  superuser, a managed role with `pg_read_all_data` and the application
  owner.

* **Credentials resolver: values passed as they are** (issue #61). Every
  instance value reaches the resolver's script as one single-quoted word: a
  `$(…)`, a backtick or a `$VAR` in a host or user no longer runs or expands
  in the init container. Secret values keep their trailing line breaks: the
  MariaDB and MySQL files write every value double-quoted with `\n`/`\r`
  escapes, which both clients read back; pgpass and MongoDB's file cannot
  carry a line break, and the resolver stops with the instance and field
  named, not the value. pgpass now also escapes `:` and `\` in host and port.

* **MySQL and Percona Server 8.4: `databases.mysql`** (issue #51).
  * A new engine, configured like `databases.mariadb` (static `config`,
    `secretRef` or `existingSecret`), off by default. `backup-mysql`,
    `backup-cluster-mysql` and `restore-mysql` dump and restore with MySQL's
    own client 8.4, shipped in `/opt/mysql` with the glibc it runs on (from
    the official `mysql:8.4.11` image, pinned by digest; about 29 MB, 10 MB
    compressed), in the files, modes and restore modes of MariaDB. The dumps
    carry no GTIDs.
  * Measured with the MariaDB client against MySQL 8.4: the dump succeeds
    without a warning, but every table with a generated column fails its
    restore (`ERROR 3105`), and the full dump copies system tables MySQL
    refuses and the source's GTIDs. `backup-mariadb` and `restore-mariadb`
    therefore fail with rc 2 against a MySQL server, and the MySQL scripts
    against a MariaDB server, naming the engine to use.
  * `tls: false` on a MySQL `secretRef` instance writes `ssl-mode=DISABLED`
    and `get-server-public-key`.
  * The image's MariaDB client gets its authentication plugins
    (`mariadb-connector-c`): before, it could not log in as a
    `caching_sha2_password` (MySQL's default), `ed25519` or `parsec` user.
  * An error of a MariaDB/MySQL backup or restore is reported once, not
    again by every subshell it ends.
  * Tested end to end against MySQL 8.4 and Percona Server 8.4 with GTIDs
    on, and against the Percona Operator for MySQL's Secrets.

* **Database dumps: the whole PostgreSQL instance, uncompressed dumps,
  `restore-mariadb`, only the configured engines, end-to-end tests** (issues
  #45, #46, #47, #55).
  * Only the engines a release configures are dumped: those with
    `databases.<engine>.enabled` and at least one instance or an
    `existingSecret`. One chart helper decides it; only these engines get
    their credentials volume, are published to the cluster agent and
    attached as pre-backup hooks (plan mode), and run in the cluster CronJob,
    which gets them as `BORG_DB_ENGINES` and runs the new
    `backup-cluster-databases` instead of every engine's wrapper.
  * `backup-postgres` dumps the instance as `pg_dumpall` covers it:
    `globals.sql` (roles, password hashes, memberships, role settings,
    tablespaces) and one `<db>.dump` (`pg_dump -Fc -Z0`) per database,
    `postgres` and `template1` included. The plain `<db>.sql.gz` is gone:
    `pg_restore -f` writes the SQL of a dump, `-l`/`-L` restores selected
    objects. A user without superuser rights gets the roles without their
    passwords, and the dump ends with rc 1, a warning in Borg UI.
  * Dumps of both engines are no longer compressed, so that Borg
    deduplicates them: a second archive of an unchanged instance adds next to
    nothing. Every dump file is mode 600, and a failing dump leaves the
    previous one in place. The MariaDB dumps leave out the dump date.
  * The per-database MariaDB dumps carry the events again (`-E`; the flag
    was `-e`, extended inserts).
  * `restore-postgres` restores the whole instance (`--all`), one database
    (with `-j`, its properties included), one database under another name
    (`--as`), or the roles alone (`--globals`), also into a PostgreSQL server
    before 17, whose rejections of the newer `pg_restore` it accepts.
  * New `restore-mariadb`: the whole instance from the full dump (`--all`),
    one database, or one under another name (`--as`).
  * `databases.mariadb.instances[].tls: false`: the credentials resolver
    writes `skip-ssl`, for a server without TLS, which the image's MariaDB
    client refuses by default (a MariaDB before 11.4 without a certificate).
  * The dumps and restores are tested end to end against PostgreSQL 13–18
    and MariaDB 10.11, 11.4 and 11.8 (`tests/e2e/db/`), in CI on every push.
  * Usage, files and privileges: `chart/README.md`, "Database dumps".

* **The node backup snapshots the cluster datastore** (#49,
  `node.datastoreSnapshot.enabled`, off by default). A node backup read
  etcd's data directory or k3s's `state.db` while they were written, which
  is not a consistent copy. Now each node pod snapshots its node's datastore
  before the backup: k3s with embedded etcd and kubeadm's etcd with
  `etcdctl snapshot save` (at the node's IP, without the host network;
  `hostNetwork: true` for etcd on localhost only), k3s with SQLite with
  SQLite's online backup, read-only. The k3s server token or kubeadm's PKI
  goes along, since the restore needs them. Nodes without a datastore skip
  the step. The snapshot holds every Secret of the cluster in clear text: it
  is written to a memory-backed volume of the pod, archived under
  `var/lib/k8s-borg/datastore`, and removed after the run. In interval mode
  `run.sh` takes it; in agent mode the chart publishes `datastore-snapshot`
  and `datastore-snapshot-clean` to the node agent and attaches them to the
  node plan as its last pre-backup hook (continuing on error) and its first
  post-backup hook (run whatever the result). A failed snapshot does not
  stop the file backup, and fails the run (in Borg UI: a warning). The
  restore for each datastore is in the chart README.
* **The image carries `etcdctl` and `etcdutl` 3.6.15**, the official release
  build, checksummed per architecture.
* **`register-backup-plan` keeps hooks it does not own.** With
  `BORG_PLAN_OWNED_AGENT_SCRIPTS` (set on node agents) only those hooks are
  replaced or removed; the plan keeps every other hook, such as one chosen
  in Borg UI. `BORG_PLAN_POST_AGENT_SCRIPTS` attaches post-backup hooks.
* **Consistent copies of SQLite databases on application volumes** (#53,
  `node.sqlite.enabled`, off by default). The node backup read an
  application's SQLite file and its `-wal` or `-journal` file at different
  moments, which under write load gave a corrupt copy more often than not.
  Now the databases listed in `node.sqlite.databases` (namespace, claim, path
  in the volume) are copied first with SQLite's online backup, by the new
  `sqlite-copy`: each node pod resolves the claim to its volume through the
  API and copies the databases on its node, read-only through `/node`, with
  the application's locks honoured. The copies are single files, mode 600,
  in their database's journal mode, archived under
  `var/lib/k8s-borg/sqlite/<namespace>/<pvc>/` and removed after the run. A
  database that cannot be copied fails the step with rc 2; the others are
  still copied, and the file backup runs. The node pods get a ServiceAccount
  of their own (`get` on the listed claims and on PersistentVolumes), an
  `emptyDir` on the node's disk for the copies, and `HostToContainer` mount
  propagation on `/node`, so that CSI volumes mounted after their start are
  visible. In interval mode `run.sh` makes the copies; in agent mode the
  chart attaches `sqlite-copy` and `sqlite-copy-clean` to the node plan like
  the datastore snapshot. No new binary: the image's Python has the
  `sqlite3` module. Tested end to end against applications writing under
  load in WAL and rollback-journal mode, with the SQLite of Alpine, Debian 12
  and Debian 11 (`tests/e2e/db/sqlite.bats`). Usage and restore: chart
  README, "SQLite databases".
* **Node backups stay on the node's own file systems** (#64). Interval-mode
  node backups (`borg-backup`) and the node plans `register-backup-plan`
  writes run `borg create` with `--one-file-system` (appended to the plan's
  custom flags, once). Mounts below a `node.include` root (kubelet, CSI and
  Longhorn volumes, NFS shares, btrfs subvolumes) are skipped; every root is
  still archived, the SQLite copies and the datastore snapshot included.
  Cluster backups are unchanged. A partition of the node below a root is
  stored as an empty directory, without a word from Borg: the new
  `node-skipped-mounts` names each one from the pod's mount table, as a
  warning before every interval run and at the start of every agent-mode
  node pod. Tested end to end with a tmpfs below a root and one as a root
  of its own (`tests/e2e/lifecycle.bats`).
* **A node plan without sources is disabled** (#58). When no root of
  `node.include` exists on a node, `register-backup-plan` disables the
  node's plan in Borg UI and logs why, instead of leaving it with its old
  sources and hooks. It is not deleted, which would drop its run history;
  the next pod start with a root enables it again. Cluster plans are left
  unchanged as before.
* **Credentials resolver Roles per release namespace** (#66). The Role and
  RoleBinding `db-credentials-rbac.yaml` renders in a `secretRef` namespace
  hash the release's namespace with the target namespace, as the
  `node.sqlite` Roles do: releases of the same name in two namespaces no
  longer collide.

* **MongoDB dumps and restores** (#50). `databases.mongodb` adds MongoDB to
  the cluster backup, configured like the other engines: a static `config`,
  an `existingSecret`, or a `secretRef` resolved at pod start, either to a
  whole connection string (`uriKey`, e.g. the MongoDB Community operator's
  `connectionString.standard`) or from `host`, `port`, `options` and user and
  password keys (Percona operator, Bitnami chart). An instance's credentials
  file is the YAML file `mongodump`/`mongorestore` read with `--config`, so
  the password never shows on a command line; a database in the URI's path
  (the Community operator's `…/admin?…`) is handed to the tools as
  `authSource`, as they would otherwise dump or restore that database alone.
  * `backup-mongodb` dumps an instance into one uncompressed archive,
    `<instance>/<instance>.archive`, mode 600, the users and roles included;
    on a replica set with the oplog of its own run (`--oplog`). The
    collections are written one after the other, so that two dumps of
    unchanged data are the same bytes and Borg deduplicates them. A sharded
    cluster (mongos) is refused; any failure fails the backup with rc ≥ 2
    and keeps the previous archive.
  * `backup-cluster-mongodb` runs it for every instance, in the CronJob and,
    published to the cluster agent, as the plan's pre-backup hook.
  * `restore-mongodb` restores the whole instance (`--all`, the oplog
    replayed; `--no-oplog` without), one database (dropped and created
    again), or one database under another name (`--as`); a database the
    archive does not hold is refused before anything is dropped. With an
    oplog, `--all` restores the users and roles first, so that the replay
    keeps a session the restored users would otherwise end. The user needs
    the `restore` role, and for `--all` with an oplog `root` or `anyAction`
    on `anyResource` as well: the replayed oplog starts with the last entry
    before the dump, often a command.
  * The image carries `mongodump` and `mongorestore` from Alpine's
    `mongodb-tools` (100.14.1; the package's six other tools are removed)
    and `mongodb-admin`, a small pymongo helper for what they cannot do:
    the server's topology, the config with the URI's database moved, dropping
    a database collection by collection (the `restore` role may not drop a
    database), and whether an archive holds an oplog.
  * The credentials resolver reads Secret keys with a `.` in their name.
  * `tests/e2e/db/mongodb.bats` runs dump, Borg archive and extract, and
    every restore mode against MongoDB 7 and 8 (replica sets and a
    standalone server), comparing each restore with a fingerprint of the
    source.

### Upgrade notes

* Node archives may shrink: a `node.include` root that contained mounts of
  other file systems no longer archives them, a partition of the node
  itself included (e.g. `/var/lib` of its own under `R /node/var`). Give
  every partition to keep its own `R` root; the node pod's log names the
  ones skipped.
* The credentials resolver's Roles and RoleBindings
  (`<fullname>-db-<hash>`) are renamed once: Helm deletes the old ones and
  creates the new ones in the same upgrade.
* `databases.<engine>.enabled: true` without instances and without an
  `existingSecret` now fails every render, with a message naming the engine.
  Before, it failed only where the cluster workloads were rendered (not with
  `cluster.enabled: false`). Configure the engine or set `enabled: false`.
* The dump files change their names: `<db>.sql.gz` and `<db>.dump.gz`
  (PostgreSQL) become `globals.sql` and `<db>.dump`; `<db>.sql.gz` and
  `<instance>-full-dump.sql.gz` (MariaDB) become `<db>.sql` and
  `<instance>-full-dump.sql`. The first successful dump removes the old
  `*.gz` files of its instance directory. To restore from an archive made
  before, `gunzip -k` the file first.
* `borg.dbBackupLocation` needs room for the uncompressed dumps, several
  times the size of the gzipped ones.
* A PostgreSQL backup user without superuser rights turns every cluster
  backup into a warning (roles without passwords). See "Privileges of the
  backup user" in `chart/README.md`.
* A MariaDB server without TLS needs `tls: false` (secretRef instances) or
  `skip-ssl` in its static config.
* A MySQL or Percona server under `databases.mariadb` now fails its backup
  with rc 2 (its dumps did not restore): move the instance to
  `databases.mysql`. MySQL's client knows no `skip-ssl`: in a static config
  write `ssl-mode=DISABLED` and `get-server-public-key` instead; a `secretRef`
  instance with `tls: false` gets them from the resolver.

## 1.1.9-beta.12

* **Borg UI 2.3.10-52-g2e4031646**, for a 24-hour integration test. The
  `borg-ui` submodule pins our fork's `io/integration` branch at 2e4031646
  (upstream main with fixes not yet merged there). Agent 0.1.21 (offered as
  an upgrade to agents installed outside the chart); the database schema
  changes (Alembic c4e532c20d7b).

### Upgrade notes

* Going back to 1.1.9-beta.11 or earlier: run `alembic downgrade -1` while
  still on this image, which deletes only the hooks that name an agent
  script; otherwise the older image fails at startup with "Can't locate
  revision".

## 1.1.9-beta.11

* **Borg UI 2.3.10-43-gb45ce0f58.** The `borg-ui` submodule moves to
  upstream main b45ce0f58. Agent 0.1.20 and the database schema are
  unchanged.

## 1.1.9-beta.10

* **Borg UI unchanged:** 2.3.10-36-g5e15222d5, agent 0.1.20, database
  schema unchanged.
* **Plan-mode cluster backups mount the S3 buckets fresh before each run**
  (#39). The console pod mounts its buckets when it starts and keeps the
  mounts as long as it runs, often for days, and s3fs's caches go wrong on
  such a mount: archives of plan-mode clusters showed directories with two
  entries and directory listings that no longer changed (deleted files gone,
  new ones never shown), while every CronJob archive of the same days was
  complete, since each CronJob run mounts fresh. The new agent script
  `s3-remount-buckets` unmounts every listed bucket and mounts it again with
  the probe and the `s3.onMountFailure` policy of the start; a busy mount is
  detached and its s3fs ended. In `cluster.backupMode=plan` it is the first
  pre-backup hook, ahead of `s3-verify-listing` and `s3-check-mounts`, and
  continues on error like them. Ending the s3fs of a busy or failed mount now
  matches the bucket name literally: a dot in a bucket name no longer also
  matches another bucket's s3fs (also in `s3-mount-bucket`).
* **The console pod reaps orphaned processes.** Its main process, the agent,
  does not collect the exit status of processes left to it, such as an s3fs
  that ends after its unmount or the watcher of busybox `timeout`; they stayed
  as zombies until the pod restarted, and a remount on every plan run would
  have added one per bucket per run. The pod now shares its process
  namespace (`shareProcessNamespace: true`), so the pause container is PID 1
  and reaps them.

### Upgrade notes

* The console pod rolls once (`shareProcessNamespace`). At its start the
  cluster plan's pre-backup hooks become `s3-remount-buckets`,
  `s3-verify-listing` (with `s3.verifyListing`), `s3-check-mounts`, the
  database dumps; as before, hooks changed in Borg UI are replaced.
* Each plan run now mounts every bucket fresh: about a second per bucket,
  and for a bucket that cannot be mounted the probe's `S3_PROBE_TIMEOUT`
  (30 s), once in `s3-remount-buckets` and once more in `s3-verify-listing`.
  Such a bucket is reported twice in the run, by `s3-remount-buckets` and by
  `s3-check-mounts`.
* The tag `1.1.9-beta.9` was built again from the merge of #39, chart and
  images under the same version. A cluster that had fetched the 1.1.9-beta.9
  chart before keeps it, since Flux does not fetch a chart again under the
  same version: its pods run the new image, which carries
  `s3-remount-buckets`, but the old chart neither publishes nor attaches it.
  Use 1.1.9-beta.10.

## 1.1.9-beta.9

* **Borg UI 2.3.10-36-g5e15222d5.** The `borg-ui` submodule moves to
  upstream main 5e15222d5. Agent 0.1.20 and the database schema are
  unchanged.
* **Keyfile modes for `borg.encryption`** (#20). Borg's key files now go to
  the `persistence.uiAgent` volume, next to the agent's `config.toml`: every
  backup workload sets `BORG_KEYS_DIR=/etc/borg-ui-agent/borg-keys`, in every
  mode, so the key of a keyfile repository survives the pod (the cluster
  CronJob's next run, a rollout of the DaemonSet or the console pod). The
  chart therefore accepts `keyfile`, `keyfile-blake2` (Borg 1),
  `keyfile-aes-ocb` and `keyfile-chacha20-poly1305` (Borg 2), which it
  refused until now. Repositories that exist are not affected: none of them
  can be a keyfile repository, and the repokey and authenticated modes keep
  their key in the repository. The new env variable rolls the backup pods
  once. The chart README's *Keyfile modes and where the keys live* says how
  to export a key (do it after the first backup), that an agent reset removes
  `config.toml` only, and that Borg UI never gets the key.
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
* **One S3 bucket that cannot be mounted no longer stops the cluster backup**
  (#26). Until now a bucket that did not answer its first listing stopped the
  pod's start, so the app pod went into CrashLoopBackOff and no bucket was
  backed up. s3fs cannot tell a missing bucket from a wrong region, wrong
  credentials or an unreachable endpoint, so the new `s3-mount-buckets`
  decides by count: such a bucket is skipped with a warning that names it,
  and the start stops only when no listed bucket can be mounted. The mount
  directory of a skipped bucket is removed, so the archive does not show it
  as an empty bucket. Before `borg create`, `borg-backup` checks that every
  listed bucket is mounted: a bucket that is not mounted makes the run end
  with a warning, and no bucket mounted is an error; the other sources are
  archived either way. In `cluster.backupMode=plan` the same check runs as
  the plan's first pre-backup hook, `s3-check-mounts`, registered with
  `continue_on_error`: the backup runs whatever the check finds, and Borg UI
  shows a failed check as a warning. `s3.onMountFailure: fail` keeps the
  hard stop at the start.
* **Plan-mode cluster backups check the S3 listings and mount lost buckets
  again** (#34). In `cluster.backupMode=plan` the console pod keeps its S3
  mounts for its whole life, and the listing check of the CronJob did not run:
  the long-lived mount, the one the s3fs listing bug hit, went unchecked, and a
  bucket skipped at the start or whose s3fs died stayed unmounted until the pod
  started again. With `s3.verifyListing` on (the default) the chart publishes
  `s3-verify-listing` to the cluster agent and attaches it as the plan's first
  pre-backup hook, ahead of `s3-check-mounts`, so that a bucket it mounts again
  counts as mounted. It continues on error like `s3-check-mounts`: a bucket
  that still misses objects ends the run with a warning in Borg UI, after the
  backup (the CronJob fails such a run; Borg UI cannot fail a plan run after
  its backup). s3fs puts itself into a session of its own, so a bucket mounted
  again from the hook stays mounted after the hook ends or is cancelled.
* **A failed reconcile Job says why, and the reason stays** (#29). Every
  request of the Job is bounded in time; the health wait gives up on a single
  attempt after 10 s instead of curl's own 300-s connect timeout, which let
  one dropped connection use up the whole wait. A failed request names curl's
  message or the HTTP status with what the server said (a validation error's
  field and message, never the rejected input; known secrets masked), and the
  `FATAL` line carries it. The health wait prints a progress line every 30 s.
  The reason is kept in three places: the Job and its pod stay for a day
  instead of 10 minutes, the last log lines land in the pod status
  (`terminationMessagePolicy: FallbackToLogsOnError`), and the Job writes the
  `FATAL` line with its revision to the reconcile-status ConfigMap as
  `lastError`, which the gated agent pods print while they wait in
  `wait-for-reconcile`. The next successful run removes it.

### Upgrade notes

* The console pod and the DaemonSet roll once for the new `BORG_KEYS_DIR`;
  the cluster CronJob picks it up with its next run.
* Cluster archives written through a long-lived s3fs mount by an earlier
  image (above all the console pod in `cluster.backupMode=plan`) can miss
  files of a bucket. The first cluster run with this image archives the
  bucket's full listing; archives from before the upgrade keep what they
  hold, so compare them with the bucket before relying on them.
* New value `s3.verifyListing` (default `true`). Each check costs two
  listings of the bucket through the S3 API and one walk of its mount, once
  per cluster run; a bucket that is mounted again is checked again, which
  repeats all three.
* A run that fails the check exits with an error after archiving, so the
  CronJob's pod restarts it (`backoffLimit: 5`) with a new mount.
* New value `s3.onMountFailure` (default `skip`, or `fail` for the previous
  behaviour). A bucket that cannot be mounted costs `S3_PROBE_TIMEOUT` (30 s)
  at the start, and with `s3.verifyListing` once more in each cluster run,
  which tries to mount it again. A cluster run with a skipped bucket ends
  with a warning: the CronJob logs it and exits 0, as for Borg's own
  warnings.
* In plan mode the cluster plan gains the pre-backup hook `s3-check-mounts`
  at the next start of the console pod. A bucket skipped at the start stays
  unmounted until the pod starts again, and each plan run warns until then.
* In plan mode with S3 and no database dump, the console pod now sends the
  plan's pre-backup hooks on every start, and Borg UI replaces all hooks of
  the plan with that list. A hook added to the cluster plan in Borg UI is
  then gone after the next start (with a database dump this was already so).
  The chart attaches only its own hooks; `cluster.agentScripts` publishes a
  script but does not attach it.
* New value `borgUI.reconcile.ttlSecondsAfterFinished` (default `86400`,
  until now fixed at 600): how long a finished reconcile Job and its pod are
  kept. Each revision has its own Job, so a kept Job does not block the next
  upgrade.
* `borgUI.reconcile.waitSeconds`: image pull time plus this wait must stay
  below the release timeout (HelmRelease `spec.timeout`, `helm --timeout`),
  or raising it only moves the failure from the Job to the release.

## 1.1.9-beta.8

* **Borg UI 2.3.10-34-g49099c8c0.** The `borg-ui` submodule moves to
  upstream main 49099c8c0. Agent 0.1.20 (offered as an upgrade to agents
  installed outside the chart); the database schema is unchanged.
* CI runs on Ubuntu 26.04 with Helm 4.3.0 pinned; the chart and the image
  contents are not affected.

### Upgrade notes

* No value changes; the rendered manifests differ only in the image tags.
* Borg UI's usage analytics are on for every user who has not declined
  them (banner at first login, or Preferences); they now go to the Borg UI
  project's own service instead of Umami.
* A `borg.version` other than 1 or 2 now fails the repository registration:
  Borg UI accepts only these Borg majors.

## 1.1.9-beta.7

* **Borg UI 2.3.10-27-gcdd5712c9.** The `borg-ui` submodule moves from our
  integration branch (54ee5563) to upstream main cdd5712c9. Agent 0.1.19
  (offered as an upgrade to agents installed outside the chart); the database
  schema is unchanged.
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
* Notification URLs with the email options `use_pgp=` or `pgpkey=`, which
  apprise 2.0.0 removed, now fail.

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
* **Borg UI unchanged:** 2.3.8, agent 0.1.17, database schema unchanged.
