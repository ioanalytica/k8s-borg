# Borg UI agents

With `node.backupMode=agent` or `cluster.mode=agent` (see
[Modes](/guide/configuration#modes)), the chart enrolls the backup pods at a
[Borg UI](https://github.com/karanhudia/borg-ui) server as managed agents and
registers their repositories, check schedules and backup plans there. This page
covers what the chart sets up for them; for Borg UI itself, see the
[Borg UI documentation](https://docs.borgui.com).

## Agent pre/post-backup scripts

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
  where the cluster source/DB secrets live. The chart adds `backup-cluster-<engine>`
  for each enabled database and, with `s3.enabled`, `s3-remount-buckets`
  (unmounts every listed bucket and mounts it fresh) and `s3-check-mounts` (exit
  `1` when a listed bucket is not mounted) and, with `s3.verifyListing` as well,
  `s3-verify-listing` (the CronJob's listing check, which also mounts a lost or
  skipped bucket again); in `cluster.backupMode=plan` they are the plan's
  pre-backup hooks, in the order `s3-remount-buckets`, `s3-verify-listing`,
  `s3-check-mounts`, the dumps. The console pod mounts its buckets when it
  starts and keeps them as long as it runs, so the fresh mount before each
  plan run gives the plan path what each CronJob run has. A failing S3 script
  does not stop the backup (`continue_on_error`); a failing database dump does.
  The console pod shares its process namespace, so that the pod's pause
  container reaps the s3fs processes that end after an unmount.
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

## Check and backup schedules

A managed agent takes its `borg check` schedule from `borg.checkSchedule` and
the schedule of its backup plan from `borg.backupSchedule`. Each pod looks up
its own hostname in `perHost` and falls back to `default`:

| Pod | Hostname, the `perHost` key |
| --- | --- |
| console pod (`cluster.mode=agent`) | `cluster.nodeName` itself (default `k8s-borg-mycluster`) |
| node pod (`node.backupMode=agent`) | `k8s-borg-<node name>`, e.g. `k8s-borg-node01` on node `node01` |

The console pod applies the backup schedule only with `cluster.backupMode=plan`;
in `cronjob` mode `cluster.schedule` runs the cluster backup.

```yaml
cluster:
  nodeName: k8s-borg-mycluster
borg:
  checkSchedule:
    default: "0 3 * * *"
    perHost:
      k8s-borg-mycluster: "0 4 * * 0"   # the console pod: cluster.nodeName
  backupSchedule:
    default: "0 2 * * *"
    perHost:
      k8s-borg-mycluster: "0 */4 * * *"
      k8s-borg-node01: "30 2 * * *"     # the node pod on node node01
```

A key that is no pod's hostname is never read: the pod it was meant for runs
on `default`. `helm install` and `helm upgrade` list the keys that no agent pod
applies; a key that starts with `k8s-borg-` counts as a node pod's, as the chart
does not know the node names.

The agents apply their schedules when they start, so a change rolls the pods
that apply it: `borg.checkSchedule` the console pod (`cluster.mode=agent`) and
the node pods (`node.backupMode=agent`), `borg.backupSchedule` the node pods
and, with `cluster.backupMode=plan`, the console pod. The section counts as a
whole: a change to one node's key rolls every pod that applies the section.

A check schedule removed from the values is removed from Borg UI as well:
`set-check-schedule` records the cron it set on the agent's volume
(`/etc/borg-ui-agent/check-schedule-owned`) and removes the schedule only
while Borg UI still has that cron for the repository. A check schedule set by
hand in Borg UI, or given another cron there, stays, and so does every one in
a release without `borg.checkSchedule`. The record holds for the Borg UI the
agent is enrolled at: an agent that enrols anew, at a new or rebuilt server,
drops it. It is written from this version on: a schedule set by an older
version counts as the chart's once a pod has started with the new version and
found it still set. Removed in the same update, it stays in Borg UI; turn it
off there, or with `off`.

`off` removes a pod's check schedule whoever set it, and keeps the pod off
`default`; `default: "off"` does so for every pod without a `perHost` entry.
For a backup schedule `off` means a plan without schedule, also with a
`default`. An unquoted `off` is read as `false` by YAML and counts as `off`.

```yaml
borg:
  checkSchedule:
    default: "0 3 * * *"
    perHost:
      k8s-borg-node02: "off"   # no check schedule on node02, also none set by hand
```

A removed backup schedule turns the plan's schedule off, as
`register-backup-plan` rewrites the whole plan.
