# Example manifests

Sanitized, deploy-shaped example manifests for running k8s-borg on a Kubernetes
cluster with [Kustomize](https://kustomize.io/). They mirror a real deployment
but every site-specific value (hosts, domains, repositories, buckets,
credentials) has been replaced with a placeholder.

> **These are examples, not a turnkey deployment.** Review every file and replace
> the `<...>` / `<CHANGE_ME>` / `*.example.com` placeholders for your cluster.

## Layout

| Path | What it deploys |
| --- | --- |
| `borg-namespace.yaml` | the `borg` namespace |
| `k8s-borg-config.yaml` | ConfigMap: include/exclude patterns + S3 bucket list |
| `k8s-borg-daemonset.yaml` | **DaemonSet** — one node backup per node (`BORG_MODE=node`, `hostPath` root, privileged) |
| `k8s-borg-cronjob.yaml` | **CronJob** — periodic cluster-data backup (shared FS, S3, logical DB dumps) |
| `k8s-borg-app-sts.yaml` | **`k8s-borg-app`** — long-running pod for console access to backups/repos |
| `k8s-borg-ui-*.yaml` | optional Borg UI server (Deployment/Service/Ingress) |
| `storage/` | NFS PersistentVolumes/Claims (shared FS + Borg client cache) |
| `secrets/` | **placeholder** Secrets — Borg repo, SSH key, S3 keys, DB credentials |

## Usage

```sh
# edit the placeholders first!
kubectl apply -k examples/
```

Images default to the published `ghcr.io/ioanalytica/k8s-borg:1.0.4` (agent) and
`ghcr.io/ioanalytica/k8s-borg-ui:2.2.5` (server).

## Secrets

`secrets/` holds **placeholder** Secrets so the kustomization is self-contained.
Do **not** commit real credentials — replace the values and manage them with an
encrypted-at-rest tool (SOPS, Sealed Secrets, External Secrets Operator, …).

## Notes on the security posture

The backup pods run **privileged** with `SYS_ADMIN` (and, for node backups, a
read-only `hostPath` mount of `/`). That is intentional: node/cluster backups
must read arbitrary source paths and mount FUSE (S3, `borg mount`). Scope the
namespace and RBAC accordingly.

The optional Borg UI server can reach every repository — keep its Ingress
restricted to trusted networks (see the comment in `k8s-borg-ui-ingress.yaml`).
`BORG_UI_AGENT=true` (managed-agent mode) is **DEV/TEST only** while the Borg UI
integration matures; unset, k8s-borg runs the stable standalone backup flow.
