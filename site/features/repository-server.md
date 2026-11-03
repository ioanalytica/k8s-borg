# Repository server

`repoServer.enabled=true` adds a Borg repository server to the release: `sshd`
as the unprivileged user `borg`, in a pod of its own, with every client key
bound to `borg serve` for one directory. It runs from the agent image, so server
and clients of one chart version carry the same Borg 2 and borgstore. One
replica, data on one node.

> **Borg 2 repositories are test beds.** Borg 2 is a beta, and its repository
> format has changed more than once without a conversion path. A repository
> server from this chart does not change that: do not rely on a Borg 2
> repository as your backup.

> **A cluster that backs up to a server inside itself needs that cluster to
> restore.** The data directory therefore is a plain directory on the node:
> without the pod — and without the cluster — it is read on the node with a Borg
> of the same version, as the directory's owner. For clients in other clusters
> the server is external and the point does not arise.

## One Secret

Server and clients share the ssh Secret (`ssh.*`, or `ssh.existingSecret`). For
the server it carries two more entries:

| Key | Content |
| --- | --- |
| `ssh_host_ed25519_key` | the server's host key, private part (`ssh.hostKey`) |
| `authorized_keys` | the clients' public keys, one per line (`ssh.authorizedKeys`) |

```sh
ssh-keygen -t ed25519 -N "" -C "" -f ssh_host_ed25519_key
```

The host key is handed in and never generated. It is the same after every
restart, and its public part is known before the first install — it is what goes
into the clients' `known_hosts`, as `[<host>]:<port> ssh-ed25519 AAAA…`.

`authorized_keys` is the usual file, without options:

```
ssh-ed25519 AAAA… cluster-a
ssh-ed25519 AAAA… cluster-b
ssh-ed25519 AAAA… restore-test
```

The comment names the client. An init container rewrites every line into one
that binds the key to `borg serve` for a single directory, without shell, PTY or
forwarding, and stages it together with the host key with the modes `sshd`
insists on. The server container mounts what was staged read-only; it sees
neither the Secret nor anything it could change. A line that carries options, a
comment that is no plain name, or a damaged key stops the start.

**Adding a client is adding a line.** It gets the directory named after it and
`repoServer.defaultPermissions`. The pod reads the Secret at start: restart it
after a change (`kubectl rollout restart statefulset/<release>-repo-server`).
With a Secret the chart renders itself, the restart happens on upgrade.

## Directories and permissions

Every client is confined to one directory below the data directory. With the
permissions `all` it creates repositories anywhere below it, on demand. Borg
checks the requested path against that directory by resolved path; nothing
outside can be reached.

`repoServer.clients` is only needed for a client that differs from the default:

```yaml
repoServer:
  enabled: true
  defaultPermissions: all
  clients:
    - name: cluster-b
      permissions: no-delete
    - name: restore-test        # a second key for cluster-b's repositories
      path: cluster-b
      permissions: read-only
```

| Permissions | Borg 2 | Borg 1 |
| --- | --- | --- |
| `all` | everything | everything |
| `no-delete` | read and write; no delete, no overwrite | `--append-only`: a delete or prune is recorded, not carried out |
| `write-only` | write; no read | no access |
| `read-only` | read; no write | no access |

They are enforced by the server (`borg serve --permissions`), not by the client.
Borg 1 has no permissions, only append-only, which is why a key that may only
read or only write gets no Borg 1 access at all. Append-only is the weaker
promise: the client's delete seems to succeed, and the data stays until someone
with full access compacts the repository. `repoServer.borg1=false` turns Borg 1
off altogether.

**The backup workloads of this chart need `all`.** They create their repository
and prune and compact after every backup, and only `all` allows the three. The
other permissions are for keys that do one thing: a second key that reads a
repository for a restore test, or a client that only runs `borg create` into a
repository someone else created and maintains.

## Repository URLs

| Client | URL |
| --- | --- |
| Borg 2.0.0b25 and later | `ssh://borg@<host>:<port>/<client>/<repository>` |
| Borg 2 up to 2.0.0b24 | `rest://borg@<host>:<port>/<client>/<repository>` |
| Borg 1 | `ssh://borg@<host>:<port>/./<client>/<repository>` |

The path is relative to the data directory. Nothing is wired up for the
workloads of the release itself: set `borg.repoBase` and the `known_hosts` entry
as for any other server.

Two things a client has to know:

- **Borg 2 ignores the port of the URL once `BORG_RSH` or `BORGSTORE_RSH` is
  set.** It takes the remote shell command as it is. A client with its own
  command has to name the port there: `BORG_RSH="ssh -p 2222 …"`.
- **Borg 1 creates a repository only in a directory that exists.** The client's
  own directory does; anything deeper has to be created on the server first.
  Borg 2 creates the directories in between.

Clients in other clusters run the Borg of their own release. When a Borg 2 beta
changes the protocol, upgrade the release that runs the server first.

## Reaching the server

One Service for every client (`repoServer.service`):

| `type` | Reachable from |
| --- | --- |
| `ClusterIP` (default) | pods of the cluster, as `<release>-repo-server.<namespace>.svc` |
| `NodePort` | also from outside, on every node's address (`nodePort` fixes the port) |
| `LoadBalancer` | also from outside, on the load balancer address (`loadBalancerIP`, `loadBalancerClass`, `loadBalancerSourceRanges`, `annotations` — e.g. `metallb.io/loadBalancerIPs`) |

Pods of the cluster use the Service name with every type.
`externalTrafficPolicy: Local` keeps the client address in the `sshd` log; then
only the node running the pod answers.

## Storage and the user

| `repoServer.persistence` | |
| --- | --- |
| `existingClaim` | a claim you manage |
| `local.createPV` + `local.nodeName` + `local.path` | a static `local` PersistentVolume for a directory on one node, and its claim. The volume's node affinity pins the pod to that node |
| neither | a claim from `storageClassName` (or the default class) |

The pod mounts no `hostPath`, runs without root and without capabilities, on a
read-only root filesystem — nothing a restricted namespace forbids.

The server runs as `repoServer.runAsUser`/`runAsGroup` (default `20222`,
deliberately not a uid other charts commonly use: a second workload with the
same number on the node could read the repositories). **The data directory has
to exist and belong to that user**; the chart does not change ownership. The
server sets it to mode `0700` and creates everything below it readable for this
user only.

```sh
# on the node, once
install -d -o 20222 -g 20222 -m 0700 /srv/borg
```

Volume and claim created by the chart are kept on `helm uninstall`.
