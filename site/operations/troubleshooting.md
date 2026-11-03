# Troubleshooting

## When the reconcile Job fails

The reconcile Job (`<fullname>-reconcile-<revision>`, e.g.
`k8s-borg-reconcile-12` for revision 12 of a release named `k8s-borg`) runs once
per install/upgrade; the agent pods wait for it in their `wait-for-reconcile` init
container. When it fails, the `FATAL` line names the request that failed and
why (curl's message, or the HTTP status with what the server said). It can be
read in four places:

- the Job log, `kubectl logs job/<fullname>-reconcile-<revision>` —
  the Job and its pod are kept for `borgUI.reconcile.ttlSecondsAfterFinished`
  (a day by default);
- the pod status, `.status.containerStatuses[0].state.terminated.message`;
- the ConfigMap `<fullname>-reconcile-status`, `data.lastError`, with the revision and the
  time — kept until the next successful run;
- the log of a waiting agent pod's `wait-for-reconcile`, which prints that
  `lastError` when it belongs to its revision.

`borgUI.reconcile.waitSeconds` (default 300) is how long the Job waits for the
server's `/health`, counted from the start of the Job's container. When the
release waits for the Job, image pull time plus `waitSeconds` must stay below
the release timeout (HelmRelease `spec.timeout`, `helm --timeout`).

## Changing a referenced Secret

The reconcile Job copies what it reads from Secrets into the Borg UI database:
the notification passwords and service URLs, the OIDC client secret, the
license key and the entitlement document. It runs once per Helm revision. A
changed Secret referenced through `existingSecret` / `existingSecretKey` does
not make a new revision by itself: Flux upgrades only when the chart version
or the values change, so the server keeps the old content until the next
revision.

To apply such a change, start a new revision with the same values:

```bash
# Helm: every upgrade is a new revision
helm upgrade <release> <chart> -n borg --reuse-values

# Flux: an unchanged HelmRelease is not upgraded unless forced
flux reconcile helmrelease <release> -n borg --force
```

The reconcile run writes only what differs, so the rest of the server's
settings stay as they are. A new revision also rolls the agent pods (node and
cluster), because they wait for the reconcile of their revision; a backup
running in one of them is interrupted. Apply the change outside the backup
windows.
