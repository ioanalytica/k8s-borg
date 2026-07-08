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
  --set borg.repoBase="ssh://user@borg.example.com:22/./mycluster" \
  --set borg.passphrase="…" \
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
- **Cluster backup mechanism** — `cluster.backupMode` (only when `cluster.enabled`,
  mutually exclusive): this picks *how the backup is scheduled*, nothing else.
  - `cronjob` (default): a k8s CronJob runs the backup on `cluster.schedule`.
  - `plan`: a server-side BackupPlan in Borg UI runs it (registered by the app
    pod, so it needs `app.mode=agent`); **no** CronJob is created.
- **Console/app enrollment** — `app.mode`:
  - `legacy` (default): inspection only (tails the log, `kubectl exec` in).
  - `agent`: fully enroll at Borg UI — register the cluster repository +
    check-schedule so it is **browsable in the UI regardless of who backs it up**,
    and run the agent. It registers a BackupPlan only when `cluster.backupMode=plan`;
    with `cronjob` the CronJob backs up and the agent just makes the repo visible.

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

- **`app.agentScripts`** (needs `app.mode=agent`) → the **cluster** agent, in the
  console/app pod. Use this for cluster-backup scripts (DB dumps etc.) — that pod
  is where the cluster source/DB secrets live.
- **`node.agentScripts`** (needs `node.backupMode=agent`) → each **node** agent.
  Use this for node-local scripts. Node pods do not have the cluster secrets.

```yaml
app:
  mode: agent
  agentScripts:
    backup-cluster-postgres: |
      #!/bin/sh
      # borg-ui: Dump the cluster Postgres before backup
      pg_dumpall > /mnt/cluster/db.sql
```

## Borg 1 vs 2

`borg.version` (`1` or `2`) selects the borg **binary** used by the scripts. The
**transport** is the URL scheme in `borg.repoBase` and is independent of the
version: `ssh://` (server has borg installed, works with 1 and 2) or `sftp://`
(plain SFTP target with no server-side borg — borg 2 only).

## Parameters

Parameters are grouped and documented inline in [`values.yaml`](values.yaml)
(`## @param`). Key sections:

| Section | Highlights |
| --- | --- |
| `image`, `initImage` | agent image (defaults to appVersion) |
| `borg` | `version`, `repoBase`, `passphrase`, retention, archive naming |
| `s3` | S3 sources mounted via s3fs |
| `config` | include/exclude patterns + bucket list (→ ConfigMap) |
| `ssh`, `databases` | SSH key + MariaDB/PostgreSQL logical-dump configs (→ Secrets) |
| `node` / `cluster` / `app` | the three backup workloads (each toggleable; `backupMode` per component). `cluster`/`app` also take their own `extraVolumes`/`extraVolumeMounts` (scoped to just those pods, e.g. a node-local PVC for a stable cluster-backup mount) plus `nodeSelector`/`affinity`/`tolerations` to pin them to that storage node |
| `borgUI` | optional server (Deployment/Service/Ingress), `agentConnection`, `reconcile` Job, `oidc`, `remoteMachines`, `redis` (archive-listing cache: `mode: internal` deploys a dedicated Redis pod that survives UI-pod rolls, or `external` points at an existing instance) |
| `persistence` | NFS source, cache, UI state PVCs (+ optional static NFS PVs) |

## Security posture

The backup pods run **privileged** with `SYS_ADMIN` (node backups also mount the
host `/` read-only). This is required to read arbitrary source paths and mount
FUSE. Keep the Borg UI Ingress restricted to trusted networks — it can reach
every repository.
