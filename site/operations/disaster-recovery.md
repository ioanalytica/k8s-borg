# Disaster recovery

For when more than data is lost: the control plane, or the storage of the
repository server. Both need the repository's passphrase and, for a repository
in a keyfile mode, its key.

## Cluster datastore {#cluster-datastore}

The restore is done by hand on the node. Each procedure below was carried out
once on a test cluster (k3d for k3s, kind for kubeadm) from an archive this
chart wrote: the objects from before the backup were back, the ones created
after it were gone, and the Secrets were readable. What a restore does to the
parts of the cluster that keep running was tested later on k3d (k3s 1.36) and
kind (Kubernetes 1.37, etcd 3.7), with snapshots `datastore-snapshot` took,
restored on the same node.

Get the files out of the archive with a Borg of the repository's version, for
example the one in this chart's image, onto the node being restored, into a
directory only root can read (`/root/restore` below). Delete them after the
restore.

```sh
borg extract "$BORG_REPO::<archive>" var/lib/k8s-borg/datastore      # Borg 1
borg -r "$BORG_REPO" extract <archive> var/lib/k8s-borg/datastore    # Borg 2
```

**The revision goes back.** A restore takes the datastore back to the
revision it had at the backup. Kubelets, kube-proxy, CoreDNS and other
controllers that keep running across it have seen higher ones: they resume
watching from there, get no event until the store passes it, and never learn
what the restore changed. In the tests, on kubeadm the kubelet kept running
pods the restore had removed, and the pods a Deployment's ReplicaSet created
after it stayed pending, as the kubelet never started them; kube-proxy and
CoreDNS kept serving a Service the restore had removed. On k3s, whose kubelet
and kube-proxy list anew when the server is back, CoreDNS did. They stayed so
until they were restarted. A running `kubectl get --watch` ends when the API
server stops, with the bump below or without it.

For etcd,
`etcdutl snapshot restore --bump-revision 1000000000 --mark-compacted` lifts
the revision above anything seen before and marks the older ones compacted, so
that a watch from an older revision fails and the client lists anew; with it,
the kubelet, kube-proxy and CoreDNS carried on without a restart. The bump has
to lift the revision above the highest the cluster reached: it counts the
writes since the backup and the bump of any restore since then (a second
restore of the same snapshot takes 2000000000). 1000000000 is the value of
etcd's recovery guide. `etcdutl` comes with the etcd release and with this
chart's image; the image's 3.6.15 restored the snapshots of etcd 3.7 (kind)
and 3.6 (k3s) in the tests. SQLite has nothing of the kind.

**k3s, embedded etcd** (tested on a fresh node with the same k3s version).
k3s restores a snapshot at the snapshot's revision and has no option to raise
it, so `etcdutl` makes a copy with the bump first. k3s checks the SHA-256 at
the end of a snapshot, which the copy gets appended. `etcdutl` refuses a data
directory that is not empty, so a second attempt starts with a clean one:

```sh
rm -rf /root/restore/etcd-bumped &&
etcdutl snapshot restore /root/restore/var/lib/k8s-borg/datastore/k3s/etcd-snapshot.db \
  --data-dir /root/restore/etcd-bumped --bump-revision 1000000000 --mark-compacted &&
cp /root/restore/etcd-bumped/member/snap/db /root/restore/etcd-snapshot-bumped.db &&
openssl dgst -sha256 -binary /root/restore/etcd-bumped/member/snap/db >>/root/restore/etcd-snapshot-bumped.db &&
systemctl stop k3s &&
K3S_TOKEN="$(cat /root/restore/var/lib/k8s-borg/datastore/k3s/token)" \
  k3s server --cluster-reset --etcd-s3=false \
  --cluster-reset-restore-path=/root/restore/etcd-snapshot-bumped.db
# go on only if the last message says the membership has been reset
systemctl start k3s
```

`--etcd-s3=false` keeps k3s to the local file where its configuration sends
snapshots to S3: k3s would look for the path in the bucket and fail.

k3s keeps its certificates in the datastore, encrypted with the token: a node
without the original token file refuses the restore without it. `K3S_TOKEN`
hands it to the reset without putting it into the process arguments, where
other users of the node could read it; k3s takes it neither from
`--token-file` nor from a token file put in place before the reset. A reset
that failed can still exit with 0, hence the look at its last message. The
reset leaves the token in `/var/lib/rancher/k3s/server/token`, from where k3s
reads it when its configuration names none. Where the configuration names one
(`token` or `token-file` in `/etc/rancher/k3s/config.yaml`, `K3S_TOKEN` in the
service's environment file), make it the archived one before the start: with
another, k3s stops with "bootstrap data already found and encrypted with
different token". With more than one server, k3s documents the rest: on each
other server stop k3s, move `/var/lib/rancher/k3s/server/db` away, and start
k3s to rejoin (not tested here).

**k3s, SQLite** (tested on a fresh node with the same k3s version). The token
goes back as a file, with the same rule for a token the configuration names:

```sh
systemctl stop k3s
mkdir -p /root/restore/old && mv /var/lib/rancher/k3s/server/db/state.db* /root/restore/old/
install -m 0600 /root/restore/var/lib/k8s-borg/datastore/k3s/state.db /var/lib/rancher/k3s/server/db/state.db
install -m 0600 /root/restore/var/lib/k8s-borg/datastore/k3s/token /var/lib/rancher/k3s/server/token
systemctl start k3s
```

After this restore, restart the pods that watch the API and kept running:
CoreDNS (`kubectl -n kube-system rollout restart deployment/coredns`), and any
other controller in a pod, such as an ingress controller or an operator. The
kubelets and kube-proxy of k3s, on the server and the agents, list anew by
themselves.

**kubeadm, local etcd** (tested on the same control-plane node). Take the
member name and peer URL from `/etc/kubernetes/manifests/etcd.yaml`:

```sh
mkdir -p /etc/kubernetes/manifests.stopped &&
mv /etc/kubernetes/manifests/{etcd,kube-apiserver}.yaml /etc/kubernetes/manifests.stopped/ &&
while crictl ps --name '^(etcd|kube-apiserver)$' -q | grep -q .; do sleep 1; done &&
rm -rf /var/lib/etcd-restored &&
etcdutl snapshot restore /root/restore/var/lib/k8s-borg/datastore/kubeadm/etcd-snapshot.db \
  --data-dir /var/lib/etcd-restored --name <member> \
  --initial-cluster <member>=https://<node IP>:2380 \
  --initial-advertise-peer-urls https://<node IP>:2380 \
  --bump-revision 1000000000 --mark-compacted &&
mv /var/lib/etcd "/var/lib/etcd.before-restore.$(date +%Y%m%d%H%M%S)" &&
mv /var/lib/etcd-restored /var/lib/etcd &&
mv /etc/kubernetes/manifests.stopped/{etcd,kube-apiserver}.yaml /etc/kubernetes/manifests/
```

The loop waits until the kubelet has stopped etcd and the API server. A
failure on the way leaves both stopped, so that the cluster does not come back
on the data from before the restore unnoticed; the data directory it had is
kept under its date.

The controller manager and the scheduler lose their lease while the API server
is down and restart by themselves.

On a rebuilt node, put `kubeadm/pki` back to `/etc/kubernetes/pki` first, so
the cluster keeps its certificate authority; with several etcd members, all of
them and their API servers stop first, and each member restores the same
snapshot with the same bump, its own name and the full `--initial-cluster`
(etcd's documentation). Neither was tested here.

## Repository server, from its external copy {#repository-server}

**Rebuild the server** after its storage failed:

1. Set `repoServer.offsite.suspend: true`, so that the job does not take a
   half-restored repository for the current one and trims the copy to it.
   Suspending starts no new Job but leaves a running one alone: wait until no
   Job of `<release>-repo-server-offsite` runs any more (`kubectl get jobs`).
2. Provide the new data directory, owned by `repoServer.runAsUser` (see [Storage and the user](/features/repository-server#storage-and-the-user)).
3. Copy the repositories back as that user, **with umask 077**: rclone would
   leave the files readable for everyone.

   ```sh
   umask 077
   rclone --config rclone.conf copy offsite:k8s-borg /srv/borg   # as uid 20222
   ```

4. Start the server. Set `suspend: false` again only once the copy back
   ended without an error and `borg check` passed on every repository: the
   next run makes the copy what the server holds. The clients keep their
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

## Borg keys {#borg-keys}

A repository in a keyfile mode cannot be read without its key file, which the
pods keep on the `persistence.uiAgent` volume. Export it after the first backup
and keep it apart from the cluster, as
[Keyfile modes and where the keys live](/features/borg-versions#keyfile-modes)
describes.
