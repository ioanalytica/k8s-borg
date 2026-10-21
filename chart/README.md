<!-- Copyright IO ANALYTICA. SPDX-License-Identifier: AGPL-3.0-only -->

# k8s-borg

Backup for Kubernetes clusters with [BorgBackup](https://www.borgbackup.org/).
Deploys a node-backup **DaemonSet**, a cluster-data **CronJob**, and a console
**StatefulSet** — each talking to its own Borg repository — plus an optional
[Borg UI](https://github.com/karanhudia/borg-ui) server with managed-agent
enrollment, and an optional Borg 1/Borg 2 repository server.

## Install

```sh
# pull the common library dependency (or use the vendored charts/ tarball)
helm dependency build ./chart

helm install my-borg ./chart -n k8s-borg --create-namespace \
  --set borg.repoBase.value="ssh://user@borg.example.com:22/./mycluster" \
  --set borg.passphrase.value="…" \
  --set-file ssh.privateKey=./id_ed25519 \
  --set-file ssh.knownHosts=./known_hosts
```

For anything beyond a smoke test, put the sensitive values in a pre-created
Secret and reference it with `existingSecret` / `ssh.existingSecret` (managed
with SOPS, Sealed Secrets, or External Secrets) — see [`../examples`](../examples).

## Modes

Backup execution is chosen **per component**, along two independent axes:
*who runs the backup* and *whether the pod is enrolled in Borg UI*.

- **Node (DaemonSet)** — `node.backupMode`:
  - `interval` (default): the stable in-pod loop runs `/run.sh` every
    `node.backupIntervalSeconds` against `borg.repoBase`.
  - `agent`: each node pod enrolls at Borg UI and registers a per-node backup plan.
- **Cluster (CronJob + console/agent pod)** — the `cluster` section covers the
  cluster-scope data **and** the long-lived console pod (deployed when
  `cluster.enabled`). Two independent axes:
  - `cluster.backupMode` — *how the backup is scheduled*: `cronjob` (default, a k8s
    CronJob on `cluster.schedule`) or `plan` (a server-side BackupPlan run by the
    console/agent pod; needs `cluster.mode=agent`; no CronJob).
  - `cluster.mode` — *whether the console pod is enrolled in Borg UI*: `legacy`
    (default, inspection only — tails the log, `kubectl exec` in) or `agent` (enroll
    at Borg UI: register the cluster repository + check-schedule so it is browsable,
    and run the agent). In `cronjob` mode the agent just makes the repo visible.
  - `cluster.borgUiResync` (default `true`) — in `cronjob` mode with a Borg UI to
    talk to (`borgUI.enabled` or `borgUI.agentConnection.server`), each run ends by
    asking Borg UI to resync the cluster repository, so new and pruned archives and
    the size show up right away instead of on the next periodic reconcile run. Best
    effort: a failure is logged as a warning and never changes the job's exit code.

Managed-agent modes need a reachable server: set `borgUI.agentConnection.server`,
or deploy one in-cluster with `borgUI.enabled=true` (which also runs a reconcile
Job that mints an admin PAT and reconciles `borgUI.oidc`).

### Node backups: the node's own file systems

A node backup archives the node itself, not what other workloads mount on it.
It runs `borg create` with `--one-file-system`, in `interval` mode and in the
node plans `register-backup-plan` writes (appended to the plan's custom
flags). Below a `node.include` root, Borg skips every mount of another file
system: kubelet volumes, CSI and Longhorn devices, NFS shares. Each `R` root
is still archived whatever file system it is on, so a partition given as a
root of its own (e.g. `R /node/home`) is backed up. The SQLite copies
(`node.sqlite`) and the datastore snapshot (`node.datastoreSnapshot`) are
roots of their own as well. Cluster backups are not changed: their sources
are mounts on purpose.

**Give every partition you want archived its own `R` root.** Roots on
different file systems are fine: `R /node/etc` and `R /node/var/lib` are
both archived in full, whatever disks they are on. The pitfall is a root
that spans a file-system boundary of the node itself: with `R /node/var`
while `/var/lib` is a partition of its own, Borg stores `/var/lib` as an
empty directory, and Borg itself does not warn. Before each interval run
and at each start of a node pod in `agent` mode, `node-skipped-mounts`
reads the pod's mount table and logs every such partition (disk file
systems such as ext4, xfs, btrfs, zfs, vfat; not kubelet volumes, NFS,
tmpfs or overlay) as a warning, e.g.:

```
WARNING: file systems of the node below a root are skipped by --one-file-system; give each one to archive its own 'R' root in node.include:
/node/var/lib (ext4 /dev/sdb1)
```

On btrfs, a subvolume counts as a file system of its own and is skipped
below a root, snapper snapshots among them, which is usually wanted. Give a
subvolume that should be backed up its own `R` root. A subvolume that is
not mounted on its own does not show in the mount table and is not named
in the warning.

A node on which no root of `node.include` exists has nothing to back up. In
`agent` mode `register-backup-plan` disables the node's plan and says why in
the pod log. The plan is not deleted, so its run history stays in Borg UI;
the next pod start with a root on the node enables it again. In `interval`
mode `borg-backup` skips a run only when `node.include` has no `R` line at
all; it does not check that the roots exist, and `borg create` reports a
missing one as a warning.

### Agent pre/post-backup scripts

You can publish pre/post-backup scripts to a managed agent as a map of
filename → script body. They are mounted read-only and executable at
`/etc/borg-ui-agent-scripts` and become selectable as pre/post-backup hooks in a
Borg UI backup plan. The agent only ever runs scripts from this allow-list — the
server sends a script *name*, never a path. Scripts run on the agent with
`stdout`/`stderr` kept separate; exit code `0` = success, `1` = warning (the
backup still runs), `>1` = failure.

Scope matters — publish scripts to the agent that actually has the data and
secrets they need:

- **`cluster.agentScripts`** (needs `cluster.mode=agent`) → the **cluster** agent, in
  the console pod. Use this for cluster-backup scripts (DB dumps etc.) — that pod is
  where the cluster source/DB secrets live. The chart adds `backup-cluster-<engine>`
  for each enabled database and, with `s3.enabled`, `s3-remount-buckets`
  (unmounts every listed bucket and mounts it fresh) and `s3-check-mounts` (exit
  `1` when a listed bucket is not mounted) and, with `s3.verifyListing` as well,
  `s3-verify-listing` (the CronJob's listing check, which also mounts a lost or
  skipped bucket again); in `cluster.backupMode=plan` they are the plan's
  pre-backup hooks, in the order `s3-remount-buckets`, `s3-verify-listing`,
  `s3-check-mounts`, the dumps. The console pod mounts its buckets when it
  starts and keeps them as long as it runs, so the fresh mount before each
  plan run gives the plan path what each CronJob run has. A failing S3 script
  does not stop the backup (`continue_on_error`); a failing database dump does.
  The console pod shares its process namespace, so that the pod's pause
  container reaps the s3fs processes that end after an unmount.
- **`node.agentScripts`** (needs `node.backupMode=agent`) → each **node** agent.
  Use this for node-local scripts. Node pods do not have the cluster secrets.

```yaml
cluster:
  mode: agent
  agentScripts:
    backup-cluster-postgres: |
      #!/bin/sh
      # borg-ui: Dump the cluster Postgres before backup
      pg_dumpall > /mnt/cluster/db.sql
```

## Database dumps

Each cluster backup first dumps every instance of the configured engines
(`backup-cluster-<engine>`) into `borg.dbBackupLocation/<instance>/`, which the
cluster backup then archives. `<instance>` is the instance's `name` (the
`*.conf` file name of a static config).

An engine is configured when `databases.<engine>.enabled` is true and it has at
least one instance or an `existingSecret`; an enabled engine with neither fails
the render. Only configured engines get their credentials mounted, their
`backup-cluster-<engine>` published to the cluster agent and attached as a
pre-backup hook (plan mode), or run in the cluster CronJob (the chart passes
them as `BORG_DB_ENGINES` to `backup-cluster-databases`).

| Engine | File | Content |
| --- | --- | --- |
| PostgreSQL | `globals.sql` | `pg_dumpall --globals-only`: roles, password hashes, memberships, role settings, tablespaces |
| PostgreSQL | `<db>.dump` | `pg_dump -Fc -Z0`, one per database that allows connections (as `pg_dumpall`; others are named in the log), `postgres` and `template1` included: schema, data, privileges, extensions, the database's owner, settings and grants |
| MariaDB | `<db>.sql` | one per database, with routines, events and triggers |
| MariaDB | `<instance>-full-dump.sql` | every database (`-A`), the `mysql` schema with the users and grants included |
| MySQL | `<db>.sql`, `<instance>-full-dump.sql` | as MariaDB, written by MySQL's own `mysqldump` 8.4, without GTIDs |
| MongoDB | `<instance>.archive` | one `mongodump` archive of every database, users and roles included, with the oplog on a replica set — see [MongoDB dumps](#mongodb-dumps) |
| Redis/Valkey | `<instance>.rdb` | the server's RDB snapshot, every database: a standalone server, or a replica |
| Redis/Valkey | `<instance>-slots-<first>-<last>.rdb` | a cluster: one RDB snapshot per primary, named after its first slot range |
| Redis/Valkey | `<instance>-cluster-nodes.txt` | a cluster: `CLUSTER NODES` at dump time, which primary held which slots |

Every file is mode `600`. The dumps are **not compressed**: a compressed
stream differs from the first changed byte on, so every dump would be new data
in every archive. Uncompressed, Borg deduplicates them and compresses on its
own; a second archive of an unchanged instance adds next to nothing. The
directory needs room for the uncompressed dumps, several times the size of
the gzipped ones before 1.1.9. A dump that fails fails the backup and leaves
the previous dump of that database in place; the dump of a database that no
longer exists stays in the directory.

### Restoring

From the console pod, with the instance's credentials file (static configs in
`/root/.<engine>/`, secretRef instances resolved there too), after the dumps
are extracted from an archive into `DB_BACKUP_LOCATION`:

| Command | Restores |
| --- | --- |
| `restore-postgres /root/.postgres/<instance>.conf --all [-j N]` | the whole instance: `globals.sql`, then every database dropped and created again with its properties. The dumped roles' attributes and passwords replace the server's, the role in the credentials file included |
| `restore-postgres /root/.postgres/<instance>.conf <db> [-j N]` | one database, dropped and created again with its properties |
| `restore-postgres /root/.postgres/<instance>.conf <db> --as <name> [-j N]` | the dump of `<db>` into `<name>` (dropped first), to compare before replacing; the database-level properties (owner, `ALTER DATABASE … SET`, its grants) are not applied |
| `restore-postgres /root/.postgres/<instance>.conf --globals` | roles and tablespaces alone (passwords as with `--all`) |
| `restore-mariadb /root/.mariadb/<instance>.conf --all` | the whole instance from the full dump, users and grants included. Meant for an empty server: the dumped users replace the server's, the one in the credentials file included |
| `restore-mariadb /root/.mariadb/<instance>.conf <db>` | one database, dropped and created again |
| `restore-mariadb /root/.mariadb/<instance>.conf <db> --as <name>` | the dump of `<db>` into `<name>` (dropped first) |
| `restore-mysql /root/.mysql/<instance>.conf --all \| <db> [--as <name>]` | the same for MySQL |

`-j N` sets pg_restore's parallel jobs (default 4; one for a server before 17). A database that is
replaced is dropped with `WITH (FORCE)`, which ends its sessions. Every error
ends a restore with rc ≥ 2. The image's `pg_restore` is PostgreSQL 18's;
for a server before 17 `restore-postgres` accepts the two statements of a
newer `pg_restore` that such a server rejects (`SET transaction_timeout`, and
`LOCALE_PROVIDER` before 15). Restores are tested against PostgreSQL 13–18,
MariaDB 10.11, 11.4 and 11.8, MySQL 8.4 and Percona Server 8.4.

A PostgreSQL dump can be read and edited as SQL without a server:
`pg_restore -f db.sql <db>.dump` writes the SQL, `pg_restore -l <db>.dump >
list` lists its objects, and `pg_restore -L list …` restores only the ones
left in the list.

### Restoring Redis and Valkey

An RDB file is restored by the server itself, which loads it at start; how
to stop and start the server depends on how it is deployed, so this is not
scripted:

1. Extract the instance's RDB file from an archive.
2. Stop the server (scale its StatefulSet or Deployment to 0).
3. Put the file into the server's data directory (`dir`) under its
   `dbfilename` (`dump.rdb` by default), readable by the server's user.
4. With `appendonly yes` the server loads its append-only file instead and
   ignores `dump.rdb`: move the append-only directory aside and start with
   `appendonly no`; once the server is up, `CONFIG SET appendonly yes`
   writes a new append-only file from the loaded data. Set it in the
   configuration again.
5. Start the server; replicas copy the restored data from it.

The RDB file holds the keys of every database with their TTLs, not the ACL
users and not the configuration. It loads into the server it came from or a
newer release of the same one; Valkey 9 writes its own format (`VALKEY080`).
The primaries of a cluster are dumped one after another, each consistent in
itself: put each file on the primary that holds its slots in a cluster with
the same slot layout (`<instance>-cluster-nodes.txt`), or load the files one
after another into a standalone server to read the keys. The tests cover the
restore into a server of the same version, also of every primary's file into
a standalone server (Redis 7 and 8, Valkey 8 and 9); not a restore into a
cluster.

The server forks for the snapshot, as for `BGSAVE`, and needs memory for the
pages written meanwhile. Two snapshots of an unchanged server differ only in
their first and last bytes, so Borg stores little of a second archive; the
keys are in the server's hash order, so changes land all over the file, and
each makes its Borg chunk (about 2 MiB) new.

### Privileges of the backup user

- **PostgreSQL:** a superuser dumps everything. Without superuser rights the
  role password hashes cannot be read: the roles are dumped without their
  passwords (`--no-role-passwords`) and the dump ends with rc `1`, a warning
  in Borg UI. Such a user needs `pg_read_all_data` (PostgreSQL 14+), `CONNECT`
  on every database, and `SELECT` on every large object — `pg_read_all_data`
  does not cover large objects, and a dump that cannot read one fails.
- **MariaDB:** the dumps read every database, the `mysql` schema included:
  `GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, SHOW DATABASES ON *.*` is enough
  (tested), or `root`. A restore with `--all` writes the `mysql` schema and
  needs `root`.
- **MySQL:** as MariaDB, plus `PROCESS`:
  `GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, SHOW DATABASES, PROCESS ON *.*`
  (tested), or `root`.
- **Redis/Valkey:** an ACL user needs
  `ACL SETUSER backup on >… +info +sync +replconf +cluster|nodes` (tested):
  `INFO` tells a cluster from a standalone server, `SYNC`/`REPLCONF` carry
  the snapshot, `CLUSTER NODES` lists the primaries. Without a `user` the
  default user is used (`requirepass`). A server that renames or disables
  `SYNC` cannot be dumped.

### Redis and Valkey instances

An instance's config file is key=value lines, the value taken verbatim after
the first `=`: `host` (required), `port` (6379), `user`, `password`, `tls`
(`true`/`false`), `cacert` (a CA bundle to verify the server with; mount it
through `cluster.extraVolumes`/`cluster.extraVolumeMounts`) and `insecure`
(TLS without verifying the server); `cacert` and `insecure` turn TLS on.
With TLS, the certificate must name the server: `host` as configured, and
each node of a cluster by the hostname it announces
(`cluster-announce-hostname`), or else by its IP address. Every connection is
checked, `INFO` and `CLUSTER NODES` included, before the password is sent
(tested against a TLS-only cluster whose certificate names its nodes'
hostnames and no IP address). A `secretRef` instance
sets the same as `host`, `port`, `user`/`secretRef.usernameKey` (either or
neither), `tls`, `cacert` and `insecure`.

A cluster is recognised by itself (`cluster_enabled` in `INFO`) and dumped
through any one of its nodes, one RDB file per primary. A failing primary
fails the dump, and the previous files stay as they were.

The snapshot is streamed over the replication protocol by `redis-rdb-sync`.
It does what `valkey-cli --rdb` does and also tells a Valkey server its own
version: Valkey 9 sends its new format only to a replica that announces a
version able to read it, and without it the snapshot of a hash field with a
TTL of its own fails.

### PostgreSQL operators

A `secretRef` instance reads the user and the password from the operator's
Secret; the host is always given on the instance, the port defaults to 5432.

| Operator | `secretRef` | `host` |
| --- | --- | --- |
| Zalando | `name: postgres.<cluster>.credentials.postgresql.acid.zalan.do`, `usernameKey: username`, `passwordKey: password` | `<cluster>.<ns>.svc` |
| CloudNativePG | `name: <cluster>-superuser`, `usernameKey: username`, `passwordKey: password` | `<cluster>-rw.<ns>.svc` |

CloudNativePG's Secrets carry a `host` too, but only the service name
(`<cluster>-rw`), which resolves in the cluster's own namespace alone. Its
`<cluster>-superuser` Secret exists only with `enableSuperuserAccess: true` on
the `Cluster` (off by default). Without it, a role of its own can dump: one
declared under `spec.managed.roles` with `login: true`,
`inRoles: [pg_read_all_data]` and a `passwordSecret` (a
`kubernetes.io/basic-auth` Secret with `username` and `password`), or the
application owner from `<cluster>-app`. Both dump a cluster as CloudNativePG
bootstraps it, the roles without their passwords (rc `1`, see above). What
is added later needs the grants above: `CONNECT` on every database,
`SELECT` on every large object, and, for the application owner, which reads
only what it owns or is granted, read access to every table. A dump that
cannot read something fails the backup (rc ≥ 2). Tested against
CloudNativePG 1.30.1 with all three Secrets.

### MariaDB servers without TLS

The image's MariaDB client (11.8) asks for TLS by default and refuses a server
that offers none, as a MariaDB before 11.4 without a certificate of its own
does. For such a server, set `tls: false` on a `secretRef` instance (the
resolver writes `skip-ssl` into its credentials file), or add a `skip-ssl`
line to the `[client]` section of a static `config`.

### MySQL and Percona Server

`databases.mysql` takes MySQL 8.4 and Percona Server 8.4 (the Percona Operator
for MySQL included), with the same instance options as `databases.mariadb`.
It dumps and restores with MySQL's own client (8.4, in `/opt/mysql/bin`):
`mariadb-dump` writes the values of generated columns into its dumps, which
MySQL refuses on restore, and copies system tables MySQL does not take back.
An instance under the wrong engine fails its backup with rc 2, naming the
engine to use.

- **TLS:** MySQL's client uses TLS when the server offers it, without checking
  the certificate (`ssl-mode=PREFERRED`). `tls: false` on a `secretRef`
  instance writes `ssl-mode=DISABLED` and `get-server-public-key` (a
  `caching_sha2_password` user cannot log in without TLS otherwise). Neither
  authenticates the server: someone who can intercept the connection can pose
  as the server, and with `get-server-public-key` hand out the RSA key the
  password is encrypted with, and read the password. Both are meant for a
  network you trust, such as the cluster's own. Elsewhere use a static
  `config` that checks the server: `ssl-mode=VERIFY_IDENTITY` with `ssl-ca`,
  or, without TLS, `server-public-key-path` with the server's key.
- **GTIDs:** the dumps carry none (`--set-gtid-purged=OFF`). A restore brings
  back the data into a server that keeps its own GTIDs; it does not make that
  server a replica of the source.
- **Percona Operator for MySQL:** `<cluster>-secrets` holds one key per system
  user (`user: root`, `passwordKey: root`); `<cluster>-psuser-root` holds
  `user` and `password` (`usernameKey: user`). Both tested with operator 1.2.0.
  Restore single databases into an operator's cluster: `--all` replaces the
  users the operator manages.

## MongoDB dumps

When MongoDB is configured (see [Database dumps](#database-dumps)),
`backup-cluster-mongodb` dumps every instance with `mongodump` into
`borg.dbBackupLocation/<instance>/<instance>.archive`, one archive of every
database, the users and roles (`admin.system.users`, `admin.system.roles`)
included. On a replica set the dump carries the oplog of its own run
(`--oplog`), so that a restore of the whole instance is consistent to the end
of the dump; a standalone server is dumped without one. A sharded cluster
(`mongos`) is refused: dump the shards' replica sets instead.

The archive is mode `600` and **not compressed**, and its collections are
written one after the other (`--numParallelCollections=1`): two dumps of
unchanged data are then the same bytes but for the oplog, so Borg
deduplicates them (with mongodump's default of four collections at a time,
interleaved, 20 of 25 MB differed between two dumps of the same data). A
failing dump fails the backup (rc ≥ 2) and leaves the previous archive in
place.

### Credentials

An instance's `*.conf` file is the YAML file `mongodump` / `mongorestore`
read with `--config`, so the password never shows on a command line:

```yaml
uri: mongodb://backup@mongodb.databases.svc:27017/?authSource=admin
password: 'CHANGE_ME'   # for the user in the URI; may also be in the URI
```

A `secretRef` instance gets this file from the credentials resolver, in one
of two ways:

| Operator / chart | `secretRef` | Resolved to |
| --- | --- | --- |
| MongoDB Community operator | `name: <resource>-<auth db>-<user>`, `uriKey: connectionString.standard` | the connection string as is |
| Percona Server for MongoDB | `name:` the cluster's `spec.secrets.users` (default `percona-server-mongodb-users`), `usernameKey: MONGODB_BACKUP_USER`, `passwordKey: MONGODB_BACKUP_PASSWORD`, with `host: <cluster>-rs0.<ns>.svc` and `options: authSource=admin&replicaSet=rs0` | `mongodb://<user>@<host>:<port>/?<options>` and the password |
| Bitnami chart | `passwordKey: mongodb-root-password` with `user: root` and `host` | as above |

`port` defaults to 27017 and `options` (the URI's query) to
`authSource=admin`; the user is percent-encoded. `host` is one host name or
IP address (an IPv6 address in brackets; a seed list goes into a `uriKey` or a
static config), and special characters in an option's value are
percent-encoded; the chart refuses anything else. With `uriKey`, `host`,
`port`, `options` and the user and password keys go without.

A database in the URI's path (`…:27017/admin?…`, as in the Community
operator's connection strings) is the one to authenticate against when the
URI has credentials and no `authSource` (an `authSource` takes precedence),
but `mongodump` and `mongorestore` would also dump or restore that database
alone. The scripts therefore hand the tools the file through
`mongodb-admin config`, which drops the path and, for a URI with credentials
and no `authSource`, makes the database its `authSource` — through a pipe, so
the password is not written anywhere.

### Restoring

From the console pod, after the archive is extracted into
`DB_BACKUP_LOCATION`:

| Command | Restores |
| --- | --- |
| `restore-mongodb /root/.mongodb/<instance>.conf --all` | the whole instance: each dumped collection dropped and restored, the users and roles, which replace the server's (the one in the credentials file included), and, for a replica set's dump, the oplog replayed. Databases the dump does not hold are left alone |
| `restore-mongodb /root/.mongodb/<instance>.conf --all --no-oplog` | the same without replaying the oplog |
| `restore-mongodb /root/.mongodb/<instance>.conf <db>` | one database, dropped and created again |
| `restore-mongodb /root/.mongodb/<instance>.conf <db> --as <name>` | the dump of `<db>` into `<name>` (dropped first), to compare before replacing |

With an oplog, `--all` restores the users and roles first, on their own:
a user replaced by its dumped self (on another server, with another
`userId`) loses the session it is logged in with, which the replay after
them would then lack. The full restore after it logs in anew, as the
restored user of the credentials file, whose password must therefore be the
one in the dump; `--all --no-oplog` restores in one pass.

`mongorestore` replays the oplog only for the whole instance: a single
database comes back as each of its collections was when it was dumped. The
users and roles, also those defined on a database, and the `admin` database
are only restored with `--all`. A database the archive does not hold is
refused before anything is dropped. Every error ends a restore with rc ≥ 2.
Covered by the database end-to-end tests against MongoDB 7.0 and 8.2, replica
set and standalone (`tests/e2e/db/mongodb.bats`).

### Privileges

- **Dump:** the built-in `backup` role, which also reads the users and roles.
- **Restore:** the built-in `restore` role for a single database. For
  `--all` from a replica set's dump, `root` or a role with `anyAction` on
  `anyResource` as well, as MongoDB documents for `mongorestore
  --oplogReplay`: replaying a command takes it, and the replayed oplog starts
  with the last entry before the dump, which on a quiet server is often one
  (an index, a collection or a view created or dropped). With `restore`
  alone such a replay fails after the collections are back (rc ≥ 2, with a
  hint); `--all --no-oplog` restores without it.

The same credentials file serves both, so its user needs both roles. The
Percona operator's backup user has them, `anyAction` included (its role
`pbmAnyAction`).

## Cluster datastore snapshot

`node.datastoreSnapshot.enabled=true` adds a snapshot of the cluster datastore
to the node backup of every control-plane node: the objects, Secrets and
configuration a lost control plane is rebuilt from. Copying the datastore's
files while it runs does not give a consistent copy, so each node pod takes a
snapshot first:

| Datastore | Detected by | Snapshot | Goes along |
| --- | --- | --- | --- |
| k3s, embedded etcd | `<k3sDataDir>/server/db/etcd/member` | `etcdctl snapshot save` | the k3s server token |
| k3s, SQLite | `<k3sDataDir>/server/db/state.db` | SQLite online backup (read-only) | the k3s server token |
| kubeadm, local etcd | `<kubeadmDir>/manifests/etcd.yaml` | `etcdctl snapshot save` | `<kubeadmDir>/pki` |

The node DaemonSet runs on every node and tolerates `NoSchedule` taints, so it
reaches the control-plane nodes; a node without a datastore skips the step.
Control-plane nodes with a `NoExecute` taint (k3s's `CriticalAddonsOnly` for
dedicated servers) need a matching entry in `node.tolerations`. Not covered:
an etcd outside the cluster's nodes (kubeadm's external etcd), and other
datastores of k3s (kine with PostgreSQL or MySQL).

> **RKE2, and k3s with embedded etcd, snapshot etcd themselves** (by default
> every 12 hours, into `<data-dir>/server/db/snapshots`). Archiving that
> directory through `node.include` is enough and needs no part of this
> feature, for example
> `R /node/var/lib/rancher/rke2/server/db/snapshots`. Archive the server
> token with it (`<data-dir>/server/token`, or the `token` in the server's
> config file, or the file its `token-file` names): the restore refuses
> without it. Snapshot and token together give the cluster's Secrets and
> keys, so the repository must encrypt (see below). Such a snapshot is as old
> as the last scheduled one, and it stays on the node's disk. This feature is
> for datastores without built-in snapshots, k3s with SQLite and kubeadm, or
> for a snapshot taken at backup time.

etcd is reached at the node's IP, on which k3s and kubeadm listen as well as
on localhost, with the node's etcd client certificate, read through the
read-only host root. Where etcd listens on localhost only,
`node.datastoreSnapshot.hostNetwork=true` puts the node pods into the host
network and uses `https://127.0.0.1:2379`; `node.datastoreSnapshot.etcdEndpoint`
sets any other URL.

**The snapshot holds every Secret of the cluster in clear text.** It is written
to a memory-backed volume of the pod (`node.datastoreSnapshot.sizeLimit`,
default `2Gi`, counts against the pod's memory), never to the node's disk,
archived from there into the repository, and removed after the run.
A run that ends early (a failed pre-backup hook before it, a cancelled run)
leaves it in that memory until the next run or the pod's end.

**Use it only with an encrypting repository mode** (`borg.encryption`: the
`repokey*` and `keyfile*` modes, the default). `authenticated*` and `none` do
not encrypt the archive contents: anyone who can read the repository reads the
snapshot, the token and the PKI without the passphrase.

- **Interval mode:** `run.sh` takes the snapshot before `borg-backup` and
  removes it on every way out.
- **Agent mode:** the chart publishes `datastore-snapshot` and
  `datastore-snapshot-clean` to the node agent (next to `node.agentScripts`,
  which win on a name collision) and attaches them to the node plan: the
  snapshot as the last pre-backup hook, its removal as the first post-backup
  hook, run whatever the backup's result. Hooks chosen in Borg UI stay on the
  plan; switching the feature off removes only these two.

A failed snapshot does not stop the file backup, and fails the run; in agent
mode Borg UI can only show it as a warning (`continue_on_error`).

### Archive layout

```
var/lib/k8s-borg/datastore/k3s/etcd-snapshot.db    k3s, embedded etcd
var/lib/k8s-borg/datastore/k3s/state.db            k3s, SQLite
var/lib/k8s-borg/datastore/k3s/token               k3s server token
var/lib/k8s-borg/datastore/kubeadm/etcd-snapshot.db
var/lib/k8s-borg/datastore/kubeadm/pki/            /etc/kubernetes/pki
```

### Restore

The restore is done by hand on the node. Each procedure below was carried out
once on a test cluster from an archive this chart wrote: the objects from
before the backup were back, the ones created after it were gone, and the
Secrets were readable.

Get the files out of the archive with a Borg of the repository's version, for
example the one in this chart's image, onto the node being restored, into a
directory only root can read (`/root/restore` below). Delete them after the
restore.

```sh
borg extract "$BORG_REPO::<archive>" var/lib/k8s-borg/datastore      # Borg 1
borg -r "$BORG_REPO" extract <archive> var/lib/k8s-borg/datastore    # Borg 2
```

**k3s, embedded etcd** (tested on a fresh node with the same k3s version):

```sh
systemctl stop k3s
k3s server --cluster-reset \
  --cluster-reset-restore-path=/root/restore/var/lib/k8s-borg/datastore/k3s/etcd-snapshot.db \
  --token="$(cat /root/restore/var/lib/k8s-borg/datastore/k3s/token)"
systemctl start k3s
```

k3s keeps its certificates in the datastore, encrypted with the token: without
`--token`, a node without the original token file refuses the restore. With
more than one server, k3s documents the rest: on each other server stop k3s,
move `/var/lib/rancher/k3s/server/db` away, and start k3s to rejoin (not
tested here).

**k3s, SQLite** (tested on a fresh node with the same k3s version):

```sh
systemctl stop k3s
mkdir -p /root/restore/old && mv /var/lib/rancher/k3s/server/db/state.db* /root/restore/old/
install -m 0600 /root/restore/var/lib/k8s-borg/datastore/k3s/state.db /var/lib/rancher/k3s/server/db/state.db
systemctl start k3s     # on a fresh node: with --token "$(cat …/k3s/token)", as above
```

**kubeadm, local etcd** (tested on the same control-plane node). Take the
member name and peer URL from `/etc/kubernetes/manifests/etcd.yaml`; `etcdutl`
comes with the etcd release and with this chart's image:

```sh
mkdir -p /etc/kubernetes/manifests.stopped
mv /etc/kubernetes/manifests/{etcd,kube-apiserver}.yaml /etc/kubernetes/manifests.stopped/
# wait until crictl ps shows neither etcd nor kube-apiserver
etcdutl snapshot restore /root/restore/var/lib/k8s-borg/datastore/kubeadm/etcd-snapshot.db \
  --data-dir /var/lib/etcd-restored --name <member> \
  --initial-cluster <member>=https://<node IP>:2380 \
  --initial-advertise-peer-urls https://<node IP>:2380
mv /var/lib/etcd /var/lib/etcd.before-restore && mv /var/lib/etcd-restored /var/lib/etcd
mv /etc/kubernetes/manifests.stopped/{etcd,kube-apiserver}.yaml /etc/kubernetes/manifests/
```

On a rebuilt node, put `kubeadm/pki` back to `/etc/kubernetes/pki` first, so
the cluster keeps its certificate authority; with several etcd members, each
member restores the same snapshot with its own name and the full
`--initial-cluster` (etcd's documentation). Neither was tested here.

## SQLite databases

Many applications keep their data in a SQLite file on a volume. The node
backup archives such a file from the host while the application writes it.
Archived like that, the database and its `-wal` or `-journal` file are read
at different moments, and the copy is often unusable: on a test cluster, raw
copies taken under write load, with a second between the files as Borg reads
them, were corrupt in 10 of 10 cases in WAL mode and 6 of 10 with a rollback
journal. `node.sqlite` archives a consistent copy instead, made with SQLite's
online backup (what `sqlite3 DB ".backup COPY"` does):

```yaml
node:
  sqlite:
    enabled: true
    databases:
      - namespace: vaultwarden
        pvc: vaultwarden-data   # the claim of the application's volume
        path: db.sqlite3        # the database, relative to the volume's root
```

Before each node backup, every node pod resolves each claim to its volume
through the API and copies the database if the volume is on its node:

| Volume | Where the node pod reads it | Copied by |
| --- | --- | --- |
| `local` (the local-path provisioner), `hostPath` | the volume's path on the node | the node its node affinity names; without one, a node that has the file |
| any other (CSI, NFS, …) | the kubelet's mount for a pod, `<kubeletDir>/pods/<pod>/volumes/…/<volume>` | a node with a running pod that mounts it |

A node without the volume skips the database, and so does every node while no
pod mounts a CSI volume (nothing writes it then, and nothing can read it). A
volume shared by pods on several nodes (`ReadWriteMany`) is copied by each of
them. `node.sqlite.kubeletDir` is the kubelet's root directory, for
distributions that move it (k0s: `/var/lib/k0s/kubelet`).

The copy runs read-only through the host root and honours the application's
locks, across the pods: a database in WAL mode stays writable during the
copy; one with a rollback journal makes the application's writers wait until
the copy is done (as long as it takes to read the file; on the test cluster
under 0.1 s for 25 MB). The copy waits for an application's write lock at
most `node.sqlite.busyTimeout` seconds (default 60). A rollback-journal
application that crashed in a transaction leaves a hot journal, which only a
writer can roll back: such a database cannot be copied read-only until the
application has started again.

What the node pods get for it:

- **Their own ServiceAccount**, `<release>-node`, with `get` on exactly the
  listed claims (one Role in each listed namespace) and `get` on
  PersistentVolumes (a ClusterRole: a claim's volume has a name only once it
  is bound). Nothing else, and no Secret. The listed namespaces have to exist
  when the chart is installed, since it creates the Roles in them.
- **`mountPropagation: HostToContainer` on `/node`**, which stays read-only:
  without it, a volume the kubelet mounts after the node pod started (CSI) is
  an empty directory below `/node`.
- **An `emptyDir` on the node's disk** for the copies, as large as the
  databases (`node.sqlite.sizeLimit`, default none).

Each copy is a single SQLite file, mode 600, in the journal mode of its
database, checked with `PRAGMA quick_check`, and archived as

```
var/lib/k8s-borg/sqlite/<namespace>/<pvc>/<path>
```

It exists only for the run: it is removed after the backup.

- **Interval mode:** `run.sh` makes the copies before `borg-backup` and
  removes them on every way out.
- **Agent mode:** the chart publishes `sqlite-copy` and `sqlite-copy-clean` to
  the node agent and attaches them to the node plan like the datastore
  snapshot: the copies as a pre-backup hook (before the snapshot), their
  removal as a post-backup hook, run whatever the backup's result.

A database that cannot be copied fails the step with rc 2, and the others are
still copied. The reasons are a claim that does not exist or is not bound, a
file missing on the node that has the volume, a path leading out of the
volume, or a copy that fails or does not check. A failed step does not stop
the file backup, and fails the run. In agent mode Borg UI can only show it as
a warning (`continue_on_error`).

Not covered: a database encrypted at the file level (SQLCipher), which
SQLite cannot open without its key; and a database path that is an absolute
symlink. For applications with an export of their own (`gitea dump`, for
example), archiving that export is an alternative that needs no rights on the
nodes.

### Restore

The restore is done by hand. This procedure is what the end-to-end test
(`tests/e2e/db/sqlite.bats`) does with the copies after they went through Borg.

```sh
borg extract "$BORG_REPO::<archive>" var/lib/k8s-borg/sqlite/<namespace>/<pvc>      # Borg 1
borg -r "$BORG_REPO" extract <archive> var/lib/k8s-borg/sqlite/<namespace>/<pvc>    # Borg 2
```

1. Stop the application (scale it to 0), so that nothing has the database open.
2. Replace the database in the volume with the copy, for example from a
   temporary pod that mounts the claim, and remove the old database's `-wal`,
   `-shm` and `-journal` files next to it: they belong to the old file.
3. Give the file the owner and mode the application expects (the copy is
   root's, mode 600).
4. Start the application again.

## Repository server (optional)

`repoServer.enabled=true` adds a Borg repository server to the release: `sshd`
as the unprivileged user `borg`, in a pod of its own, with every client key
bound to `borg serve` for one directory. It runs from the agent image, so server
and clients of one chart version carry the same Borg 2 and borgstore. One
replica, data on one node.

> **Borg 2 repositories are test beds.** Borg 2 is a beta, and its repository
> format has changed more than once without a conversion path. A repository
> server from this chart does not change that: do not rely on a Borg 2
> repository as your backup.

> **A cluster that backs up to a server inside itself needs that cluster to
> restore.** The data directory therefore is a plain directory on the node:
> without the pod — and without the cluster — it is read on the node with a Borg
> of the same version, as the directory's owner. For clients in other clusters
> the server is external and the point does not arise.

### One Secret

Server and clients share the ssh Secret (`ssh.*`, or `ssh.existingSecret`). For
the server it carries two more entries:

| Key | Content |
| --- | --- |
| `ssh_host_ed25519_key` | the server's host key, private part (`ssh.hostKey`) |
| `authorized_keys` | the clients' public keys, one per line (`ssh.authorizedKeys`) |

```sh
ssh-keygen -t ed25519 -N "" -C "" -f ssh_host_ed25519_key
```

The host key is handed in and never generated. It is the same after every
restart, and its public part is known before the first install — it is what goes
into the clients' `known_hosts`, as `[<host>]:<port> ssh-ed25519 AAAA…`.

`authorized_keys` is the usual file, without options:

```
ssh-ed25519 AAAA… cluster-a
ssh-ed25519 AAAA… cluster-b
ssh-ed25519 AAAA… restore-test
```

The comment names the client. An init container rewrites every line into one
that binds the key to `borg serve` for a single directory, without shell, PTY or
forwarding, and stages it together with the host key with the modes `sshd`
insists on. The server container mounts what was staged read-only; it sees
neither the Secret nor anything it could change. A line that carries options, a
comment that is no plain name, or a damaged key stops the start.

**Adding a client is adding a line.** It gets the directory named after it and
`repoServer.defaultPermissions`. The pod reads the Secret at start: restart it
after a change (`kubectl rollout restart statefulset/<release>-repo-server`).
With a Secret the chart renders itself, the restart happens on upgrade.

### Directories and permissions

Every client is confined to one directory below the data directory. With the
permissions `all` it creates repositories anywhere below it, on demand. Borg
checks the requested path against that directory by resolved path; nothing
outside can be reached.

`repoServer.clients` is only needed for a client that differs from the default:

```yaml
repoServer:
  enabled: true
  defaultPermissions: all
  clients:
    - name: cluster-b
      permissions: no-delete
    - name: restore-test        # a second key for cluster-b's repositories
      path: cluster-b
      permissions: read-only
```

| Permissions | Borg 2 | Borg 1 |
| --- | --- | --- |
| `all` | everything | everything |
| `no-delete` | read and write; no delete, no overwrite | `--append-only`: a delete or prune is recorded, not carried out |
| `write-only` | write; no read | no access |
| `read-only` | read; no write | no access |

They are enforced by the server (`borg serve --permissions`), not by the client.
Borg 1 has no permissions, only append-only, which is why a key that may only
read or only write gets no Borg 1 access at all. Append-only is the weaker
promise: the client's delete seems to succeed, and the data stays until someone
with full access compacts the repository. `repoServer.borg1=false` turns Borg 1
off altogether.

**The backup workloads of this chart need `all`.** They create their repository
and prune and compact after every backup, and only `all` allows the three. The
other permissions are for keys that do one thing: a second key that reads a
repository for a restore test, or a client that only runs `borg create` into a
repository someone else created and maintains.

### Repository URLs

| Client | URL |
| --- | --- |
| Borg 2.0.0b25 and later | `ssh://borg@<host>:<port>/<client>/<repository>` |
| Borg 2 up to 2.0.0b24 | `rest://borg@<host>:<port>/<client>/<repository>` |
| Borg 1 | `ssh://borg@<host>:<port>/./<client>/<repository>` |

The path is relative to the data directory. Nothing is wired up for the
workloads of the release itself: set `borg.repoBase` and the `known_hosts` entry
as for any other server.

Two things a client has to know:

- **Borg 2 ignores the port of the URL once `BORG_RSH` or `BORGSTORE_RSH` is
  set.** It takes the remote shell command as it is. A client with its own
  command has to name the port there: `BORG_RSH="ssh -p 2222 …"`.
- **Borg 1 creates a repository only in a directory that exists.** The client's
  own directory does; anything deeper has to be created on the server first.
  Borg 2 creates the directories in between.

Clients in other clusters run the Borg of their own release. When a Borg 2 beta
changes the protocol, upgrade the release that runs the server first.

### Reaching the server

One Service for every client (`repoServer.service`):

| `type` | Reachable from |
| --- | --- |
| `ClusterIP` (default) | pods of the cluster, as `<release>-repo-server.<namespace>.svc` |
| `NodePort` | also from outside, on every node's address (`nodePort` fixes the port) |
| `LoadBalancer` | also from outside, on the load balancer address (`loadBalancerIP`, `loadBalancerClass`, `loadBalancerSourceRanges`, `annotations` — e.g. `metallb.io/loadBalancerIPs`) |

Pods of the cluster use the Service name with every type.
`externalTrafficPolicy: Local` keeps the client address in the `sshd` log; then
only the node running the pod answers.

### Storage and the user

| `repoServer.persistence` | |
| --- | --- |
| `existingClaim` | a claim you manage |
| `local.createPV` + `local.nodeName` + `local.path` | a static `local` PersistentVolume for a directory on one node, and its claim. The volume's node affinity pins the pod to that node |
| neither | a claim from `storageClassName` (or the default class) |

The pod mounts no `hostPath`, runs without root and without capabilities, on a
read-only root filesystem — nothing a restricted namespace forbids.

The server runs as `repoServer.runAsUser`/`runAsGroup` (default `20222`,
deliberately not a uid other charts commonly use: a second workload with the
same number on the node could read the repositories). **The data directory has
to exist and belong to that user**; the chart does not change ownership. The
server sets it to mode `0700` and creates everything below it readable for this
user only.

```sh
# on the node, once
install -d -o 20222 -g 20222 -m 0700 /srv/borg
```

Volume and claim created by the chart are kept on `helm uninstall`.

### External copy

`repoServer.offsite.enabled=true` adds a CronJob that copies every repository
below the data directory to an rclone remote: S3-compatible storage, an SFTP
target such as a Hetzner Storage Box, or any other remote rclone knows. It is
there for one case: the server's storage fails.

> **The copy is a mirror, not a second backup.** What a client deletes or
> compacts disappears from the copy with the next run. Against deletions by a
> client there is `no-delete` (see above); against everything else — a
> compromised server included, which holds the credentials of the remote —
> only the remote itself helps: versioning or object lock on a bucket, snapshots
> of a Storage Box.

What the job does:

- **It reads the server's volume read-only**, as `repoServer.runAsUser`, on the
  server's node, without root or capabilities, like the server itself. The
  clients notice nothing and never see the remote's credentials.
- **One repository at a time, at the same path below `target` as below the data
  directory.** A repository that does not exist locally is never touched on the
  remote: a server that starts on a new, empty volume does not empty the copy.
  A repository a client deletes altogether stays on the remote until you remove
  it there.
- **No lock and no passphrase.** Borg 2 seals its locks with the repository key,
  and the server never holds one. Instead every repository is copied in the
  order Borg writes it — segments or packs first, then what refers to them, then
  the deletions — and the copy only counts if nothing in the repository changed
  meanwhile and no client held a lock at either end. Otherwise it is taken
  again, `retries` times at most. **Schedule it outside the backup windows**:
  a repository that keeps changing fails the run.
- **A failed run is a failed Job** (`backoffLimit: 0`); its log names every
  repository that was not copied. The others are copied all the same. A run
  by hand: `kubectl create job --from=cronjob/<release>-repo-server-offsite offsite-now`.

```yaml
repoServer:
  offsite:
    enabled: true
    target: offsite:k8s-borg        # <remote>:<path>, the remote from rclone.conf
    schedule: "0 4 * * *"
    bwlimit: "08:00,2M 20:00,off"   # rclone --bwlimit, optional
    rcloneConfig:
      existingSecret: k8s-borg-offsite   # key rclone.conf
```

`rcloneConfig`, `sshKey` and `knownHosts` each take a `value` or an existing
Secret (`existingSecret`, `existingSecretKey`), and are mounted as
`/etc/borg-offsite/rclone.conf`, `ssh_key` and `known_hosts`. Further rclone
options go to `extraArgs`; `transfers` (default 4) is how many files move in
parallel.

S3-compatible storage:

```ini
[offsite]
type = s3
provider = Other
endpoint = https://s3.example.com
region = eu-central-1
access_key_id = …
secret_access_key = …
# a key that may not create buckets:
no_check_bucket = true
```

A Hetzner Storage Box (or any SFTP server), with `sshKey` and `knownHosts`:

```ini
[offsite]
type = sftp
host = u123456.your-storagebox.de
port = 23
user = u123456
key_file = /etc/borg-offsite/ssh_key
known_hosts_file = /etc/borg-offsite/known_hosts
```

```sh
ssh-keyscan -p 23 u123456.your-storagebox.de   # the line for knownHosts
```

Without `known_hosts_file` rclone accepts any host key.

#### Restoring from the copy

**Rebuild the server** after its storage failed:

1. Set `repoServer.offsite.suspend: true`, so that the job does not take a
   half-restored repository for the current one and trims the copy to it.
2. Provide the new data directory, owned by `repoServer.runAsUser` (see above).
3. Copy the repositories back as that user, **with umask 077**: rclone would
   leave the files readable for everyone.

   ```sh
   umask 077
   rclone --config rclone.conf copy offsite:k8s-borg /srv/borg   # as uid 20222
   ```

4. Start the server, then set `suspend: false` again. The clients keep their
   URLs.

**Borg 1 clients that backed up after the last copy refuse the repository**:
"Cache, or information obtained from the security directory is newer than
repository". The archives since the last copy are lost; to carry on, the client
forgets what it knew of this repository — its id is the `id` line of the
repository's `config` — and rebuilds its cache:

```sh
rm -rf ~/.config/borg/security/<id> ~/.cache/borg/<id>   # below BORG_BASE_DIR, if set
```

Borg 2 clients carry on as they are.

**Read the copy directly**, without a server:

| Target | Borg 2 | Borg 1 |
| --- | --- | --- |
| S3 | `s3:<key-id>:<secret>@https://s3.example.com/<bucket>/<path>` | download it with `rclone copy`, then open the local directory |
| Storage Box | `sftp://u123456@u123456.your-storagebox.de:23/<path>` | `ssh://u123456@u123456.your-storagebox.de:23/./<path>` with `--remote-path=borg-1.4` — the box runs Borg 1 itself |
| other rclone remote | `rclone:<remote>:<path>` | download it with `rclone copy` |

- A client that knew the repository at the server asks before it opens it at
  another place, and gives up without a terminal: set
  `BORG_RELOCATED_REPO_ACCESS_IS_OK=yes`.
- The passphrase is needed as always. A repository in a keyfile mode also needs
  the client's key file, which is not in the copy.
- Borg 2 over sftp moves everything through one stream, and `borg check` reads
  the whole repository. For a large restore from a Storage Box, download the
  copy with rclone first (parallel transfers) and restore from the local
  directory.
- Run `borg check` on what you restored.

## Borg 1 vs 2

`borg.version` (`1` or `2`) selects the borg **binary** used by the scripts. The
**transport** is the URL scheme in `borg.repoBase` and is independent of the
version: `ssh://` (server has borg installed, works with 1 and 2) or `sftp://`
(plain SFTP target with no server-side borg — borg 2 only).

The two majors read the same `ssh://` URL differently:

| | relative to the login directory | absolute |
| --- | --- | --- |
| Borg 1 | `ssh://user@host:22/./cluster` | `ssh://user@host:22/srv/cluster` |
| Borg 2 | `ssh://user@host:22/cluster` | `ssh://user@host:22//srv/cluster` |

| | Borg 1 | Borg 2 |
| --- | --- | --- |
| `borg.remotePath` (`BORG_REMOTE_PATH`) | the `borg` wrapper adds `--remote-path=<value>` to every call | read by Borg itself; the option no longer exists (removed in 2.0.0b22) |
| `borg.encryption` (`BORG_ENCRYPTION`, read by `borg-init` and `register-repo`; empty = the default) | `repokey-blake2` (default), `repokey`, `keyfile-blake2`, `keyfile`, `authenticated-blake2`, `authenticated`, `none` | `repokey-aes-ocb` (default), `repokey-chacha20-poly1305`, `keyfile-aes-ocb`, `keyfile-chacha20-poly1305`, `authenticated` (= `authenticated-sha256`). No `none`, no `authenticated-blake3` (Borg UI has no name for it) |
| `borg.passphrase` | needed for the modes with a key | mandatory: from 2.0.0b25 on there is no repository without a key, and every command needs it, `break-lock` and `repo-delete` included |
| port | taken from the URL | taken from the URL, unless a remote shell command is set (`BORG_RSH`, `BORGSTORE_RSH`): that command is used as it is and has to name the port, `ssh -p 2222`. The chart sets neither |
| `rest://` | never a repository URL | the name of `ssh://` up to 2.0.0b24; refused from 2.0.0b25 on |

`borg.encryption` sets the mode of the repositories the pods create. A mode the
chosen `borg.version` does not have fails the render with the list of valid
ones. It never changes a repository that exists: `borg-init` only creates one
where there is none, and `register-repo` sends the mode only when it records a
repository for the first time. A record it moves to a changed base keeps its
mode, so `register-repo` moves it only when that mode is the one `borg-init`
created the new repository with. Otherwise the pod stops and names both modes
and both paths: change `borg.repoBase` and `borg.encryption` in the same
upgrade, and you remove the record in Borg UI (without deleting data) so that
the pod registers the repository anew, with its mode.

### Keyfile modes and where the keys live

The keyfile modes (`keyfile`, `keyfile-blake2` for Borg 1, `keyfile-aes-ocb`,
`keyfile-chacha20-poly1305` for Borg 2) keep the repository's key outside the
repository, in a file of the client. The passphrase does not replace that
file: a repository without its key cannot be read.

Every backup workload sets `BORG_KEYS_DIR=/etc/borg-ui-agent/borg-keys`, in
every mode, so Borg writes its key files to the `persistence.uiAgent` volume,
next to the agent's `config.toml`. That volume is mounted per node
(`<volume>/<node>/borg-keys`), and the cluster CronJob and the console pod
share the cluster's directory, so both read the key the first of them wrote.
The volume is kept on `helm uninstall` (`persistence.uiAgent.retain`). Borg
finds a key by the repository id inside the file, not by the file name.

- **Export the key after the first backup** and keep it apart from the
  cluster: a lost volume means repositories nobody can read.

  ```sh
  # Borg 1
  kubectl -n <namespace> exec <pod> -- sh -c 'borg key export "$BORG_REPO"' > <node>.borg-key
  # Borg 2
  kubectl -n <namespace> exec <pod> -- sh -c 'borg2 key export' > <node>.borg-key
  ```

  Import brings it back into `BORG_KEYS_DIR` of a pod of the same node:

  ```sh
  # Borg 1
  kubectl -n <namespace> exec -i <pod> -- sh -c 'borg key import "$BORG_REPO" -' < <node>.borg-key
  # Borg 2
  kubectl -n <namespace> exec -i <pod> -- sh -c 'borg2 key import --key-location=keyfile -' < <node>.borg-key
  ```

  Borg 2 needs `--key-location=keyfile`: without it, the imported key is stored
  in the repository as a repokey key, not in `BORG_KEYS_DIR`.

  A key the chart took from a Secret could only serve such a restore: Borg
  creates the key when it creates the repository, so it cannot be supplied in
  advance.
- **An agent reset removes `config.toml` only.** Wiping the node's whole
  directory on that volume deletes `borg-keys/` with it.
- **Borg UI never gets the key**, just as it never gets the agent's SSH key:
  `register-repo` records the repository without it, and Borg UI is meant to
  run every operation on an agent's repository through the agent, which reads
  the key in the pod. An operation Borg UI still runs on its own server for
  such a repository fails for a keyfile repository.

### Upgrading to Borg 2.0.0b25

This concerns releases with `borg.version: 2`. **Borg 1 repositories are not
affected.** Which Borg 2 an image carries: `borg2 --version` in a pod.

> **Borg 2 repositories are test beds, not backups to rely on.** Borg 2 is a
> beta. 2.0.0b25 cannot open a repository written by 2.0.0b22–b24 (exit 15,
> "is not a valid repository"), and there is no conversion in place: every
> Borg 2 repository is created anew, and the history in the old one ends.

What changes for the clients:

- **`rest://` becomes `ssh://`.** The path rules are the same. 2.0.0b25 does not
  reject the old scheme, it reads the URL as a local directory and would back up
  into the pod's own filesystem. The chart therefore refuses a
  `borg.repoBase.value` that starts with `rest://`, and the `borg2` wrapper
  refuses such a repository before Borg runs when the Borg 2 of the image is
  2.0.0b25 or later. A base from an existing Secret is only seen by the wrapper.
  The wrapper goes by the Borg 2 of the image, the chart cannot: a release that
  pins an image with an earlier Borg 2 takes its `rest://` base from an existing
  Secret.
- **`BORG_ENCRYPTION=none` is refused**, `authenticated` creates an
  `authenticated-sha256` repository.
- **The passphrase is needed for every command.**

Before the upgrade, with the release that is still running:

1. **Restore what you still need** from the Borg 2 repositories. Where the
   history itself matters, the only bridge is one archive at a time, with both
   Borg versions side by side: `borg export-tar --tar-format BORG` from the old
   repository into `borg import-tar` of the new one. The archives get new ids.

Then, in this order:

2. **Repository server first.** It has to run the borgstore that belongs to
   2.0.0b25 (0.7.0, with the `blake3` extra); clients up to 2.0.0b24 keep
   working against it. For the [repository server](#repository-server-optional)
   of this chart that is the upgrade of the release that runs it.
3. Stop the backups of the Borg 2 repositories (suspend the CronJob, pause the
   plans and schedules in Borg UI) and wait for running jobs.
4. On the server, **move the old repository directories aside. Do not delete
   them.**
5. **Upgrade the release.** With the base in `borg.repoBase.value`, change it to
   `ssh://` in the same step; the chart does not render otherwise.
6. **Then the base URL**, where it comes from an existing Secret: change it to
   `ssh://` and restart the pods. Until then they refuse to run Borg 2 and say
   why; nothing is written anywhere.
7. The pods create the repositories (`borg-init`) and move their records in
   Borg UI to the new URL. Borg UI checks a changed URL from its own server:
   when that server cannot reach the repository, it refuses, and the pod stops
   with both URLs and Borg UI's answer. It also stops, naming both modes, when
   the record's encryption mode is not the one the pod created the repository
   with; a Borg 2 record that a pod of an earlier release registered carries
   the Borg 1 name `repokey-blake2`. Change the record there by hand, or remove it
   from Borg UI without deleting data, so that the pod registers it anew.
8. Check one repository: `borg-info` prints `Repository version: 5`. Run a
   backup and a restore into an empty directory, then resume the backups.
9. Delete the directories of step 4 once the new repositories hold backups you
   have verified.

**Rollback** is the previous release with the previous base URL and the
directories of step 4 moved back. It works only as long as those directories
exist. What 2.0.0b25 has written in between cannot be read by an earlier beta.

## Versioning

`appVersion` is the agent image version, and `image.tag` defaults to it — the
agent image tag is never written down a second time. `version` is `appVersion`
for a new agent release, and gains a `-N` suffix for chart-only changes on top
of it (`1.0.23-1`, `1.0.23-2`, …).

The UI image is a different lifecycle: `borgUI.image.tag` follows the pinned
`borg-ui` submodule. It is `git describe` of the pinned commit against
borg-ui's release tags (`docker/ui-app-version.sh`): `2.3.10` when the pin is
exactly tag `v2.3.10`, `2.3.10-27-gcdd5712c9` for a commit after it. Every pin
gets its own image that way; borg-ui's `VERSION` file stays the same across
many commits, and a tag reused for another pin would overwrite the image an
older chart version still points at.

The managed agent's own version comes from the pin too. Borg UI raises it only
at a release, so a pin past a release that changed the agent gets that pin's
distance appended in both images (`2.3.10-64-g…` → agent `0.1.21.64`,
`docker/agent-version-stamp.sh`): it sorts above the release and below the
next one, and enrolled agents are offered the new code. A pin at a release tag,
or one that left the agent unchanged, keeps the plain version.
The `annotations.images` block in `Chart.yaml` restates all of this for chart
scanners, so it has to be updated along with any bump.

`tests/chart-versions.bats` enforces the whole set — a mismatch fails CI rather
than shipping a chart that points at an image tag nobody built.

## Parameters

Parameters are grouped and documented inline in [`values.yaml`](values.yaml)
(`## @param`). Key sections:

| Section | Highlights |
| --- | --- |
| `image`, `initImage` | agent image (defaults to appVersion) |
| `borg` | `version`, `repoBase`, `passphrase`, `remotePath`, retention, archive naming — see [Borg 1 vs 2](#borg-1-vs-2) |
| `s3` | S3 sources mounted via s3fs: `endpoint`, `region` (SigV4 region; empty = s3fs's `us-east-1`, which servers that check the region, such as Garage, refuse), `mountPath`, credentials, `verifyListing`, `onMountFailure`. A bucket that cannot be listed within 30 seconds after mounting is reported with the bucket, endpoint and region. With `onMountFailure: skip` (default) the start goes on without it and stops only when no bucket can be mounted (a wrong endpoint, region or credentials); each cluster backup then ends with a warning that names the bucket (in plan mode through the pre-backup hook `s3-check-mounts`, as a warning in Borg UI; the hook continues on error, so the other sources are backed up even when no bucket is mounted). With `onMountFailure: fail` one such bucket stops the start. Before each cluster backup, `verifyListing` (default on) compares each mount with the bucket's listing through the S3 API; a mount that misses objects, or that is not mounted, is mounted again, and one that still misses them fails the run. In plan mode the console pod's mounts live as long as the pod, so each plan run first mounts every bucket fresh (pre-backup hook `s3-remount-buckets`, the same mount and policy as at the start), then runs the check as the hook `s3-verify-listing`, ahead of `s3-check-mounts`, and a bucket that still misses objects ends the run with a warning in Borg UI (Borg UI has no way to fail a plan run after its backup) |
| `ssh`, `databases` | SSH key + MariaDB/MySQL/PostgreSQL/MongoDB logical-dump and Redis/Valkey RDB configs (→ Secrets) |
| `node` / `cluster` | the two backup scopes. `node` is the DaemonSet; `cluster` is the CronJob **and** the console/agent StatefulSet (they share `cluster.nodeName`/`resources`/`extraVolumes`/`nodeSelector`/`affinity`/`tolerations`, pinned to the storage node). `cluster.mode` (legacy/agent) and `cluster.backupMode` (cronjob/plan) select enrollment and scheduling. Borg include/exclude patterns (+ `cluster.s3Buckets`) live under each scope: `node.include`/`node.exclude`, `cluster.include`/`cluster.exclude`. `node.datastoreSnapshot` adds the cluster datastore — see [Cluster datastore snapshot](#cluster-datastore-snapshot) |

> **Upgrade note (1.0.21):** two breaking value renames — the chart fails fast if
> the old sections are still set.
> - `app` merged into `cluster`: `app.mode`→`cluster.mode`,
>   `app.agentScripts`→`cluster.agentScripts`, drop `app.enabled`/`app.nodeName`/… —
>   the console pod now shares the `cluster.*` pod settings with the CronJob.
> - `config` split into `node`/`cluster`: `config.clusterInclude`→`cluster.include`,
>   `config.clusterExclude`→`cluster.exclude`, `config.s3Buckets`→`cluster.s3Buckets`,
>   `config.nodeInclude`→`node.include`, `config.nodeExclude`→`node.exclude`.
| `borgUI` | optional server (Deployment/Service/Ingress), `agentConnection`, `reconcile` Job, `oidc`, `remoteMachines`, `notifications` (see [Notification channels](#notification-channels-borguinotifications)), `redis` (archive-listing cache: `mode: internal` deploys a dedicated Redis pod that survives UI-pod rolls, or `external` points at an existing instance) |
| `persistence` | NFS source, cache, UI state PVCs (+ optional static NFS PVs) |
| `repoServer` | optional repository server: `sshd` + `borg serve`, clients from `authorized_keys` in the ssh Secret, `service`, `persistence` — see [Repository server](#repository-server-optional) |

### When the reconcile Job fails

The reconcile Job (`<fullname>-reconcile-<revision>`, e.g.
`k8s-borg-reconcile-12` for revision 12 of a release named `k8s-borg`) runs once
per install/upgrade; the agent pods wait for it in their `wait-for-reconcile` init
container. When it fails, the `FATAL` line names the request that failed and
why (curl's message, or the HTTP status with what the server said). It can be
read in four places:

- the Job log, `kubectl logs job/<fullname>-reconcile-<revision>` —
  the Job and its pod are kept for `borgUI.reconcile.ttlSecondsAfterFinished`
  (a day by default);
- the pod status, `.status.containerStatuses[0].state.terminated.message`;
- the ConfigMap `<fullname>-reconcile-status`, `data.lastError`, with the revision and the
  time — kept until the next successful run;
- the log of a waiting agent pod's `wait-for-reconcile`, which prints that
  `lastError` when it belongs to its revision.

`borgUI.reconcile.waitSeconds` (default 300) is how long the Job waits for the
server's `/health`, counted from the start of the Job's container. When the
release waits for the Job, image pull time plus `waitSeconds` must stay below
the release timeout (HelmRelease `spec.timeout`, `helm --timeout`).

### Licensing (`borgUI.licensing`)

Borg UI evaluates its plan from a signed entitlement in its own database. By
default the server contacts `https://license.borgui.com` on startup and refreshes
every 24h; the plan itself is then checked locally.

Air-gapped installs turn the phone-home off:

```yaml
borgUI:
  licensing:
    startupSync: false
    activationServiceUrl: ""
```

The license can travel with the release instead of being clicked into the UI —
the reconcile Job applies it on every install/upgrade:

```yaml
# online: activate a key (only while the instance carries no paid license)
borgUI.licensing.licenseKey.value: "…"        # or .existingSecret/.existingSecretKey

# air-gapped: import an already-signed entitlement document, no egress
borgUI.licensing.entitlement.existingSecret: "borgui-entitlement"
```

```bash
kubectl create secret generic borgui-entitlement -n borg \
  --from-file=entitlement.json=/path/to/entitlement.json
```

`scripts/dump-entitlement.py` exports the entitlement an already-licensed instance
holds, in exactly that file format — useful both as a license backup and to seed
the Secret above.

The offline document is issued for the `instance_id` the server generates on its
first boot, so it is a two-step process: install, read the `instance_id` (Settings
> Licensing, or the reconcile Job log, which prints it), get the document, then
set the Secret and upgrade.

That `instance_id` lives only in the database, so wiping the database gives the
instance a new identity and the stored document stops applying to it. Setting
**both** values covers that: the document is used while it matches, and once it
doesn't, the key — which is instance-independent — takes over and has a fresh
entitlement issued. Re-export the document afterwards; the old one is stale. A
stale document with no key configured fails the reconcile rather than quietly
dropping the instance to the community plan.

Nothing is re-applied without cause. An instance already holding a paid license is
never re-activated (no seat is burned on an upgrade), and a document is imported
only when the instance is unlicensed or the document outlives what it currently
holds — a live instance renews its entitlement by itself, and re-asserting an older
copy from the release would roll that back.

The activation service may still count the old instance as holding the license, so
deactivate a paid license (Settings > Licensing) before deleting an instance you
intend to rebuild.

### Notification channels (`borgUI.notifications`)

A fresh Borg UI has no notification channel, so every failed backup stays
silent until somebody adds one in the UI. The reconcile Job can provision them
from the release instead:

```yaml
borgUI:
  notifications:
    - name: ops-mail
      email:
        smtp: { host: smtp.example.com, port: 587, mode: starttls }   # mode: starttls | ssl | insecure
        username: alerts@example.com
        password:                       # the only secret: value or existingSecret+existingSecretKey
          existingSecret: borgui-mail
          existingSecretKey: password
        from: alerts@example.com
        fromName: "Borg UI prod"        # optional
        to: [ops@example.com]           # cc, bcc, replyTo optional
      titlePrefix: "[prod]"
      events:                           # optional; omitted = the API defaults
        backupWarning: true
    - name: chat                        # anything that is not e-mail: a whole Apprise URL
      serviceUrl:
        existingSecret: borgui-notifications
        existingSecretKey: chat
```

An `email` channel keeps everything but the password in plain values, visible
in the release; the password reaches only a Secret and the Job. The Job assembles the Apprise `mailtos://` URL (`mailto://` for
`mode: insecure`) at run time and percent-encodes every part itself, so the
password needs no escaping. For any other Apprise service, `serviceUrl` takes
the whole URL from a Secret, since such URLs carry their token in the URL:

```bash
kubectl create secret generic borgui-notifications -n borg \
  --from-literal=chat='json://hooks.example.com/notify?token=…'
```

- **Matched by name.** A missing channel is created; an existing one is updated
  with only the fields that differ; an equal one causes no write. Channels with
  other names — made in the UI — are never touched.
- **Nothing is deleted.** Removing an entry leaves its channel in Borg UI;
  delete it in the UI.
- **Only what an entry names is enforced.** Without `events` a new channel gets
  the API defaults: every failure event, stale backups and the backup report on;
  start, success and warning off. A flag the values do not name keeps whatever
  the UI sets later. `enabled` defaults to `true`, so a channel switched off in
  the UI is switched on again by the next reconcile — set `enabled: false` to
  keep it off. `monitorAllRepositories: false` leaves the repository selection
  to the UI: the repositories the agents register do not exist yet when the
  reconcile Job runs.
- **Best effort.** A channel the server rejects (a malformed URL, say), or
  whose Secret or key does not exist, is a warning in the Job log; the release
  still succeeds and agents still start.
  The Job does not send a test message.
- **Credentials stay out of the manifests.** The SMTP password or a whole
  `serviceUrl` never lands in a ConfigMap or the Job's spec; the Job reads it
  from a Secret-backed variable and never prints it. Given as `value`, it goes
  into the chart Secret, but Helm also keeps it in the release's values, where
  anyone with access to the release reads it (`helm get values`). Use
  `existingSecret` when a credential must not be part of the release. A
  changed Secret is applied on the next reconcile run, see
  [Changing a referenced Secret](#changing-a-referenced-secret).

### Changing a referenced Secret

The reconcile Job copies what it reads from Secrets into the Borg UI database:
the notification passwords and service URLs, the OIDC client secret, the
license key and the entitlement document. It runs once per Helm revision. A
changed Secret referenced through `existingSecret` / `existingSecretKey` does
not make a new revision by itself: Flux upgrades only when the chart version
or the values change, so the server keeps the old content until the next
revision.

To apply such a change, start a new revision with the same values:

```bash
# Helm: every upgrade is a new revision
helm upgrade <release> <chart> -n borg --reuse-values

# Flux: an unchanged HelmRelease is not upgraded unless forced
flux reconcile helmrelease <release> -n borg --force
```

The reconcile run writes only what differs, so the rest of the server's
settings stay as they are. A new revision also rolls the agent pods (node and
cluster), because they wait for the reconcile of their revision; a backup
running in one of them is interrupted. Apply the change outside the backup
windows.

## Security posture

The backup pods run **privileged** with `SYS_ADMIN` (node backups also mount the
host `/` read-only). This is required to read arbitrary source paths and mount
FUSE. Keep the Borg UI Ingress restricted to trusted networks — it can reach
every repository.

With `node.datastoreSnapshot` the node archives hold every Secret of the
cluster, and with kubeadm its certificate authority's keys: whoever can read
the repository and has its passphrase holds the cluster, and in an
`authenticated*` or `none` repository whoever can read it.

With `node.sqlite` the node pods get a ServiceAccount of their own that may
read the listed claims and all PersistentVolumes, nothing else; the files they
copy are ones they could read through the host root already.

The repository server is the exception: unprivileged, no capabilities, read-only
root filesystem. It shares the ssh Secret with the backup pods, so those pods
can read its host key; keep `ssh_host_ed25519_key` out of the Secret of a
release that does not run the server. All clients are served by one user:
what keeps them apart is the directory their key is bound to, not file
ownership.
