# Node backups

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
