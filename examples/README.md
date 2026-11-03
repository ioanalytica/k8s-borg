# Examples

| Path | What it is |
| --- | --- |
| [`helm/k8s-borg.yaml`](helm/k8s-borg.yaml) | A [Flux](https://fluxcd.io/) `HelmRepository` and `HelmRelease` modelled on a production release, with every site-specific value replaced: node and cluster backups to a Hetzner Storage Box, S3 buckets, MariaDB and PostgreSQL dumps with the operators' credentials, a Borg UI server with OIDC login and mail notifications running the node backups as managed agents, and a repository server for other clusters |
| [`secrets/`](secrets) | **Placeholder** Secrets with the keys the release above references |

The `values:` block of the HelmRelease is an ordinary values file, so the same
settings work with plain Helm. Every key in it is checked against the chart by
`tests/examples-helm.bats`, which also renders it without Borg UI, and it pins
the current chart version. For a first try, the install command in the
[README](../README.md#quick-start) needs none of this.

> **These are examples, not a turnkey deployment.** Replace the `<...>` /
> `<CHANGE_ME>` / `*.example.com` placeholders for your cluster; every parameter
> is documented in [`chart/values.yaml`](../chart/values.yaml) and on the
> [documentation site](https://k8s-borg.ioanalytica.com).

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
