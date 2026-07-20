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
