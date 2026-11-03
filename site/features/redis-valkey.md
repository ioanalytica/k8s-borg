# Redis and Valkey

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

::: tip Restore
Restoring an RDB file is described under [Restore](/operations/restore#redis-and-valkey).
:::

## Dragonfly

Dragonfly speaks the Redis protocol but has no `SYNC`: it replicates only to
other Dragonfly instances, with a protocol of its own. `backup-redis` cannot
stream its snapshot, so an instance in `databases.redis` that reports
`dragonfly_version` fails at once with rc 2 and points here. Dragonfly writes
snapshots of its own instead, to S3 among other places, and k8s-borg backs the
bucket up like any other (tested with Dragonfly 2.0):

- The snapshot directory is a prefix of its own per instance,
  `s3://<bucket>/<ns>-<instance>/` (`snapshot.dir` with the Dragonfly
  operator, else `--dir`).
- `--s3_endpoint=<host>:<port>` for an S3 server other than AWS,
  `--s3_use_https=false` for one without TLS, `--df_snapshot_format=false` and
  `--dbfilename=dump`: one `dump.rdb`, an ordinary RDB file that each snapshot
  replaces, instead of Dragonfly's own format in several files.
- The credentials come from `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in
  Dragonfly's environment, with `AWS_REGION` (servers that check the region,
  such as Garage, refuse any other).
- A schedule (`snapshot.cron`, else `--snapshot_cron`) that writes the
  snapshot before the backup runs.
- In k8s-borg the bucket goes into `cluster.s3Buckets` (with `s3.enabled`);
  nothing Dragonfly-specific is needed.
