# Configuration

k8s-borg is configured through the chart's values. Each one is documented in
[`values.yaml`](https://github.com/ioanalytica/k8s-borg/blob/main/chart/values.yaml),
and the sections are summed up under [Parameters](/reference/parameters). This
page covers what decides how the backups run; the features have pages of
their own.

## Two ways to run

### Standalone (default)

If `BORG_UI_AGENT` is unset or not `true`, k8s-borg runs **without** Borg UI.
The container entrypoint (`/run.sh run`) validates the environment, mounts the
sources (S3 via `s3fs` for cluster/app jobs), takes the dumps of the configured
database engines (cluster jobs) or the datastore snapshot and the SQLite copies
(node pods, when enabled), then runs `borg-backup` against the pod's assigned
repository. Scheduling is Kubernetes' own: the DaemonSet's interval loop and the
CronJob.

### Borg UI managed agent (optional)

Set `BORG_UI_AGENT=true` (in the chart: `node.backupMode=agent`,
`cluster.mode=agent`) to enroll the pod at a Borg UI server as a **managed
agent** and register its assigned repository with the server. From Borg UI you
then create, schedule and run **backup plans, maintenance jobs and restores**,
next to any other agents and repositories that server manages. Enrollment is
idempotent: an existing `config.toml` skips enrollment as long as the server
still recognises the agent; otherwise the pod enrolls again.

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
  - `cluster.borgUiResync` (default `true`) — in `cronjob` mode with a Borg UI to
    talk to (`borgUI.enabled` or `borgUI.agentConnection.server`), each run ends by
    asking Borg UI to resync the cluster repository, so new and pruned archives and
    the size show up right away instead of on the next periodic reconcile run. Best
    effort: a failure is logged as a warning and never changes the job's exit code.

Managed-agent modes need a reachable server: set `borgUI.agentConnection.server`,
or deploy one in-cluster with `borgUI.enabled=true` (which also runs a reconcile
Job that mints an admin PAT and reconciles `borgUI.oidc`).

## An example release {#example}

The repository's example is a Flux `HelmRepository` and `HelmRelease`; its
`values:` block is an ordinary values file, so the same settings work with
plain Helm. `tests/examples-helm.bats` checks every key it sets against the
chart and renders it. The Secrets it references are in
[`examples/secrets/`](https://github.com/ioanalytica/k8s-borg/tree/main/examples/secrets),
and [`examples/README.md`](https://github.com/ioanalytica/k8s-borg/blob/main/examples/README.md)
describes both.

<<< @/../examples/helm/k8s-borg.yaml
