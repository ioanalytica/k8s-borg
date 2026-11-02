# Examples

| Path | What it is |
| --- | --- |
| [`helm/k8s-borg.yaml`](helm/k8s-borg.yaml) | A [Flux](https://fluxcd.io/) `HelmRepository` and `HelmRelease` installing the published chart: node backups, a cluster backup of a shared NFS file system, two S3 buckets and two databases, and the optional Borg UI part commented out |
| [`secrets/`](secrets) | **Placeholder** Secrets with the keys the release above references |

The `values:` block of the HelmRelease is an ordinary values file, so the same
settings work with plain Helm. Every key in it is checked against the chart by
`tests/examples-helm.bats`, and it pins the current chart version.

> **These are examples, not a turnkey deployment.** Replace the `<...>` /
> `<CHANGE_ME>` / `*.example.com` placeholders for your cluster; every parameter
> is documented in [`chart/README.md`](../chart/README.md).

## Plain manifests

The chart is the maintained way to deploy k8s-borg. For plain YAML, for
example to apply with Kustomize, render the chart with your values:

```sh
helm template k8s-borg oci://ghcr.io/ioanalytica/charts/k8s-borg --version <version> \
  -n k8s-borg -f my-values.yaml > k8s-borg.yaml
```

## Secrets

Do **not** commit real credentials — keep them in an encrypted-at-rest tool
(SOPS, Sealed Secrets, External Secrets Operator, …) and reference them from
the release with `existingSecret`. See [`secrets/README.md`](secrets/README.md).

## Security posture

Node and cluster backups run **privileged** with `SYS_ADMIN`, and node backups
mount the host's root read-only: they read arbitrary source paths and mount
FUSE (S3, `borg mount`). The optional Borg UI server can reach every repository
— keep its Ingress restricted to trusted networks. Details in "Security
posture" in [`chart/README.md`](../chart/README.md#security-posture).
