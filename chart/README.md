<!-- Copyright IO ANALYTICA. All Rights Reserved. SPDX-License-Identifier: Apache-2.0 -->

# k8s-borg

Backup for Kubernetes clusters with [BorgBackup](https://www.borgbackup.org/).
Deploys a node-backup **DaemonSet**, a cluster-data **CronJob**, and a console
**StatefulSet** — each talking to its own Borg repository — plus an optional
[Borg UI](https://github.com/karanhudia/borg-ui) server and managed-agent
enrollment (DEV/TEST).

## Install

```sh
# pull the common library dependency (or use the vendored charts/ tarball)
helm dependency build ./chart

helm install my-borg ./chart -n k8s-borg --create-namespace \
  --set borg.repoBase.value="ssh://user@borg.example.com:22/./mycluster" \
  --set borg.passphrase.value="…" \
  --set-file ssh.privateKey=./id_ed25519 \
  --set-file ssh.knownHosts=./known_hosts
```

For anything beyond a smoke test, put the sensitive values in a pre-created
Secret and reference it with `existingSecret` / `ssh.existingSecret` (managed
with SOPS, Sealed Secrets, or External Secrets) — see [`../examples`](../examples).

## Modes

Backup execution is chosen **per component**, along two independent axes:
*who runs the backup* and *whether the pod is enrolled in Borg UI*.

- **Node (DaemonSet)** — `node.backupMode`:
  - `interval` (default): the stable in-pod loop runs `/run.sh` every
    `node.backupIntervalSeconds` against `borg.repoBase`.
  - `agent`: each node pod enrolls at Borg UI and registers a per-node backup plan.
- **Cluster (CronJob + console/agent pod)** — the `cluster` section covers the
  cluster-scope data **and** the long-lived console pod (deployed when
  `cluster.enabled`). Two independent axes:
  - `cluster.backupMode` — *how the backup is scheduled*: `cronjob` (default, a k8s
    CronJob on `cluster.schedule`) or `plan` (a server-side BackupPlan run by the
    console/agent pod; needs `cluster.mode=agent`; no CronJob).
  - `cluster.mode` — *whether the console pod is enrolled in Borg UI*: `legacy`
    (default, inspection only — tails the log, `kubectl exec` in) or `agent` (enroll
    at Borg UI: register the cluster repository + check-schedule so it is browsable,
    and run the agent). In `cronjob` mode the agent just makes the repo visible.
  - `cluster.borgUiResync` (default `true`) — in `cronjob` mode with a Borg UI to
    talk to (`borgUI.enabled` or `borgUI.agentConnection.server`), each run ends by
    asking Borg UI to resync the cluster repository, so new and pruned archives and
    the size show up right away instead of on the next periodic reconcile run. Best
    effort: a failure is logged as a warning and never changes the job's exit code.

Managed-agent modes need a reachable server: set `borgUI.agentConnection.server`,
or deploy one in-cluster with `borgUI.enabled=true` (which also runs a reconcile
Job that mints an admin PAT and reconciles `borgUI.oidc`).

### Agent pre/post-backup scripts

You can publish pre/post-backup scripts to a managed agent as a map of
filename → script body. They are mounted read-only and executable at
`/etc/borg-ui-agent-scripts` and become selectable as pre/post-backup hooks in a
Borg UI backup plan. The agent only ever runs scripts from this allow-list — the
server sends a script *name*, never a path. Scripts run on the agent with
`stdout`/`stderr` kept separate; exit code `0` = success, `1` = warning (the
backup still runs), `>1` = failure.

Scope matters — publish scripts to the agent that actually has the data and
secrets they need:

- **`cluster.agentScripts`** (needs `cluster.mode=agent`) → the **cluster** agent, in
  the console pod. Use this for cluster-backup scripts (DB dumps etc.) — that pod is
  where the cluster source/DB secrets live.
- **`node.agentScripts`** (needs `node.backupMode=agent`) → each **node** agent.
  Use this for node-local scripts. Node pods do not have the cluster secrets.

```yaml
cluster:
  mode: agent
  agentScripts:
    backup-cluster-postgres: |
      #!/bin/sh
      # borg-ui: Dump the cluster Postgres before backup
      pg_dumpall > /mnt/cluster/db.sql
```

## Repository server (optional)

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

### One Secret

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

### Directories and permissions

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

### Repository URLs

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

### Reaching the server

One Service for every client (`repoServer.service`):

| `type` | Reachable from |
| --- | --- |
| `ClusterIP` (default) | pods of the cluster, as `<release>-repo-server.<namespace>.svc` |
| `NodePort` | also from outside, on every node's address (`nodePort` fixes the port) |
| `LoadBalancer` | also from outside, on the load balancer address (`loadBalancerIP`, `loadBalancerClass`, `loadBalancerSourceRanges`, `annotations` — e.g. `metallb.io/loadBalancerIPs`) |

Pods of the cluster use the Service name with every type.
`externalTrafficPolicy: Local` keeps the client address in the `sshd` log; then
only the node running the pod answers.

### Storage and the user

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

## Borg 1 vs 2

`borg.version` (`1` or `2`) selects the borg **binary** used by the scripts. The
**transport** is the URL scheme in `borg.repoBase` and is independent of the
version: `ssh://` (server has borg installed, works with 1 and 2) or `sftp://`
(plain SFTP target with no server-side borg — borg 2 only).

The two majors read the same `ssh://` URL differently:

| | relative to the login directory | absolute |
| --- | --- | --- |
| Borg 1 | `ssh://user@host:22/./cluster` | `ssh://user@host:22/srv/cluster` |
| Borg 2 | `ssh://user@host:22/cluster` | `ssh://user@host:22//srv/cluster` |

| | Borg 1 | Borg 2 |
| --- | --- | --- |
| `borg.remotePath` (`BORG_REMOTE_PATH`) | the `borg` wrapper adds `--remote-path=<value>` to every call | read by Borg itself; the option no longer exists (removed in 2.0.0b22) |
| `BORG_ENCRYPTION` (read by `borg-init`; the chart does not set it, its workloads get the default) | any Borg 1 mode, default `repokey-blake2` | `repokey-aes-ocb` (default), `repokey-chacha20-poly1305`, `keyfile-aes-ocb`, `keyfile-chacha20-poly1305`, `authenticated` (= `authenticated-sha256`), `authenticated-blake3`. No `none` |
| `borg.passphrase` | needed for the modes with a key | mandatory: from 2.0.0b25 on there is no repository without a key, and every command needs it, `break-lock` and `repo-delete` included |
| port | taken from the URL | taken from the URL, unless a remote shell command is set (`BORG_RSH`, `BORGSTORE_RSH`): that command is used as it is and has to name the port, `ssh -p 2222`. The chart sets neither |
| `rest://` | never a repository URL | the name of `ssh://` up to 2.0.0b24; refused from 2.0.0b25 on |

### Upgrading to Borg 2.0.0b25

This concerns releases with `borg.version: 2`. **Borg 1 repositories are not
affected.** Which Borg 2 an image carries: `borg2 --version` in a pod.

> **Borg 2 repositories are test beds, not backups to rely on.** Borg 2 is a
> beta. 2.0.0b25 cannot open a repository written by 2.0.0b22–b24 (exit 15,
> "is not a valid repository"), and there is no conversion in place: every
> Borg 2 repository is created anew, and the history in the old one ends.

What changes for the clients:

- **`rest://` becomes `ssh://`.** The path rules are the same. 2.0.0b25 does not
  reject the old scheme, it reads the URL as a local directory and would back up
  into the pod's own filesystem. The chart therefore refuses a
  `borg.repoBase.value` that starts with `rest://`, and the `borg2` wrapper
  refuses such a repository before Borg runs when the Borg 2 of the image is
  2.0.0b25 or later. A base from an existing Secret is only seen by the wrapper.
  The wrapper goes by the Borg 2 of the image, the chart cannot: a release that
  pins an image with an earlier Borg 2 takes its `rest://` base from an existing
  Secret.
- **`BORG_ENCRYPTION=none` is refused**, `authenticated` creates an
  `authenticated-sha256` repository.
- **The passphrase is needed for every command.**

Before the upgrade, with the release that is still running:

1. **Restore what you still need** from the Borg 2 repositories. Where the
   history itself matters, the only bridge is one archive at a time, with both
   Borg versions side by side: `borg export-tar --tar-format BORG` from the old
   repository into `borg import-tar` of the new one. The archives get new ids.

Then, in this order:

2. **Repository server first.** It has to run the borgstore that belongs to
   2.0.0b25 (0.7.0, with the `blake3` extra); clients up to 2.0.0b24 keep
   working against it. For the [repository server](#repository-server-optional)
   of this chart that is the upgrade of the release that runs it.
3. Stop the backups of the Borg 2 repositories (suspend the CronJob, pause the
   plans and schedules in Borg UI) and wait for running jobs.
4. On the server, **move the old repository directories aside. Do not delete
   them.**
5. **Upgrade the release.** With the base in `borg.repoBase.value`, change it to
   `ssh://` in the same step; the chart does not render otherwise.
6. **Then the base URL**, where it comes from an existing Secret: change it to
   `ssh://` and restart the pods. Until then they refuse to run Borg 2 and say
   why; nothing is written anywhere.
7. Borg UI keeps the URL of every repository it knows, and the pods leave a
   record they find alone. Change the records of the Borg 2 repositories there,
   or remove them from Borg UI without deleting data, so that the pods register
   them anew.
8. The pods create the repositories (`borg-init`). Check one: `borg-info` prints
   `Repository version: 5`. Run a backup and a restore into an empty directory,
   then resume the backups.
9. Delete the directories of step 4 once the new repositories hold backups you
   have verified.

**Rollback** is the previous release with the previous base URL and the
directories of step 4 moved back. It works only as long as those directories
exist. What 2.0.0b25 has written in between cannot be read by an earlier beta.

## Versioning

`appVersion` is the agent image version, and `image.tag` defaults to it — the
agent image tag is never written down a second time. `version` is `appVersion`
for a new agent release, and gains a `-N` suffix for chart-only changes on top
of it (`1.0.23-1`, `1.0.23-2`, …).

The UI image is a different lifecycle: `borgUI.image.tag` follows the pinned
`borg-ui` submodule, whose `VERSION` file is the single source of truth for it.
The `annotations.images` block in `Chart.yaml` restates all of this for chart
scanners, so it has to be updated along with any bump.

`tests/chart-versions.bats` enforces the whole set — a mismatch fails CI rather
than shipping a chart that points at an image tag nobody built.

## Parameters

Parameters are grouped and documented inline in [`values.yaml`](values.yaml)
(`## @param`). Key sections:

| Section | Highlights |
| --- | --- |
| `image`, `initImage` | agent image (defaults to appVersion) |
| `borg` | `version`, `repoBase`, `passphrase`, `remotePath`, retention, archive naming — see [Borg 1 vs 2](#borg-1-vs-2) |
| `s3` | S3 sources mounted via s3fs |
| `ssh`, `databases` | SSH key + MariaDB/PostgreSQL logical-dump configs (→ Secrets) |
| `node` / `cluster` | the two backup scopes. `node` is the DaemonSet; `cluster` is the CronJob **and** the console/agent StatefulSet (they share `cluster.nodeName`/`resources`/`extraVolumes`/`nodeSelector`/`affinity`/`tolerations`, pinned to the storage node). `cluster.mode` (legacy/agent) and `cluster.backupMode` (cronjob/plan) select enrollment and scheduling. Borg include/exclude patterns (+ `cluster.s3Buckets`) live under each scope: `node.include`/`node.exclude`, `cluster.include`/`cluster.exclude` |

> **Upgrade note (1.0.21):** two breaking value renames — the chart fails fast if
> the old sections are still set.
> - `app` merged into `cluster`: `app.mode`→`cluster.mode`,
>   `app.agentScripts`→`cluster.agentScripts`, drop `app.enabled`/`app.nodeName`/… —
>   the console pod now shares the `cluster.*` pod settings with the CronJob.
> - `config` split into `node`/`cluster`: `config.clusterInclude`→`cluster.include`,
>   `config.clusterExclude`→`cluster.exclude`, `config.s3Buckets`→`cluster.s3Buckets`,
>   `config.nodeInclude`→`node.include`, `config.nodeExclude`→`node.exclude`.
| `borgUI` | optional server (Deployment/Service/Ingress), `agentConnection`, `reconcile` Job, `oidc`, `remoteMachines`, `redis` (archive-listing cache: `mode: internal` deploys a dedicated Redis pod that survives UI-pod rolls, or `external` points at an existing instance) |
| `persistence` | NFS source, cache, UI state PVCs (+ optional static NFS PVs) |
| `repoServer` | optional repository server: `sshd` + `borg serve`, clients from `authorized_keys` in the ssh Secret, `service`, `persistence` — see [Repository server](#repository-server-optional) |

### Licensing (`borgUI.licensing`)

Borg UI evaluates its plan from a signed entitlement in its own database. By
default the server contacts `https://license.borgui.com` on startup and refreshes
every 24h; the plan itself is then checked locally.

Air-gapped installs turn the phone-home off:

```yaml
borgUI:
  licensing:
    startupSync: false
    activationServiceUrl: ""
```

The license can travel with the release instead of being clicked into the UI —
the reconcile Job applies it on every install/upgrade:

```yaml
# online: activate a key (only while the instance carries no paid license)
borgUI.licensing.licenseKey.value: "…"        # or .existingSecret/.existingSecretKey

# air-gapped: import an already-signed entitlement document, no egress
borgUI.licensing.entitlement.existingSecret: "borgui-entitlement"
```

```bash
kubectl create secret generic borgui-entitlement -n borg \
  --from-file=entitlement.json=/path/to/entitlement.json
```

`scripts/dump-entitlement.py` exports the entitlement an already-licensed instance
holds, in exactly that file format — useful both as a license backup and to seed
the Secret above.

The offline document is issued for the `instance_id` the server generates on its
first boot, so it is a two-step process: install, read the `instance_id` (Settings
> Licensing, or the reconcile Job log, which prints it), get the document, then
set the Secret and upgrade.

That `instance_id` lives only in the database, so wiping the database gives the
instance a new identity and the stored document stops applying to it. Setting
**both** values covers that: the document is used while it matches, and once it
doesn't, the key — which is instance-independent — takes over and has a fresh
entitlement issued. Re-export the document afterwards; the old one is stale. A
stale document with no key configured fails the reconcile rather than quietly
dropping the instance to the community plan.

Nothing is re-applied without cause. An instance already holding a paid license is
never re-activated (no seat is burned on an upgrade), and a document is imported
only when the instance is unlicensed or the document outlives what it currently
holds — a live instance renews its entitlement by itself, and re-asserting an older
copy from the release would roll that back.

The activation service may still count the old instance as holding the license, so
deactivate a paid license (Settings > Licensing) before deleting an instance you
intend to rebuild.

## Security posture

The backup pods run **privileged** with `SYS_ADMIN` (node backups also mount the
host `/` read-only). This is required to read arbitrary source paths and mount
FUSE. Keep the Borg UI Ingress restricted to trusted networks — it can reach
every repository.

The repository server is the exception: unprivileged, no capabilities, read-only
root filesystem. It shares the ssh Secret with the backup pods, so those pods
can read its host key; keep `ssh_host_ed25519_key` out of the Secret of a
release that does not run the server. All clients are served by one user:
what keeps them apart is the directory their key is bound to, not file
ownership.
