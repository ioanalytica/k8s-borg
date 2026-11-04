<!-- Copyright IO ANALYTICA. SPDX-License-Identifier: AGPL-3.0-only -->

# k8s-borg

Backup for Kubernetes clusters with [BorgBackup](https://www.borgbackup.org/).
Deploys a node-backup **DaemonSet**, a cluster-data **CronJob**, and a console
**StatefulSet** — each talking to its own Borg repository — plus an optional
[Borg UI](https://github.com/karanhudia/borg-ui) server with managed-agent
enrollment, and an optional Borg 1/Borg 2 repository server.

**Documentation: https://k8s-borg.ioanalytica.com**

## Install

The chart is published as an OCI artifact on GitHub Container Registry. A
first install needs an SSH host with Borg and a directory there for the
repositories, a passphrase, an SSH key the host accepts and the host's
`known_hosts` line; the chart backs up no paths by default, here each node's
`/etc`. Without `--version`, Helm installs the latest release:

```sh
helm install my-borg oci://ghcr.io/ioanalytica/charts/k8s-borg \
  -n k8s-borg --create-namespace \
  --set borg.repoBase.value="ssh://user@borg.example.com:22/./mycluster" \
  --set borg.passphrase.value="…" \
  --set-file ssh.privateKey=./id_ed25519 \
  --set-file ssh.knownHosts=./known_hosts \
  --set 'node.include={P fm,R /node/etc}'
```

The chart and its images are signed with Sigstore cosign;
[Verify releases](https://k8s-borg.ioanalytica.com/security/verify) has the
commands. [Install](https://k8s-borg.ioanalytica.com/guide/install) and
[Try it locally](https://k8s-borg.ioanalytica.com/guide/try-locally) on the
documentation site go further.

From a checkout of the repository:

<!-- #region install -->
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
with SOPS, Sealed Secrets, or External Secrets) — see [`examples/`](https://github.com/ioanalytica/k8s-borg/tree/main/examples).
<!-- #endregion install -->

## Documentation

The guides are on the documentation site:

- [Configuration](https://k8s-borg.ioanalytica.com/guide/configuration): standalone or Borg UI managed
  agents, the modes of each component, an example release.
- Features: [node backups](https://k8s-borg.ioanalytica.com/features/node-backups),
  [cluster datastore snapshot](https://k8s-borg.ioanalytica.com/features/datastore),
  [SQLite databases](https://k8s-borg.ioanalytica.com/features/sqlite),
  [database dumps](https://k8s-borg.ioanalytica.com/features/databases), [MongoDB](https://k8s-borg.ioanalytica.com/features/mongodb),
  [Redis and Valkey](https://k8s-borg.ioanalytica.com/features/redis-valkey), [S3 buckets](https://k8s-borg.ioanalytica.com/features/s3),
  [repository server](https://k8s-borg.ioanalytica.com/features/repository-server),
  [external copy](https://k8s-borg.ioanalytica.com/features/external-copy),
  [Borg 1 and Borg 2](https://k8s-borg.ioanalytica.com/features/borg-versions),
  [Borg UI agents](https://k8s-borg.ioanalytica.com/features/borg-ui-agents) and
  [Borg UI server](https://k8s-borg.ioanalytica.com/features/borg-ui-server).
- Operations: [restore](https://k8s-borg.ioanalytica.com/operations/restore),
  [disaster recovery](https://k8s-borg.ioanalytica.com/operations/disaster-recovery),
  [upgrading](https://k8s-borg.ioanalytica.com/operations/upgrading) and
  [troubleshooting](https://k8s-borg.ioanalytica.com/operations/troubleshooting).
- [Versioning](https://k8s-borg.ioanalytica.com/reference/versioning) of the chart and its images.

## Parameters

<!-- #region parameters -->
Parameters are grouped and documented inline in [`values.yaml`](https://github.com/ioanalytica/k8s-borg/blob/main/chart/values.yaml)
(`## @param`). Key sections:

| Section | Highlights |
| --- | --- |
| `image`, `initImage` | agent image (defaults to appVersion) |
| `borg` | `version`, `repoBase`, `passphrase`, `remotePath`, retention, archive naming — see [Borg 1 and Borg 2](https://k8s-borg.ioanalytica.com/features/borg-versions); `checkSchedule`/`backupSchedule` for managed agents, keyed by pod hostname — see [Check and backup schedules](https://k8s-borg.ioanalytica.com/features/borg-ui-agents#check-and-backup-schedules) |
| `s3` | S3 sources mounted via s3fs: `endpoint`, `region`, `mountPath`, credentials, `verifyListing`, `onMountFailure` — see [S3 buckets](https://k8s-borg.ioanalytica.com/features/s3) |
| `ssh`, `databases` | SSH key + MariaDB/MySQL/PostgreSQL/MongoDB logical-dump and Redis/Valkey RDB configs (→ Secrets) |
| `node` / `cluster` | the two backup scopes. `node` is the DaemonSet; `cluster` is the CronJob **and** the console/agent StatefulSet (they share `cluster.nodeName`/`resources`/`extraVolumes`/`nodeSelector`/`affinity`/`tolerations`, pinned to the storage node). `cluster.mode` (legacy/agent) and `cluster.backupMode` (cronjob/plan) select enrollment and scheduling. Borg include/exclude patterns (+ `cluster.s3Buckets`) live under each scope: `node.include`/`node.exclude`, `cluster.include`/`cluster.exclude`. `node.datastoreSnapshot` adds the cluster datastore — see [Cluster datastore snapshot](https://k8s-borg.ioanalytica.com/features/datastore) |
| `borgUI` | optional server (Deployment/Service/Ingress), `agentConnection`, `reconcile` Job, `oidc`, `remoteMachines`, `notifications` (see [Notification channels](https://k8s-borg.ioanalytica.com/features/borg-ui-server#notification-channels)), `redis` (archive-listing cache: `mode: internal` deploys a dedicated Redis pod that survives UI-pod rolls, or `external` points at an existing instance) |
| `persistence` | NFS source, cache, UI state PVCs (+ optional static NFS PVs; Borg UI's only with `borgUI.enabled`); `accessModes` per claim, `ReadWriteMany` by default — `[ReadWriteOnce]` for storage without it, such as the local-path class of k3s and kind, with every pod of the claim on one node |
| `repoServer` | optional repository server: `sshd` + `borg serve`, clients from `authorized_keys` in the ssh Secret, `service`, `persistence` — see [Repository server](https://k8s-borg.ioanalytica.com/features/repository-server) |

> **Upgrade note (1.0.21):** two breaking value renames — the chart fails fast if
> the old sections are still set.
> - `app` merged into `cluster`: `app.mode`→`cluster.mode`,
>   `app.agentScripts`→`cluster.agentScripts`, drop `app.enabled`/`app.nodeName`/… —
>   the console pod now shares the `cluster.*` pod settings with the CronJob.
> - `config` split into `node`/`cluster`: `config.clusterInclude`→`cluster.include`,
>   `config.clusterExclude`→`cluster.exclude`, `config.s3Buckets`→`cluster.s3Buckets`,
>   `config.nodeInclude`→`node.include`, `config.nodeExclude`→`node.exclude`.
<!-- #endregion parameters -->

## Security posture

<!-- #region security-posture -->
The backup pods run **privileged** with `SYS_ADMIN` (node backups also mount the
host `/` read-only). This is required to read arbitrary source paths and mount
FUSE. Keep the Borg UI Ingress restricted to trusted networks — it can reach
every repository.

The Borg UI server is privileged by default too, for FUSE: server-side
backups of SSH sources, cloud mirrors of SSH repositories and "Mount archive"
mount through it. containerd lets a container open `/dev/fuse` only when it
is privileged or a device plugin assigned the device; mounting `/dev/fuse` as
a hostPath is not enough. Two values take the privilege away:

| Values | UI container |
|---|---|
| default (`borgUI.fuse.enabled: true`) | `privileged: true` |
| `borgUI.fuse.deviceResource: squat.ai/fuse` (the resource your FUSE device plugin advertises, e.g. [generic-device-plugin](https://github.com/squat/generic-device-plugin)) | not privileged; one FUSE device, `SYS_ADMIN`, privilege escalation for `fusermount3`, AppArmor unconfined |
| `borgUI.fuse.enabled: false` | not privileged, no privilege escalation, no FUSE; the three features above fail, and so does `sudo` in the container (package install commands such as `sudo apt-get`) |

Unprivileged, the container keeps `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`
and `SETUID`: its entrypoint prepares `/data` as root and then drops to the
`borg` user. A `borgUI.containerSecurityContext` you set replaces all of this.

With `node.datastoreSnapshot` the node archives hold every Secret of the
cluster, and with kubeadm its certificate authority's keys: whoever can read
the repository and has its passphrase holds the cluster, and in an
`authenticated*` or `none` repository whoever can read it.

With `node.sqlite` the node pods get a ServiceAccount of their own that may
read the listed claims and all PersistentVolumes, nothing else; the files they
copy are ones they could read through the host root already.

The repository server is the exception: unprivileged, no capabilities, read-only
root filesystem. It shares the ssh Secret with the backup pods, so those pods
can read its host key; keep `ssh_host_ed25519_key` out of the Secret of a
release that does not run the server. All clients are served by one user:
what keeps them apart is the directory their key is bound to, not file
ownership.
<!-- #endregion security-posture -->
