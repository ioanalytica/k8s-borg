# Restore

Restores are done by hand, from an archive. This page covers the database
dumps and the SQLite copies; the cluster datastore and the repository server
are under [Disaster recovery](/operations/disaster-recovery). The database
restores below run against real servers in CI on every push (see
[Test](/reference/development#test)).

## Databases {#databases}

Restore from an archive, not from `borg.dbBackupLocation` itself. A dump that
fails half-way leaves the dumps it finished next to the older ones of the
databases it did not reach, and its unfinished `*.tmp` file, until the next
good run; the archive never holds such a mix, because a failing dump stops the
backup before Borg runs. In the console pod, extract the instance's directory
into a new, empty directory with room for the uncompressed dumps, and point
`DB_BACKUP_LOCATION` at the copy of `borg.dbBackupLocation` below it, only
once the extraction succeeded:

```sh
# Borg 1
cd "$(mktemp -d /tmp/restore.XXXXXX)" \
  && borg extract --noxattrs --noacls "$BORG_REPO::<archive>" <dbBackupLocation>/<instance> \
  && export DB_BACKUP_LOCATION="$PWD/<dbBackupLocation>"
# Borg 2 (<archive> may also be aid:<id>)
cd "$(mktemp -d /tmp/restore.XXXXXX)" \
  && borg -r "$BORG_REPO" extract --noxattrs --noacls <archive> <dbBackupLocation>/<instance> \
  && export DB_BACKUP_LOCATION="$PWD/<dbBackupLocation>"
```

`<dbBackupLocation>` is `borg.dbBackupLocation` without its leading `/`, as
Borg stores paths. The console pod lives long: a directory that holds an
earlier extraction would mix its dumps with the new ones, hence a new one each
time; remove it after the restore. `--noxattrs --noacls`: dumps written to NFS carry the extended attribute
`system.nfs4_acl`, which another file system refuses, with one warning per
file and rc 1, which the wrapper counts as success.

Then restore with the instance's credentials file (static configs in
`/root/.<engine>/`, secretRef instances resolved there too):

| Command | Restores |
| --- | --- |
| `restore-postgres /root/.postgres/<instance>.conf --all [-j N]` | the whole instance: `globals.sql`, then every database dropped and created again with its properties. The dumped roles' attributes and passwords replace the server's, the role in the credentials file included |
| `restore-postgres /root/.postgres/<instance>.conf <db> [-j N]` | one database, dropped and created again with its properties |
| `restore-postgres /root/.postgres/<instance>.conf <db> --as <name> [-j N]` | the dump of `<db>` into `<name>` (dropped first), to compare before replacing; the database-level properties (owner, `ALTER DATABASE … SET`, its grants) are not applied |
| `restore-postgres /root/.postgres/<instance>.conf --globals` | roles and tablespaces alone (passwords as with `--all`) |
| `restore-postgres /root/.postgres/<instance>.conf <db> --use-list <file> [--as <name>]` | one database, only the entries of the list (`pg_restore -L`), see [PostgreSQL into another operator](#postgresql-into-another-operator). A list with a line that matches no entry of the dump, which `pg_restore` would skip, or without any entry is refused before anything is dropped |
| `restore-mariadb /root/.mariadb/<instance>.conf --all` | the whole instance from the full dump, users and grants included. Meant for an empty server: the dumped users replace the server's, the one in the credentials file included |
| `restore-mariadb /root/.mariadb/<instance>.conf <db>` | one database, dropped and created again |
| `restore-mariadb /root/.mariadb/<instance>.conf <db> --as <name>` | the dump of `<db>` into `<name>` (dropped first) |
| `restore-mysql /root/.mysql/<instance>.conf --all \| <db> [--as <name>]` | the same for MySQL |
| `restore-<engine> /root/.<engine>/<new>.conf … --from <instance>` | any of the above (and `restore-mongodb`), from the dumps of `<instance>` into the server of `<new>.conf`: a rebuilt or another server, a copy for tests |

Without `--from`, the dumps are those of the instance the credentials file is
named after (`<instance>.conf`). `-j N` sets pg_restore's parallel jobs (default 4; one for a server before 17). A database that is
replaced is dropped with `WITH (FORCE)`, which ends its sessions. Every error
ends a restore with rc ≥ 2. The image's `pg_restore` is PostgreSQL 18's;
for a server before 17 `restore-postgres` accepts the two statements of a
newer `pg_restore` that such a server rejects (`SET transaction_timeout`, and
`LOCALE_PROVIDER` before 15). Restores are tested against PostgreSQL 13–18,
MariaDB 10.11, 11.4 and 11.8, MySQL 8.4 and Percona Server 8.4.

A PostgreSQL dump can be read and edited as SQL without a server:
`pg_restore -f db.sql <db>.dump` writes the SQL, `pg_restore -C -l <db>.dump >
list` lists its objects, and `restore-postgres … <db> --use-list list`
restores only the ones left in the list. `-C` lists the database's own grants
and comment too, which a list of `pg_restore -l` lacks: the database is then
created again without them (with its owner and settings).

### PostgreSQL into another operator

`--all` is meant for a server of the same kind as the dumped one. Restoring
the dumps of a Zalando (Spilo) cluster into a CloudNativePG cluster (both
PostgreSQL 18, CloudNativePG 1.30.1) showed two pitfalls; a CloudNativePG to
CloudNativePG `--all` restore has neither (tested, with a switchover after
it).

**Extensions the target lacks.** Spilo creates extensions in every database
(`pg_cron`, `plpython3u`, `pg_auth_mon`, `pg_stat_kcache`, `set_user`) and the
schemas `metric_helpers` and `user_management` that depend on them;
CloudNativePG's images have none of them. `--all` stops at the `postgres`
database with errors, before the application databases. Restore the roles,
then each application database from a list without those entries (50 of
about 700 in the test), and leave the `postgres` database out:

```sh
restore-postgres /root/.postgres/<instance>.conf --globals
pg_restore -C -l "$DB_BACKUP_LOCATION/<instance>/<db>.dump" \
  | grep -Ev 'pg_cron|plpython3u|pg_auth_mon|pg_stat_kcache|set_user|metric_helpers|user_management' >/tmp/<db>.list
restore-postgres /root/.postgres/<instance>.conf <db> --use-list /tmp/<db>.list
```

Read the list before: an object of your own whose name holds one of these
words goes too. The database is created again with its owner, settings,
grants and comment.

**CloudNativePG's grants for `pg_rewind`.** CloudNativePG grants
`streaming_replica` four functions that `pg_rewind` needs, in the `postgres`
database only. A restore that replaces `postgres` from another operator's
dump (`--all`, or `restore-postgres … postgres`) drops them, and nothing shows
until the next switchover or failover: the old primary then loops on
`permission denied for function pg_read_binary_file` and never rejoins. Grant
them again in `postgres`, as a superuser:

```sql
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO streaming_replica;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO streaming_replica;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO streaming_replica;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO streaming_replica;
```

and check them (four times `t`):

```sql
SELECT f, has_function_privilege('streaming_replica', f, 'EXECUTE')
  FROM unnest(ARRAY['pg_catalog.pg_ls_dir(text, boolean, boolean)',
                    'pg_catalog.pg_stat_file(text, boolean)',
                    'pg_catalog.pg_read_binary_file(text)',
                    'pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean)']) f;
```

An instance already looping rejoins once its pod is restarted. A dump of a
CloudNativePG cluster carries the grants (`pg_dump` keeps changed privileges
of `pg_catalog` functions).

**The restoring user.** `--globals` (and `--all`) set the password of every
dumped role from the dump, the target's superuser included. A restore user
that is not in the dump keeps its own. In CloudNativePG, that can be the
bootstrap owner made superuser through a managed role, with its password from
a Secret that the source and a rebuilt cluster share
(`bootstrap.initdb.secret` and `managed.roles[].passwordSecret`).

## MongoDB {#mongodb}

From the console pod, after the instance's directory is extracted from an
archive as in [Databases](#databases):

| Command | Restores |
| --- | --- |
| `restore-mongodb /root/.mongodb/<instance>.conf --all` | the whole instance: each dumped collection dropped and restored, the users and roles, which replace the server's (the one in the credentials file included), and, for a replica set's dump, the oplog replayed. Databases the dump does not hold are left alone |
| `restore-mongodb /root/.mongodb/<instance>.conf --all --no-oplog` | the same without replaying the oplog |
| `restore-mongodb /root/.mongodb/<instance>.conf <db>` | one database, dropped and created again |
| `restore-mongodb /root/.mongodb/<instance>.conf <db> --as <name>` | the dump of `<db>` into `<name>` (dropped first), to compare before replacing |
| `restore-mongodb /root/.mongodb/<new>.conf … --from <instance>` | any of the above, from the archive of `<instance>` into the server of `<new>.conf` |

With an oplog, `--all` restores the users and roles first, on their own:
a user replaced by its dumped self (on another server, with another
`userId`) loses the session it is logged in with, which the replay after
them would then lack. The full restore after it logs in anew, as the
restored user of the credentials file, whose password must therefore be the
one in the dump; `--all --no-oplog` restores in one pass. `mongorestore`
names each database of the archive as a subdirectory it skips, in both
passes, and restores them all the same; the script leaves those lines out.

**Into another server.** `--all` replaces the server's users with the dumped
ones, an operator's own users included. Tested with the MongoDB Controllers
for Kubernetes 1.13.0 (`MongoDBCommunity`, MongoDB 7.0): the operator's agent
lost its automation user for about half a second, logged in with the replica
set's key file (`__system`) and created its user again; it recovered on its
own and kept working after a pod restart. The users defined in the resource
need the same passwords as on the source (a password Secret the source and
the target share), or the login after the users pass fails.

**`--no-oplog` under load.** The oplog is what makes a dump taken while the
server is written consistent. From a dump taken while a writer committed
about 33 transactions a second across two databases, `--all` replayed 66
oplog entries and the data was consistent; `--all --no-oplog` from the same
dump ended with rc 0, but one database stood 18 transactions behind the
other. Leave the oplog out only for a dump of a server that nothing wrote to
while it was dumped.

`mongorestore` replays the oplog only for the whole instance: a single
database comes back as each of its collections was when it was dumped. The
users and roles, also those defined on a database, and the `admin` database
are only restored with `--all`. A database the archive does not hold is
refused before anything is dropped. Every error ends a restore with rc ≥ 2.
Covered by the database end-to-end tests against MongoDB 7.0 and 8.2, replica
set and standalone (`tests/e2e/db/mongodb.bats`).

## Redis and Valkey {#redis-and-valkey}

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

### Dragonfly {#dragonfly}

To restore, extract `dump.rdb` from an archive. For a new instance, put it
into the instance's prefix with any S3 client before the instance is created:
it loads the file at its first start. For a running instance, stop it first —
Dragonfly writes a snapshot when it shuts down, which would replace the file —
then replace the file and start it again. Tested: a new instance loaded the
file and held the same keys as the source.

## SQLite {#sqlite}

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
