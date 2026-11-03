# Disaster recovery

For when more than data is lost: the control plane, or the storage of the
repository server. Both need the repository's passphrase and, for a repository
in a keyfile mode, its key.

## Cluster datastore {#cluster-datastore}

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
