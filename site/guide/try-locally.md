# Try it locally

The whole chart in a throwaway [k3d](https://k3d.io) cluster on one machine,
with no host outside it: the release's own repository server as the Borg host,
a Borg UI server, the node and console pods enrolled at it as managed agents,
a first backup and a restore. It takes a few minutes, most of them for pulling
the images (about 550 MB). Tested with k3d 5.9 (k3s 1.36).

::: warning A cluster to try the chart in
The repositories live in a directory of the k3d node container and are gone
with the cluster. The passphrase and the keys are in the release's values.
Nothing here is a backup to rely on.
:::

| Part | What it does here |
| --- | --- |
| Repository server | `sshd` and `borg serve` in the release, its data in `/srv/borg` on the node; the backup pods reach it by its Service, with a key of their own |
| Node pod | backs up the node's `/etc` and a snapshot of k3s's datastore, as a managed agent with a backup plan |
| Console pod | enrolls as a managed agent with the cluster repository, and runs the cluster backup once it has a source (the optional database step) |
| Borg UI server | SQLite, the release's own Redis, the local admin login; it contacts neither the license service nor the error-report ingest |
| Reconcile Job | waits for Borg UI and mints the admin token the agents enroll with |

## What you need

- Docker, with about 2 GB of memory to spare
- [k3d](https://k3d.io), `kubectl`, [Helm](https://helm.sh), `ssh-keygen` and
  `openssl`

## 1. A cluster

```sh
k3d cluster create k8s-borg
```

k3d makes `k3d-k8s-borg` the current `kubectl` context. The cluster has one
node, `k3d-k8s-borg-server-0`, which the values below name. One node is all
this setup supports: the claims it uses belong to a single node.

The repository server needs its data directory on that node, owned by the uid
it runs as:

```sh
docker exec k3d-k8s-borg-server-0 install -d -o 20222 -g 20222 -m 0700 /srv/borg
```

## 2. Keys and passwords

```sh
mkdir k8s-borg-try && cd k8s-borg-try
# The backup pods' key. Its comment names the client on the repository server,
# and the client's directory there.
ssh-keygen -q -t ed25519 -N "" -C quickstart -f id_ed25519
# The repository server's host key, and the line the pods know it by.
ssh-keygen -q -t ed25519 -N "" -C "" -f ssh_host_ed25519_key
echo "[k8s-borg-repo-server.k8s-borg.svc]:2222 $(cut -d' ' -f1,2 ssh_host_ed25519_key.pub)" > known_hosts
openssl rand -hex 16 > passphrase
openssl rand -hex 12 > admin-password
```

## 3. Install

```sh
url=https://raw.githubusercontent.com/ioanalytica/k8s-borg/main/examples/k3d
kubectl create namespace k8s-borg
kubectl -n k8s-borg apply -f $url/claims.yaml
helm install k8s-borg oci://ghcr.io/ioanalytica/charts/k8s-borg -n k8s-borg \
  -f $url/values.yaml \
  --set borg.passphrase.value="$(cat passphrase)" \
  --set borgUI.adminPassword.value="$(cat admin-password)" \
  --set-file ssh.privateKey=id_ed25519 \
  --set-file ssh.publicKey=id_ed25519.pub \
  --set-file ssh.knownHosts=known_hosts \
  --set-file ssh.hostKey=ssh_host_ed25519_key \
  --set-file ssh.authorizedKeys=id_ed25519.pub
```

Without `--version`, Helm installs the latest release. The passwords go in
with `--set`: `--set-file` would keep the file's final newline as part of the
password. `claims.yaml` replaces the chart's own claims, which ask for
`ReadWriteMany`; k3s's `local-path` storage only offers `ReadWriteOnce`.

::: details The values: examples/k3d/values.yaml
<<< @/../examples/k3d/values.yaml
:::

The node and console pods wait for the reconcile Job, and the Job waits for
Borg UI. Then each pod enrolls, registers its repository, and the node pod
registers its backup plan, a few seconds after its rollout:

```sh
kubectl -n k8s-borg rollout status daemonset/k8s-borg-node --timeout=10m
kubectl -n k8s-borg rollout status statefulset/k8s-borg-app --timeout=10m
kubectl -n k8s-borg logs daemonset/k8s-borg-node | grep -E 'Enrolled|registered|Backup plan'
```

```
Enrolled (agent id 1).
Repository 'k8s-borg-k3d-k8s-borg-server-0' registered (agent id 1).
Backup plan 'backup-k8s-borg-k3d-k8s-borg-server-0' created for repo id 1 (no schedule — run manually).
```

The ids can differ. A log that ends with `Repository cannot be accessed!`
instead means the node pod started before the repository server could take
it: [start them again](#start-again). The node pod's log also warns that
`/node/etc/hostname`, `/node/etc/hosts` and `/node/etc/resolv.conf` are
skipped as other file systems: Docker mounts these three files into the k3d
node, and the node backup does not cross into another file system (see
[Node backups](/features/node-backups)).

## 4. Borg UI

In a second terminal, and left running there:

```sh
kubectl -n k8s-borg port-forward svc/k8s-borg-ui 8081:8081
```

The commands of the next steps go on in the first terminal, in
`k8s-borg-try`, where `$url` is set. Open `http://localhost:8081` and sign in
as `admin` with the password in `admin-password`. On the first sign-in Borg UI
asks whether the browser may send usage analytics; the chart has no switch
for that (see [Error reports](/features/borg-ui-server#error-reports)).

The chart has registered:

- two managed agents, `k8s-borg-k3d-k8s-borg-server-0` (the node pod) and
  `k8s-borg-mycluster` (the console pod, named by `cluster.nodeName`);
- a repository for each, of the same name, on the repository server;
- the node pod's backup plan, `backup-k8s-borg-k3d-k8s-borg-server-0`,
  without a schedule (`borg.backupSchedule` gives it one, see
  [Borg UI agents](/features/borg-ui-agents#check-and-backup-schedules)).

How to work with them in Borg UI is in the
[Borg UI documentation](https://docs.borgui.com).

## 5. A backup

Run the node pod's backup plan in Borg UI. It runs in the node pod: the
datastore snapshot first, as a pre-backup hook, then `borg create` of
`/node/etc` and the snapshot, `borg prune` and `borg compact`, and the
snapshot's removal. From the command line:

```sh
kubectl -n k8s-borg exec daemonset/k8s-borg-node -- borg list
kubectl -n k8s-borg exec daemonset/k8s-borg-node -- \
  sh -c 'borg list "::$(borg list --short --last 1)" var/lib/k8s-borg'
```

The second command shows the snapshot of k3s's SQLite datastore and the k3s
server token. Restoring a cluster from them is under
[Disaster recovery](/operations/disaster-recovery#cluster-datastore).

## 6. A restore

In Borg UI, restore a file of the new archive, `node/etc/os-release` say, to a
custom location such as `/tmp/restore`. The restore runs on the agent, in the
node pod, where the node's root is mounted read-only
(`node.hostRootReadOnly`), so the file lands in the pod:

```sh
kubectl -n k8s-borg exec daemonset/k8s-borg-node -- cat /tmp/restore/node/etc/os-release
```

The same with Borg alone:

```sh
kubectl -n k8s-borg exec daemonset/k8s-borg-node -- \
  sh -c 'cd /tmp && borg extract "::$(borg list --short --last 1)" node/etc/os-release && cat node/etc/os-release'
```

## 7. A database (optional)

A PostgreSQL in namespace `demo`, and a cluster backup that dumps it:

```sh
kubectl apply -f $url/demo-db.yaml
kubectl -n demo rollout status statefulset/demo-db
helm upgrade k8s-borg oci://ghcr.io/ioanalytica/charts/k8s-borg -n k8s-borg \
  --reuse-values -f $url/values-demo-db.yaml
kubectl -n k8s-borg rollout status statefulset/k8s-borg-app --timeout=10m
```

::: details The values: examples/k3d/values-demo-db.yaml
<<< @/../examples/k3d/values-demo-db.yaml
:::

The console pod starts again, reads the database's credentials from its
Secret in `demo`, and registers the plan `backup-k8s-borg-mycluster`, with the
dump as its pre-backup hook. Run it in Borg UI; the archive holds the dumps:

```sh
kubectl -n k8s-borg exec statefulset/k8s-borg-app -- \
  sh -c 'borg list "::$(borg list --short --last 1)"'
```

Restoring them is under [Restore](/operations/restore#databases), the other
engines under [Database dumps](/features/databases).

## Clean up

```sh
k3d cluster delete k8s-borg
cd .. && rm -r k8s-borg-try
```

This deletes the node container with everything in it, the repositories,
Borg UI's database and the pulled images included, and the `kubectl` context.

## When it hangs

| What you see | Why, and what to do |
| --- | --- |
| Pods and claims `Pending`, the claim events say `NodePath only supports ReadWriteOnce` | the chart made its own claims: `claims.yaml` or `values.yaml` is missing from the install |
| `k8s-borg-repo-server-0` stays in `Init` with the event `path "/srv/borg" does not exist`, or its init container `prepare` fails with `data directory /repos belongs to uid 0`; the node pod's log ends with `Repository cannot be accessed!` | `/srv/borg` is missing on the node, or not the server's. Run the `docker exec` of step 1, then start the server and the backup pods again ([below](#start-again)): the node pod would try again only after an hour (`node.backupIntervalSeconds`) |
| The node and console pods stay in `Init`, the reconcile Job's log says `cannot log in as 'admin'` | a second install with new passwords: Borg UI keeps the admin password of its first start on the claim `borg-ui`, and the repositories keep their passphrase. Start over: [clean up](#clean-up) and begin at step 1 |
| A second k3d node: its node pod stays `Pending`, `didn't match PersistentVolume's node affinity` | the claims belong to the first node: one node only |

The reconcile Job's log is `kubectl -n k8s-borg logs job/k8s-borg-reconcile-1`
(the number is the release's revision). More under
[Troubleshooting](/operations/troubleshooting).

### Starting the server and the pods again {#start-again}

Once `/srv/borg` is right, start the repository server, wait for it, and then
start the node and console pods:

```sh
kubectl -n k8s-borg delete pod k8s-borg-repo-server-0
kubectl -n k8s-borg rollout status statefulset/k8s-borg-repo-server --timeout=5m
kubectl -n k8s-borg rollout restart daemonset/k8s-borg-node statefulset/k8s-borg-app
```

## From here to a real cluster

- **Storage.** All node pods share one claim for the Borg cache and one for
  the agents' state, each pod in a directory of its own: on more than one
  node these need `ReadWriteMany` storage, which the chart's own claims ask
  for (`persistence`, see [Parameters](/reference/parameters)).
- **The Borg host.** An SSH host with Borg ([Install](/guide/install)), or the
  [repository server](/features/repository-server) of another cluster: a
  server inside the cluster it backs up needs that cluster for a restore.
- **Secrets.** `existingSecret` instead of values on the command line
  ([Install](/guide/install), and the Secrets in
  [`examples/secrets/`](https://github.com/ioanalytica/k8s-borg/tree/main/examples/secrets)).
- **Borg UI.** An Ingress, OIDC, PostgreSQL, notifications and a license:
  [Borg UI server](/features/borg-ui-server); schedules and hooks:
  [Borg UI agents](/features/borg-ui-agents).
- **The modes.** Standalone or managed agents, CronJob or plan:
  [Configuration](/guide/configuration), with an example release.
