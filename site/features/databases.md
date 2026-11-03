# Database dumps

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

The cluster backup archives the dumps only when `borg.dbBackupLocation`, or a
directory above it, is one of its roots in `cluster.include` (`R <path>`), and
no pattern of `cluster.exclude` leaves them out; the chart adds no root. When a
configured engine has no such root, the notes of `helm install` and
`helm upgrade` end with a `WARNING` that names the `R` line to add (a root
below the directory does not count; the notes do not look at
`cluster.exclude`): the dumps would be written, but not archived. It is a
warning, not an error, since a release may archive them some other way. In
plan mode (`cluster.backupMode=plan`) the plan takes only the roots that exist
when the console pod starts, and the dumps are written later, by its
pre-backup hooks: the pod creates `borg.dbBackupLocation` first, wherever it
is, on the pod's scratch volume under `/mnt` or on a volume of
`extraVolumeMounts`. A root on the dumps that the plan leaves out all the same
is named in the pod's log with a `WARNING` (the dumps would be written, but
not archived), and so is a directory the pod cannot create, such as one on a
read-only volume. In CronJob mode the dumps run first, so the directory exists
when the backup starts.

| Engine | File | Content |
| --- | --- | --- |
| PostgreSQL | `globals.sql` | `pg_dumpall --globals-only`: roles, password hashes, memberships, role settings, tablespaces |
| PostgreSQL | `<db>.dump` | `pg_dump -Fc -Z0`, one per database that allows connections (as `pg_dumpall`; others are named in the log), `postgres` and `template1` included: schema, data, privileges, extensions, the database's owner, settings and grants |
| MariaDB | `<db>.sql` | one per database, with routines, events and triggers |
| MariaDB | `<instance>-full-dump.sql` | every database (`-A`), the `mysql` schema with the users and grants included |
| MySQL | `<db>.sql`, `<instance>-full-dump.sql` | as MariaDB, written by MySQL's own `mysqldump` 8.4, without GTIDs |
| MongoDB | `<instance>.archive` | one `mongodump` archive of every database, users and roles included, with the oplog on a replica set — see [MongoDB dumps](/features/mongodb) |
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

::: tip Restore
Restoring the dumps is described under [Restore](/operations/restore#databases).
:::

## Privileges of the backup user

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
  `SYNC` cannot be dumped, nor can Dragonfly (see [Dragonfly](/features/redis-valkey#dragonfly)).

## PostgreSQL operators

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

## MariaDB servers without TLS

The image's MariaDB client (11.8) asks for TLS by default and refuses a server
that offers none, as a MariaDB before 11.4 without a certificate of its own
does. For such a server, set `tls: false` on a `secretRef` instance (the
resolver writes `skip-ssl` into its credentials file), or add a `skip-ssl`
line to the `[client]` section of a static `config`.

## MySQL and Percona Server

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
