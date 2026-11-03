# Borg UI server

With `borgUI.enabled=true` the chart deploys a
[Borg UI](https://github.com/karanhudia/borg-ui) server, built from the pinned
`borg-ui` submodule (see [Versioning](/reference/versioning)), with SQLite or an
external PostgreSQL and a Redis cache, and runs a reconcile Job on every install
and upgrade that applies the settings below from the release. The values are
under `borgUI` (see [Parameters](/reference/parameters)). For the server
itself, see the [Borg UI documentation](https://docs.borgui.com).

## Licensing (`borgUI.licensing`) {#licensing}

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
borgUI:
  licensing:
    # online: activate a key (only while the instance carries no paid license)
    licenseKey:
      value: "…"                        # or existingSecret/existingSecretKey
    # air-gapped: import an already-signed entitlement document, no egress
    entitlement:
      existingSecret: borgui-entitlement
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

## Error reports (`borgUI.errorReporting`) {#error-reports}

Borg UI 2.4.1 and later report the server's own errors to the Borg UI
analytics ingest (`https://t.borgui.com/e`) as "Error - Report" events:
unhandled request exceptions, 5xx responses with their cause, startup and
migration failures, and failed jobs. Messages and stack traces are scrubbed of
secrets before they are sent. The image default is on, and nothing is sent while
any user has analytics turned off in Settings > Preferences. To turn the
server's reports off for the whole instance:

```yaml
borgUI:
  errorReporting:
    enabled: false      # ERROR_REPORTING_ENABLED, always rendered
```

The value must be a boolean (a quoted `"false"` fails the render). Older images
ignore it, so it can be set before the `borg-ui` pin moves.

This covers the server only. Usage analytics and the error reports of the web
interface go from the browser to the same ingest and follow each user's own
analytics preference; there is no instance-wide switch for them.

## Extra server env (`borgUI.extraEnv`) {#extra-server-env}

Server settings the chart has no value for can be set as a list of EnvVar
objects, appended after the env the chart renders:

```yaml
borgUI:
  extraEnv:
    - name: LOG_LEVEL
      value: "DEBUG"
    - name: SOME_TOKEN
      valueFrom:
        secretKeyRef: { name: borgui-extra, key: token }
```

A chart value always wins: a name the chart already sets for the current values
(`TZ`, `PUBLIC_BASE_URL`, `ENABLE_STARTUP_LICENSE_SYNC`, `ERROR_REPORTING_ENABLED`,
`REDIS_*`, `DB_*`, …) fails the render, as does a name listed twice, because
Kubernetes keeps only the last of two entries with one name.
Set those through their chart values. Because the extra entries come last, their
values can refer to the chart's as `$(NAME)`.

## Notification channels (`borgUI.notifications`) {#notification-channels}

A fresh Borg UI has no notification channel, so every failed backup stays
silent until somebody adds one in the UI. The reconcile Job can provision them
from the release instead:

```yaml
borgUI:
  notifications:
    - name: ops-mail
      email:
        smtp: { host: smtp.example.com, port: 587, mode: starttls }   # mode: starttls | ssl | insecure
        username: alerts@example.com
        password:                       # the only secret: value or existingSecret+existingSecretKey
          existingSecret: borgui-mail
          existingSecretKey: password
        from: alerts@example.com
        fromName: "Borg UI prod"        # optional
        to: [ops@example.com]           # cc, bcc, replyTo optional
      titlePrefix: "[prod]"
      events:                           # optional; omitted = the API defaults
        backupWarning: true
    - name: chat                        # anything that is not e-mail: a whole Apprise URL
      serviceUrl:
        existingSecret: borgui-notifications
        existingSecretKey: chat
```

An `email` channel keeps everything but the password in plain values, visible
in the release; the password reaches only a Secret and the Job. The Job assembles the Apprise `mailtos://` URL (`mailto://` for
`mode: insecure`) at run time and percent-encodes every part itself, so the
password needs no escaping. For any other Apprise service, `serviceUrl` takes
the whole URL from a Secret, since such URLs carry their token in the URL:

```bash
kubectl create secret generic borgui-notifications -n borg \
  --from-literal=chat='json://hooks.example.com/notify?token=…'
```

- **Matched by name.** A missing channel is created; an existing one is updated
  with only the fields that differ; an equal one causes no write. Channels with
  other names — made in the UI — are never touched.
- **Nothing is deleted.** Removing an entry leaves its channel in Borg UI;
  delete it in the UI.
- **Only what an entry names is enforced.** Without `events` a new channel gets
  the API defaults: every failure event, stale backups and the backup report on;
  start, success and warning off. A flag the values do not name keeps whatever
  the UI sets later. `enabled` defaults to `true`, so a channel switched off in
  the UI is switched on again by the next reconcile — set `enabled: false` to
  keep it off. `monitorAllRepositories: false` leaves the repository selection
  to the UI: the repositories the agents register do not exist yet when the
  reconcile Job runs.
- **Best effort.** A channel the server rejects (a malformed URL, say), or
  whose Secret or key does not exist, is a warning in the Job log; the release
  still succeeds and agents still start.
  The Job does not send a test message.
- **Credentials stay out of the manifests.** The SMTP password or a whole
  `serviceUrl` never lands in a ConfigMap or the Job's spec; the Job reads it
  from a Secret-backed variable and never prints it. Given as `value`, it goes
  into the chart Secret, but Helm also keeps it in the release's values, where
  anyone with access to the release reads it (`helm get values`). Use
  `existingSecret` when a credential must not be part of the release. A
  changed Secret is applied on the next reconcile run, see
  [Changing a referenced Secret](/operations/troubleshooting#changing-a-referenced-secret).
