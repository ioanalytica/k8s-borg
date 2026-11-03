# MongoDB

When MongoDB is configured (see [Database dumps](/features/databases)),
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

::: tip Restore
Restoring an archive is described under [Restore](/operations/restore#mongodb).
:::

## Credentials

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

## Privileges

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
