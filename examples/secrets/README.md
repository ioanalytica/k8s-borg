# Secrets

The manifests here are **placeholders** for the two Secrets you create yourself
for [`../helm/k8s-borg.yaml`](../helm/k8s-borg.yaml), with the keys it reads
from them. The database credentials need no Secret of yours: the chart reads
them from the Secrets the database operators create in each database's
namespace (`databases.*.instances[].secretRef`), and Borg UI's PostgreSQL
credentials likewise. The Ingress certificate (`borgui-tls`) comes from your
certificate issuer.

> ⚠️ **Never commit your real secrets.**
> Store them in a vault, or encrypt them with [SOPS](https://github.com/getsops/sops)
> or [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) and commit
> only the **encrypted** versions.

Replace every `<CHANGE_ME>` / `<...>` value before deploying, and keep the
filled-in files out of version control (e.g. add them to `.gitignore`).
