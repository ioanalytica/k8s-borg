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

- **Standalone (default, production):** unset `borgUI.agent.enabled`. Pods run the
  stable backup flow (`/run.sh`) against `borg.repoBase`.
- **Borg UI managed agent (DEV/TEST):** `borgUI.agent.enabled=true` enrolls the
  pods at a Borg UI server. Optionally deploy the server itself with
  `borgUI.enabled=true`.

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
| `node` / `cluster` / `app` | the three backup workloads (each toggleable) |
| `borgUI` | optional server (Deployment/Service/Ingress) + agent enrollment |
| `persistence` | NFS source, cache, UI state PVCs (+ optional static NFS PVs) |

## Security posture

The backup pods run **privileged** with `SYS_ADMIN` (node backups also mount the
host `/` read-only). This is required to read arbitrary source paths and mount
FUSE. Keep the Borg UI Ingress restricted to trusted networks — it can reach
every repository.
