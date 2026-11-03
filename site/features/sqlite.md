# SQLite databases

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

::: tip Restore
The restore is described under [Restore](/operations/restore#sqlite).
:::
