# Cluster datastore snapshot

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

## Archive layout

```
var/lib/k8s-borg/datastore/k3s/etcd-snapshot.db    k3s, embedded etcd
var/lib/k8s-borg/datastore/k3s/state.db            k3s, SQLite
var/lib/k8s-borg/datastore/k3s/token               k3s server token
var/lib/k8s-borg/datastore/kubeadm/etcd-snapshot.db
var/lib/k8s-borg/datastore/kubeadm/pki/            /etc/kubernetes/pki
```

::: tip Restore
The restore, by hand on the node, is described under [Disaster recovery](/operations/disaster-recovery#cluster-datastore).
:::
