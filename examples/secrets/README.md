# Secrets

The manifests here are **placeholders** — they show which keys each Secret that
[`../helm/k8s-borg.yaml`](../helm/k8s-borg.yaml) references needs.

> ⚠️ **Never commit your real secrets.**
> Store them in a vault, or encrypt them with [SOPS](https://github.com/getsops/sops)
> or [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) and commit
> only the **encrypted** versions.

Replace every `<CHANGE_ME>` / `<...>` value before deploying, and keep the
filled-in files out of version control (e.g. add them to `.gitignore`).
