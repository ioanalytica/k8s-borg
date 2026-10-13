{{- /*
Copyright IO ANALYTICA.
SPDX-License-Identifier: AGPL-3.0-only
*/}}

{{/*
Agent/backup image. Tag defaults to .Chart.AppVersion.
*/}}
{{- define "k8s-borg.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- $imageRoot := merge (dict "tag" $tag) .Values.image -}}
{{- include "common.images.image" (dict "imageRoot" $imageRoot "global" .Values.global) -}}
{{- end -}}

{{/*
Borg UI server image.
*/}}
{{- define "k8s-borg.ui.image" -}}
{{- include "common.images.image" (dict "imageRoot" .Values.borgUI.image "global" .Values.global) -}}
{{- end -}}

{{/*
Image pull secrets for all images in this chart.
*/}}
{{- define "k8s-borg.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image .Values.borgUI.image) "global" .Values.global) -}}
{{- end -}}

{{/*
Internal Redis pod name/image (borgUI.redis.mode=internal).
*/}}
{{- define "k8s-borg.redis.fullname" -}}
{{- printf "%s-redis" (include "common.names.fullname" .) -}}
{{- end -}}

{{- define "k8s-borg.redis.image" -}}
{{- include "common.images.image" (dict "imageRoot" .Values.borgUI.redis.internal.image "global" .Values.global) -}}
{{- end -}}

{{/*
Redis selector labels. Equivalent to k8s-borg.matchLabels with component=redis.
*/}}
{{- define "k8s-borg.redis.selectorLabels" -}}
{{- include "k8s-borg.matchLabels" (dict "context" . "component" "redis") -}}
{{- end -}}

{{/*
Redis connection env, used both by the Borg UI server (a working startup default
before the reconcile Job runs) and by the reconcile Job (to assemble the redis_url
it persists into the DB). Emits REDIS_* so the server auto-selects Redis over its
in-memory fallback. Nothing when borgUI.redis.mode=disabled.

NB: the cache TTL is NOT an env knob — borg-ui's env CACHE_TTL_SECONDS is only a
startup default that the DB/UI setting shadows (and a UI Save would clobber). The
authoritative TTL (cache_ttl_minutes) is reconciled into the DB instead — see the
reconcile Job.
*/}}
{{- define "k8s-borg.env.redis" -}}
{{- $r := .Values.borgUI.redis -}}
{{- if eq $r.mode "internal" }}
- name: REDIS_HOST
  value: {{ include "k8s-borg.redis.fullname" . | quote }}
- name: REDIS_PORT
  value: "6379"
- name: REDIS_DB
  value: "0"
{{- else if eq $r.mode "external" }}
{{- if $r.external.url }}
- name: REDIS_URL
  value: {{ $r.external.url | quote }}
{{- else }}
- name: REDIS_HOST
  value: {{ required "borgUI.redis.external.host (or .url) is required for mode=external" $r.external.host | quote }}
- name: REDIS_PORT
  value: {{ $r.external.port | quote }}
- name: REDIS_DB
  value: {{ $r.external.db | quote }}
{{- end }}
{{- end }}
{{- if and (ne $r.mode "disabled") (or $r.auth.value $r.auth.existingSecret) }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $r.auth.existingSecret | default (include "k8s-borg.secretName" .) }}
      key: {{ $r.auth.existingSecretKey | default "REDIS_PASSWORD" }}
{{- end }}
{{- end -}}

{{/*
Postgres connection env for the UI server. Emits DB_* parts that the server
assembles into DATABASE_URL (quoting the password itself). Nothing here when
disabled → the server falls back to its SQLite file.
Credentials come from an existing Secret when one is named, else from the inline
values; a Postgres operator's generated Secret is the intended case.
*/}}
{{- define "k8s-borg.env.postgres" -}}
{{- $pg := .Values.borgUI.postgres -}}
{{- if $pg.enabled }}
- name: DB_HOST
  value: {{ required "borgUI.postgres.host is required when borgUI.postgres.enabled" $pg.host | quote }}
- name: DB_PORT
  value: {{ $pg.port | quote }}
- name: DB_NAME
  value: {{ $pg.database | quote }}
{{- if $pg.existingSecret }}
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: {{ $pg.existingSecret | quote }}
      key: {{ $pg.userKey | default "username" | quote }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $pg.existingSecret | quote }}
      key: {{ $pg.passwordKey | default "password" | quote }}
{{- else }}
- name: DB_USER
  value: {{ required "borgUI.postgres.user (or existingSecret) is required when borgUI.postgres.enabled" $pg.user | quote }}
- name: DB_PASSWORD
  value: {{ required "borgUI.postgres.password (or existingSecret) is required when borgUI.postgres.enabled" $pg.password | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Secret names (support existing secrets).
*/}}
{{- define "k8s-borg.secretName" -}}
{{- .Values.existingSecret | default (printf "%s" (include "common.names.fullname" .)) -}}
{{- end -}}

{{- define "k8s-borg.sshSecretName" -}}
{{- .Values.ssh.existingSecret | default (printf "%s-ssh" (include "common.names.fullname" .)) -}}
{{- end -}}

{{/* The Secret with an engine's static *.conf files. Usage: include "k8s-borg.databases.secretName" (dict "context" $ "engine" "postgres") */}}
{{- define "k8s-borg.databases.secretName" -}}
{{- (index .context.Values.databases .engine).existingSecret | default (printf "%s-%s" (include "common.names.fullname" .context) .engine) -}}
{{- end -}}

{{- define "k8s-borg.configMapName" -}}
{{- printf "%s-config" (include "common.names.fullname" .) -}}
{{- end -}}

{{- define "k8s-borg.checkSchedulesConfigMapName" -}}
{{- printf "%s-check-schedules" (include "common.names.fullname" .) -}}
{{- end -}}

{{- define "k8s-borg.backupSchedulesConfigMapName" -}}
{{- printf "%s-backup-schedules" (include "common.names.fullname" .) -}}
{{- end -}}

{{- define "k8s-borg.nodeAgentScriptsConfigMapName" -}}
{{- printf "%s-node-agent-scripts" (include "common.names.fullname" .) -}}
{{- end -}}

{{- define "k8s-borg.clusterAgentScriptsConfigMapName" -}}
{{- printf "%s-cluster-agent-scripts" (include "common.names.fullname" .) -}}
{{- end -}}

{{/*
Effective cluster agent scripts: default DB-dump wrappers for each enabled
database, deep-merged with user-provided cluster.agentScripts (user keys win on
collision). Returns a YAML map (consume with `| fromYaml`).
*/}}
{{- define "k8s-borg.defaultDbDumpScript" -}}
#!/bin/sh
exec /usr/local/bin/backup-cluster-{{ .engine }} "$@"
{{- end -}}

{{- define "k8s-borg.cluster.agentScripts" -}}
{{- $scripts := .Values.cluster.agentScripts | default dict | deepCopy -}}
{{- if .Values.s3.enabled -}}
{{- $scripts = merge $scripts (dict "s3-remount-buckets" "#!/bin/sh\nexec /usr/local/bin/s3-remount-buckets /root/.borg/cluster-s3-buckets") -}}
{{- $scripts = merge $scripts (dict "s3-check-mounts" "#!/bin/sh\nexec /usr/local/bin/s3-mount-buckets --check /root/.borg/cluster-s3-buckets") -}}
{{- if .Values.s3.verifyListing -}}
{{- $scripts = merge $scripts (dict "s3-verify-listing" "#!/bin/sh\nexec /usr/local/bin/s3-verify-listing /root/.borg/cluster-s3-buckets") -}}
{{- end -}}
{{- end -}}
{{- range $engine := splitList " " (include "k8s-borg.databases.configured" .) | compact -}}
{{- $scripts = merge $scripts (dict (printf "backup-cluster-%s" $engine) (include "k8s-borg.defaultDbDumpScript" (dict "engine" $engine))) -}}
{{- end -}}
{{- toYaml $scripts -}}
{{- end -}}

{{/*
Effective node agent scripts: with node.datastoreSnapshot.enabled the snapshot
and its removal, deep-merged with user-provided node.agentScripts (user keys win
on collision). Returns a YAML map (consume with `| fromYaml`).
*/}}
{{- define "k8s-borg.node.agentScripts" -}}
{{- $scripts := .Values.node.agentScripts | default dict | deepCopy -}}
{{- if .Values.node.datastoreSnapshot.enabled -}}
{{- $scripts = merge $scripts (dict "datastore-snapshot" "#!/bin/sh\n# borg-ui: Snapshot the cluster datastore (etcd, k3s) for the backup\nexec /usr/local/bin/datastore-snapshot save") -}}
{{- $scripts = merge $scripts (dict "datastore-snapshot-clean" "#!/bin/sh\n# borg-ui: Remove the cluster datastore snapshot after the backup\nexec /usr/local/bin/datastore-snapshot clean") -}}
{{- end -}}
{{- toYaml $scripts -}}
{{- end -}}

{{/*
Where the node pod keeps the datastore snapshot during a run (a memory-backed
emptyDir); the node include patterns archive it from there.
*/}}
{{- define "k8s-borg.datastoreSnapshotDir" -}}
/var/lib/k8s-borg/datastore
{{- end -}}

{{/*
Per-component standard labels. Usage: include "k8s-borg.labels" (dict "context" $ "component" "node")
*/}}
{{- define "k8s-borg.labels" -}}
{{- include "common.labels.standard" (dict "customLabels" (dict "app.kubernetes.io/component" .component) "context" .context) -}}
{{- end -}}

{{/*
Per-component selector labels. NOT common.labels.matchLabels: that helper picks
only name+instance out of customLabels, which would collapse every component's
selector onto the same set and let the UI Deployment's selector match node/app
pods. The component is what makes a selector identify one workload.
*/}}
{{- define "k8s-borg.matchLabels" -}}
app.kubernetes.io/name: {{ include "common.names.name" .context }}
app.kubernetes.io/instance: {{ .context.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Init container that stages the SSH key/known_hosts into an in-memory volume
with the right ownership/mode. Identical across all backup workloads.
*/}}
{{- define "k8s-borg.sshInitContainer" -}}
- name: configure
  image: {{ .Values.initImage.repository }}:{{ .Values.initImage.tag }}
  imagePullPolicy: {{ .Values.initImage.pullPolicy }}
  command:
    - /bin/sh
    - -c
    - |
      # stage SSH credentials into the in-memory volume
      cp /ssh-secret/id* /ssh/
      cp /ssh-secret/known_hosts /ssh/
      chown -R 0:0 /ssh
      chmod 700 /ssh
      chmod 600 /ssh/*
      # pre-create configured mount points on the shared /mnt volume so the main
      # container (and s3fs) can mount there
      {{- if .Values.s3.enabled }}
      mkdir -p {{ .Values.s3.mountPath | quote }}
      {{- end }}
      {{- range .Values.mountPoints }}
      mkdir -p {{ . | quote }}
      {{- end }}
  volumeMounts:
    - name: ssh-credentials
      mountPath: /ssh
    - name: ssh-secret
      mountPath: /ssh-secret
      readOnly: true
    - name: mounts
      mountPath: /mnt
{{- end -}}

{{/*
Borg UI in-cluster Service URL (used for agent enrollment and the reconcile Job).
Derived from the release unless borgUI.agentConnection.server overrides it.
*/}}
{{- define "k8s-borg.ui.serverUrl" -}}
{{- if .Values.borgUI.agentConnection.server -}}
{{- .Values.borgUI.agentConnection.server -}}
{{- else -}}
{{- printf "http://%s-ui.%s.svc.cluster.local:%v" (include "common.names.fullname" .) .Release.Namespace .Values.borgUI.service.port -}}
{{- end -}}
{{- end -}}

{{/*
Whether any backup workload enrols at Borg UI as a managed agent — the console
pod (cluster.mode=agent) or the DaemonSet (node.backupMode=agent). Gates the schedule
ConfigMaps and the enrollment admin credentials. Emits "true" or "".
*/}}
{{- define "k8s-borg.anyAgent" -}}
{{- if or (and .Values.cluster.enabled (eq .Values.cluster.mode "agent")) (and .Values.node.enabled (eq .Values.node.backupMode "agent")) -}}
true
{{- end -}}
{{- end -}}

{{/*
Names for the reconcile Job's PAT Secret, ServiceAccount and Role.
*/}}
{{- define "k8s-borg.ui.patSecretName" -}}
{{- printf "%s-ui-pat" (include "common.names.fullname" .) -}}
{{- end -}}
{{- define "k8s-borg.reconcileSAName" -}}
{{- printf "%s-reconcile" (include "common.names.fullname" .) -}}
{{- end -}}

{{/*
Where the SSH key is staged for the Borg UI server to import as its system key.
*/}}
{{- define "k8s-borg.ui.sshKeyDir" -}}/etc/borg-ui-ssh{{- end -}}

{{/*
Reconcile-status ConfigMap + agent ServiceAccount names.
*/}}
{{- define "k8s-borg.ui.reconcileStatusCMName" -}}
{{- printf "%s-reconcile-status" (include "common.names.fullname" .) -}}
{{- end -}}
{{- define "k8s-borg.agentSAName" -}}
{{- printf "%s-agent" (include "common.names.fullname" .) -}}
{{- end -}}

{{/*
Whether agent workloads should gate their startup on the reconcile Job's success
(GitLab migrate-job style) — only when an in-cluster server + reconcile Job exist
in THIS release AND at least one workload runs as an agent. Emits "true" or "".
*/}}
{{- define "k8s-borg.ui.reconcileGate" -}}
{{- if and .Values.borgUI.enabled .Values.borgUI.reconcile.enabled (include "k8s-borg.anyAgent" .) -}}
true
{{- end -}}
{{- end -}}

{{/*
Gating init container: blocks until the reconcile Job has published this release
revision into the reconcile-status ConfigMap (which it only does after the server
is healthy and fully reconciled). While it waits, it prints the failure the Job
of this revision left there (data.lastError), once per change. Needs the agent
ServiceAccount's RBAC (get on that one ConfigMap). Uses the agent image (curl +
python3).
*/}}
{{- define "k8s-borg.waitForReconcileInitContainer" -}}
- name: wait-for-reconcile
  image: {{ include "k8s-borg.image" . | quote }}
  imagePullPolicy: {{ .Values.image.pullPolicy | quote }}
  command:
    - /bin/sh
    - -c
    - |
      SA=/var/run/secrets/kubernetes.io/serviceaccount
      ns=$(cat "$SA/namespace")
      echo "Waiting for Borg UI reconcile (token ${RECONCILE_TOKEN}) …"
      deadline=$(( $(date +%s) + ${RECONCILE_WAIT_SECONDS:-600} ))
      shown=""
      while :; do
        cm=$(curl -sS --connect-timeout 5 --max-time 10 --cacert "$SA/ca.crt" -H "Authorization: Bearer $(cat "$SA/token")" \
               "https://kubernetes.default.svc/api/v1/namespaces/${ns}/configmaps/${RECONCILE_STATUS_CONFIGMAP}" 2>/dev/null || true)
        val=$(printf %s "$cm" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("data",{}).get("reconciled",""))' 2>/dev/null || true)
        [ "$val" = "${RECONCILE_TOKEN}" ] && break
        err=$(printf %s "$cm" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("data",{}).get("lastError",""))' 2>/dev/null || true)
        case "$err" in
          "revision ${RECONCILE_TOKEN} at "*)
            [ "$err" = "$shown" ] || { echo "The reconcile Job failed: ${err}" >&2; shown=$err; } ;;
        esac
        [ "$(date +%s)" -lt "$deadline" ] || { echo "reconcile not complete within ${RECONCILE_WAIT_SECONDS:-600}s" >&2; exit 1; }
        sleep 3
      done
      echo "Reconcile complete — proceeding."
  env:
    - name: RECONCILE_STATUS_CONFIGMAP
      value: {{ include "k8s-borg.ui.reconcileStatusCMName" . | quote }}
    - name: RECONCILE_TOKEN
      value: {{ .Release.Revision | quote }}
    - name: RECONCILE_WAIT_SECONDS
      value: {{ .Values.borgUI.reconcile.waitSeconds | quote }}
{{- end -}}

{{/*
Whether the Borg UI server should carry the pods' SSH key as its system key —
explicitly (systemSshKey.import) or implicitly because remote machines are
configured (they need it). Emits "true" or "".
*/}}
{{- define "k8s-borg.ui.systemKeyActive" -}}
{{- if and .Values.borgUI.enabled (or .Values.borgUI.systemSshKey.import (gt (len .Values.borgUI.remoteMachines) 0)) -}}
true
{{- end -}}
{{- end -}}

{{/*
Whether the reconcile Job provisions notification channels (it is the only
consumer of their credentials). Emits "true" or "".
*/}}
{{- define "k8s-borg.ui.notificationsActive" -}}
{{- if and .Values.borgUI.enabled .Values.borgUI.reconcile.enabled .Values.borgUI.notifications -}}
true
{{- end -}}
{{- end -}}

{{/*
borgUI.notifications as the reconcile Job reads it: name, the settings to
enforce under the API's field names, and either the email fields it assembles
the Apprise URL from (+ the variable carrying the password) or the variable
carrying a whole serviceUrl. Only what an entry sets is listed, so the rest
keeps the API's default on creation and the UI's choice afterwards. No
credential in here.
*/}}
{{- define "k8s-borg.ui.notificationsJson" -}}
{{- include "k8s-borg.ui.notifications.validate" . -}}
{{- $out := list -}}
{{- range $i, $n := .Values.borgUI.notifications -}}
{{- $s := dict "enabled" (ternary $n.enabled true (hasKey $n "enabled")) -}}
{{- if $n.titlePrefix -}}{{- $_ := set $s "title_prefix" $n.titlePrefix -}}{{- end -}}
{{- if hasKey $n "includeJobNameInTitle" -}}{{- $_ := set $s "include_job_name_in_title" $n.includeJobNameInTitle -}}{{- end -}}
{{- if hasKey $n "monitorAllRepositories" -}}{{- $_ := set $s "monitor_all_repositories" $n.monitorAllRepositories -}}{{- end -}}
{{- range $k, $v := ($n.events | default dict) -}}{{- $_ := set $s (printf "notify_on_%s" (snakecase $k)) $v -}}{{- end -}}
{{- $c := dict "name" $n.name "settings" $s -}}
{{- if $n.email -}}
{{- $e := $n.email -}}
{{- $m := dict "smtpHost" $e.smtp.host "mode" ($e.smtp.mode | default "starttls") "from" $e.from "to" $e.to -}}
{{- if $e.smtp.port -}}{{- $_ := set $m "port" (int $e.smtp.port) -}}{{- end -}}
{{- range $k := list "username" "fromName" "cc" "bcc" "replyTo" -}}
{{- if get $e $k -}}{{- $_ := set $m $k (get $e $k) -}}{{- end -}}
{{- end -}}
{{- $_ := set $c "email" $m -}}
{{- if $e.password -}}{{- $_ := set $c "passwordEnv" (printf "BORG_UI_NOTIFICATION_PASSWORD_%d" $i) -}}{{- end -}}
{{- else -}}
{{- $_ := set $c "urlEnv" (printf "BORG_UI_NOTIFICATION_URL_%d" $i) -}}
{{- end -}}
{{- $out = append $out $c -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
The credentials of borgUI.notifications as a JSON list of {env, secret, key}
(+ value when the chart Secret carries it): an email channel's password, or a
whole serviceUrl. Feeds the reconcile Job's env and the chart Secret.
*/}}
{{- define "k8s-borg.ui.notificationSecrets" -}}
{{- include "k8s-borg.ui.notifications.validate" . -}}
{{- $refs := list -}}
{{- range $i, $n := .Values.borgUI.notifications -}}
{{- $env := "" -}}{{- $src := dict -}}
{{- if $n.email -}}
{{- if $n.email.password -}}{{- $env = printf "BORG_UI_NOTIFICATION_PASSWORD_%d" $i -}}{{- $src = $n.email.password -}}{{- end -}}
{{- else -}}
{{- $env = printf "BORG_UI_NOTIFICATION_URL_%d" $i -}}{{- $src = $n.serviceUrl -}}
{{- end -}}
{{- if $env -}}
{{- if $src.existingSecret -}}
{{- $refs = append $refs (dict "env" $env "secret" $src.existingSecret "key" $src.existingSecretKey) -}}
{{- else -}}
{{- $refs = append $refs (dict "env" $env "secret" (include "k8s-borg.secretName" $) "key" $env "value" (toString $src.value)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toJson $refs -}}
{{- end -}}

{{/*
validateSecretRef: a sensitive field given as value or existingSecret+existingSecretKey.
Usage: include "k8s-borg.ui.notifications.validateSecretRef" (dict "ref" $x "path" "…")
*/}}
{{- define "k8s-borg.ui.notifications.validateSecretRef" -}}
{{- if not (kindIs "map" .ref) -}}{{- fail (printf "%s must be a map with value or existingSecret+existingSecretKey" .path) -}}{{- end -}}
{{- range $k := list "value" "existingSecret" "existingSecretKey" -}}
{{- if and (hasKey $.ref $k) (not (kindIs "string" (get $.ref $k))) -}}{{- fail (printf "%s.%s must be a string (quote it)" $.path $k) -}}{{- end -}}
{{- end -}}
{{- if .ref.existingSecret -}}
{{- if not .ref.existingSecretKey -}}{{- fail (printf "%s.existingSecretKey is required with existingSecret" .path) -}}{{- end -}}
{{- else if not .ref.value -}}
{{- fail (printf "%s needs value or existingSecret+existingSecretKey" .path) -}}
{{- else if and .url (not (regexMatch "^[A-Za-z][A-Za-z0-9+.-]*://" .ref.value)) -}}
{{- fail (printf "%s.value must be an Apprise URL (scheme://…)" .path) -}}
{{- end -}}
{{- end -}}

{{/*
Refuse malformed borgUI.notifications entries at render time; a typo would
otherwise only show up as a warning in the reconcile Job's log.
*/}}
{{- define "k8s-borg.ui.notifications.validate" -}}
{{- $keys := list "name" "email" "serviceUrl" "enabled" "titlePrefix" "includeJobNameInTitle" "monitorAllRepositories" "events" -}}
{{- $emailKeys := list "smtp" "username" "password" "from" "fromName" "to" "cc" "bcc" "replyTo" -}}
{{- $events := list "backupStart" "backupSuccess" "backupWarning" "backupFailure" "restoreSuccess" "restoreFailure" "checkSuccess" "checkFailure" "restoreCheckSuccess" "restoreCheckFailure" "scheduleFailure" "staleBackup" "backupReport" -}}
{{- $addr := "^[^@\\s<>,;\"]+@[^@\\s<>,;\"]+$" -}}
{{- $seen := dict -}}
{{- range $i, $n := .Values.borgUI.notifications -}}
{{- $p := printf "borgUI.notifications[%d]" $i -}}
{{- if not (kindIs "map" $n) -}}{{- fail (printf "%s must be a map with name and email or serviceUrl" $p) -}}{{- end -}}
{{- range $k, $_ := $n -}}
{{- if not (has $k $keys) -}}{{- fail (printf "%s: unknown key %q (known: %s)" $p $k (join ", " $keys)) -}}{{- end -}}
{{- end -}}
{{- if not (and (kindIs "string" $n.name) $n.name) -}}{{- fail (printf "%s.name is required" $p) -}}{{- end -}}
{{- if hasKey $seen $n.name -}}{{- fail (printf "borgUI.notifications: name %q is used twice — channels are matched by name" $n.name) -}}{{- end -}}
{{- $_ := set $seen $n.name true -}}
{{- if and (hasKey $n "email") (hasKey $n "serviceUrl") -}}{{- fail (printf "%s: set email or serviceUrl, not both" $p) -}}{{- end -}}
{{- if hasKey $n "serviceUrl" -}}
{{- include "k8s-borg.ui.notifications.validateSecretRef" (dict "ref" $n.serviceUrl "path" (printf "%s.serviceUrl" $p) "url" true) -}}
{{- else if hasKey $n "email" -}}
{{- $e := $n.email -}}
{{- $ep := printf "%s.email" $p -}}
{{- if not (kindIs "map" $e) -}}{{- fail (printf "%s must be a map (smtp, from, to, …)" $ep) -}}{{- end -}}
{{- range $k, $_ := $e -}}
{{- if not (has $k $emailKeys) -}}{{- fail (printf "%s: unknown key %q (known: %s)" $ep $k (join ", " $emailKeys)) -}}{{- end -}}
{{- end -}}
{{- $smtp := $e.smtp | default dict -}}
{{- if not (kindIs "map" $smtp) -}}{{- fail (printf "%s.smtp must be a map (host, port, mode)" $ep) -}}{{- end -}}
{{- range $k, $_ := $smtp -}}
{{- if not (has $k (list "host" "port" "mode")) -}}{{- fail (printf "%s.smtp: unknown key %q (known: host, port, mode)" $ep $k) -}}{{- end -}}
{{- end -}}
{{- if not (and (kindIs "string" $smtp.host) $smtp.host) -}}{{- fail (printf "%s.smtp.host is required" $ep) -}}{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$" $smtp.host) -}}{{- fail (printf "%s.smtp.host must be a host name or IPv4 address (got %q)" $ep $smtp.host) -}}{{- end -}}
{{- if hasKey $smtp "port" -}}
{{- $port := $smtp.port -}}
{{- if not (and (or (kindIs "float64" $port) (kindIs "int" $port) (kindIs "int64" $port)) (eq (float64 (int $port)) (float64 $port)) (ge (int $port) 1) (le (int $port) 65535)) -}}
{{- fail (printf "%s.smtp.port must be a number from 1 to 65535" $ep) -}}
{{- end -}}
{{- end -}}
{{- if not (has ($smtp.mode | default "starttls") (list "starttls" "ssl" "insecure")) -}}{{- fail (printf "%s.smtp.mode must be \"starttls\", \"ssl\" or \"insecure\" (got %q)" $ep (toString $smtp.mode)) -}}{{- end -}}
{{- if not (and (kindIs "string" $e.from) (regexMatch $addr ($e.from | default ""))) -}}{{- fail (printf "%s.from must be an e-mail address" $ep) -}}{{- end -}}
{{- if and (hasKey $e "replyTo") (not (and (kindIs "string" $e.replyTo) (regexMatch $addr ($e.replyTo | default "")))) -}}{{- fail (printf "%s.replyTo must be an e-mail address" $ep) -}}{{- end -}}
{{- range $k := list "fromName" "username" -}}
{{- if and (hasKey $e $k) (not (kindIs "string" (get $e $k))) -}}{{- fail (printf "%s.%s must be a string" $ep $k) -}}{{- end -}}
{{- end -}}
{{- if not $e.to -}}{{- fail (printf "%s.to needs at least one address" $ep) -}}{{- end -}}
{{- range $k := list "to" "cc" "bcc" -}}
{{- if hasKey $e $k -}}
{{- $l := get $e $k -}}
{{- if not (kindIs "slice" $l) -}}{{- fail (printf "%s.%s must be a list of e-mail addresses" $ep $k) -}}{{- end -}}
{{- range $a := $l -}}
{{- if not (and (kindIs "string" $a) (regexMatch $addr $a)) -}}{{- fail (printf "%s.%s: %q is not an e-mail address" $ep $k (toString $a)) -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if hasKey $e "password" -}}
{{- if not $e.username -}}{{- fail (printf "%s.password needs email.username (the SMTP login)" $ep) -}}{{- end -}}
{{- include "k8s-borg.ui.notifications.validateSecretRef" (dict "ref" $e.password "path" (printf "%s.password" $ep)) -}}
{{- end -}}
{{- else -}}
{{- fail (printf "%s needs email or serviceUrl" $p) -}}
{{- end -}}
{{- range $k := list "enabled" "includeJobNameInTitle" "monitorAllRepositories" -}}
{{- if and (hasKey $n $k) (not (kindIs "bool" (get $n $k))) -}}{{- fail (printf "%s.%s must be true or false" $p $k) -}}{{- end -}}
{{- end -}}
{{- if gt (len (toString ($n.titlePrefix | default ""))) 100 -}}{{- fail (printf "%s.titlePrefix is longer than 100 characters" $p) -}}{{- end -}}
{{- range $k, $v := ($n.events | default dict) -}}
{{- if not (has $k $events) -}}{{- fail (printf "%s.events: unknown event %q (known: %s)" $p $k (join ", " $events)) -}}{{- end -}}
{{- if not (kindIs "bool" $v) -}}{{- fail (printf "%s.events.%s must be true or false" $p $k) -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Init container that stages the SSH key into an in-memory volume owned by the Borg
UI server user (uid 1001) with sane modes, so the server can read it once to import
as its system key. A plain secret mount would be root-owned / wrong mode.
*/}}
{{- define "k8s-borg.uiSshInitContainer" -}}
- name: stage-ssh-key
  image: {{ .Values.initImage.repository }}:{{ .Values.initImage.tag }}
  imagePullPolicy: {{ .Values.initImage.pullPolicy }}
  command:
    - /bin/sh
    - -c
    - |
      cp /ssh-secret/id_ed25519 /ssh-staged/id_ed25519
      cp /ssh-secret/id_ed25519.pub /ssh-staged/id_ed25519.pub
      chown 1001:1001 /ssh-staged/id_ed25519 /ssh-staged/id_ed25519.pub
      chmod 600 /ssh-staged/id_ed25519
      chmod 644 /ssh-staged/id_ed25519.pub
  volumeMounts:
    - name: ssh-secret
      mountPath: /ssh-secret
      readOnly: true
    - name: ssh-staged
      mountPath: /ssh-staged
{{- end -}}

{{/*
Gating init container for managed-agent workloads: blocks pod startup until the
Borg UI server answers /health, so the agent never races enrollment against a
server (and its reconcile Job) that isn't up yet. Uses the agent image (has curl).
*/}}
{{- define "k8s-borg.waitForBorgUIInitContainer" -}}
- name: wait-for-borgui
  image: {{ include "k8s-borg.image" . | quote }}
  imagePullPolicy: {{ .Values.image.pullPolicy | quote }}
  command: ["/bin/sh", "-c"]
  args:
    - |
      echo "Waiting for Borg UI at ${BORG_UI_SERVER}/health …"
      until curl -fsS -o /dev/null "${BORG_UI_SERVER}/health"; do sleep 3; done
      echo "Borg UI is up."
  env:
    - name: BORG_UI_SERVER
      value: {{ include "k8s-borg.ui.serverUrl" . | quote }}
{{- end -}}

{{/*
Common backup env. Requires NODE_NAME to be defined earlier in the env list
(BORG_REPO references it). Non-sensitive knobs come from values; sensitive ones
resolve to the chart Secret or a per-field existingSecret[+existingSecretKey].
*/}}
{{- define "k8s-borg.env.common" -}}
- name: TZ
  value: {{ .Values.timezone | quote }}
- name: BORG_REPO_BASE
  valueFrom:
    secretKeyRef:
      name: {{ .Values.borg.repoBase.existingSecret | default (include "k8s-borg.secretName" .) }}
      key: {{ .Values.borg.repoBase.existingSecretKey | default "BORG_REPO_BASE" }}
- name: BORG_REPO
  value: "$(BORG_REPO_BASE)/$(NODE_NAME)"
- name: BORG_VERSION
  value: {{ .Values.borg.version | quote }}
{{- if .Values.borg.encryption }}
- name: BORG_ENCRYPTION
  value: {{ .Values.borg.encryption | quote }}
{{- end }}
{{- /*
Borg's key files go to the uiAgent volume, next to the agent's config.toml
(k8s-borg.volumeMounts.common mounts it per node): a keyfile repository stays
readable after the pod is gone. Set for every mode, so that a later change of
borg.encryption does not hide the key of a repository that exists.
*/}}
- name: BORG_KEYS_DIR
  value: "/etc/borg-ui-agent/borg-keys"
- name: BORG_TREAT_WARNINGS_AS_ERRORS
  value: {{ .Values.borg.treatWarningsAsErrors | quote }}
{{- if .Values.borg.remotePath }}
- name: BORG_REMOTE_PATH
  value: {{ .Values.borg.remotePath | quote }}
{{- end }}
{{- if .Values.borg.defaultParams }}
{{- if eq (toString .Values.borg.version) "2" }}
- name: BORG2_DEFAULT_PARAMS
  value: {{ .Values.borg.defaultParams | quote }}
{{- else }}
- name: BORG1_DEFAULT_PARAMS
  value: {{ .Values.borg.defaultParams | quote }}
{{- end }}
{{- end }}
- name: BORG_PASSPHRASE
  valueFrom:
    secretKeyRef:
      name: {{ .Values.borg.passphrase.existingSecret | default (include "k8s-borg.secretName" .) }}
      key: {{ .Values.borg.passphrase.existingSecretKey | default "BORG_PASSPHRASE" }}
{{- if .Values.borg.archiveNameTemplate }}
- name: BORG_ARCHIVE_NAME_TEMPLATE
  value: {{ .Values.borg.archiveNameTemplate | quote }}
{{- end }}
- name: DB_BACKUP_LOCATION
  value: {{ .Values.borg.dbBackupLocation | quote }}
- name: KEEP_DAILY
  value: {{ .Values.borg.retention.daily | quote }}
- name: KEEP_WEEKLY
  value: {{ .Values.borg.retention.weekly | quote }}
- name: KEEP_MONTHLY
  value: {{ .Values.borg.retention.monthly | quote }}
- name: S3_ENABLED
  value: {{ .Values.s3.enabled | quote }}
{{- if .Values.s3.enabled }}
- name: S3_ENDPOINT
  value: {{ .Values.s3.endpoint | quote }}
- name: S3_REGION
  value: {{ .Values.s3.region | quote }}
- name: S3_MOUNTPOINT
  value: {{ .Values.s3.mountPath | quote }}
- name: S3_VERIFY_LISTING
  value: {{ .Values.s3.verifyListing | quote }}
- name: S3_ON_MOUNT_FAILURE
  value: {{ .Values.s3.onMountFailure | quote }}
- name: AWS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.s3.accessKey.existingSecret | default (include "k8s-borg.secretName" .) }}
      key: {{ .Values.s3.accessKey.existingSecretKey | default "AWS_KEY" }}
- name: AWS_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.s3.secretKey.existingSecret | default (include "k8s-borg.secretName" .) }}
      key: {{ .Values.s3.secretKey.existingSecretKey | default "AWS_SECRET_KEY" }}
{{- end }}
{{- end -}}

{{/*
Whether the cluster CronJob asks Borg UI for a resync of its repository after
each run: the CronJob exists, cluster.borgUiResync is on and there is a Borg UI
to talk to (the in-cluster server or borgUI.agentConnection.server). Also makes
the chart Secret carry the admin password for it. Emits "true" or "".
*/}}
{{- define "k8s-borg.cluster.borgUiResync" -}}
{{- if and .Values.cluster.enabled (eq .Values.cluster.backupMode "cronjob") .Values.cluster.borgUiResync (or .Values.borgUI.enabled .Values.borgUI.agentConnection.server) -}}
true
{{- end -}}
{{- end -}}

{{/*
Borg UI connection env: server URL + admin credentials, WITHOUT BORG_UI_AGENT
(which would switch run.sh into agent mode). Shared by the agent workloads and
the cluster CronJob's resync step.
Usage: include "k8s-borg.env.borgui" (dict "context" $ "optional" true)
"optional" marks the password reference optional: the CronJob's resync is best
effort, so a missing password Secret must never keep the backup from starting.
*/}}
{{- define "k8s-borg.env.borgui" -}}
{{- $ctx := .context -}}
- name: BORG_UI_SERVER
  value: {{ include "k8s-borg.ui.serverUrl" $ctx | quote }}
# Preferred credential: the admin PAT minted by the reconcile Job (optional —
# absent before the first reconcile or for out-of-cluster agents, then the
# admin user/password below is the fallback).
- name: BORG_UI_ADMIN_PAT
  valueFrom:
    secretKeyRef:
      name: {{ include "k8s-borg.ui.patSecretName" $ctx }}
      key: BORG_UI_ADMIN_PAT
      optional: true
- name: BORG_UI_ADMIN_USER
  value: {{ $ctx.Values.borgUI.adminUser | quote }}
- name: BORG_UI_ADMIN_PASS
  valueFrom:
    secretKeyRef:
      name: {{ $ctx.Values.borgUI.adminPassword.existingSecret | default (include "k8s-borg.secretName" $ctx) }}
      key: {{ $ctx.Values.borgUI.adminPassword.existingSecretKey | default "BORG_UI_ADMIN_PASS" }}
      {{- if .optional }}
      optional: true
      {{- end }}
{{- end -}}

{{/*
Managed-agent enrollment env. Rendered per component when it runs as an agent
(node.backupMode=agent, cluster.backupMode=plan). Username is fixed to "admin"
server-side; the password matches the server's INITIAL_ADMIN_PASSWORD.
*/}}
{{- define "k8s-borg.env.agent" -}}
- name: BORG_UI_AGENT
  value: "true"
{{ include "k8s-borg.env.borgui" (dict "context" $) }}
- name: BORG_CHECK_SCHEDULE_DIR
  value: /etc/borg-check-schedules
- name: BORG_BACKUP_SCHEDULE_DIR
  value: /etc/borg-backup-schedules
- name: BORG_PLAN_RUN_PRUNE
  value: {{ .Values.borg.backupMaintenance.prune | quote }}
- name: BORG_PLAN_RUN_COMPACT
  value: {{ .Values.borg.backupMaintenance.compact | quote }}
- name: BORG_PLAN_RUN_CHECK
  value: {{ .Values.borg.backupMaintenance.check | quote }}
- name: BORG_PLAN_CHECK_MAX_DURATION
  value: {{ .Values.borg.backupMaintenance.checkMaxDuration | quote }}
- name: BORG_PLAN_CHECK_EXTRA_FLAGS
  value: {{ .Values.borg.backupMaintenance.checkExtraFlags | quote }}
{{- if .Values.borg.planCustomFlags }}
- name: BORG_PLAN_CUSTOM_FLAGS
  value: {{ .Values.borg.planCustomFlags | quote }}
{{- end }}
{{- end -}}

{{/*
PVC names (support existing claims).
*/}}
{{- define "k8s-borg.pvc.cache" -}}
{{- .Values.persistence.cache.existingClaim | default (printf "%s-cache" (include "common.names.fullname" .)) -}}
{{- end -}}
{{- define "k8s-borg.pvc.ui" -}}
{{- .Values.persistence.ui.existingClaim | default (printf "%s-ui" (include "common.names.fullname" .)) -}}
{{- end -}}
{{- define "k8s-borg.pvc.uiAgent" -}}
{{- .Values.persistence.uiAgent.existingClaim | default (printf "%s-ui-agent" (include "common.names.fullname" .)) -}}
{{- end -}}

{{/*
Volumes shared by all backup workloads (SSH, config, NFS source, cache, agent state).
*/}}
{{- define "k8s-borg.volumes.common" -}}
- name: ssh-credentials
  emptyDir:
    medium: Memory
- name: mounts
  emptyDir: {}
- name: ssh-secret
  secret:
    secretName: {{ include "k8s-borg.sshSecretName" . }}
    defaultMode: 384
- name: config
  configMap:
    name: {{ include "k8s-borg.configMapName" . }}
    defaultMode: 384
- name: cache
  persistentVolumeClaim:
    claimName: {{ include "k8s-borg.pvc.cache" . }}
- name: ui-agent
  persistentVolumeClaim:
    claimName: {{ include "k8s-borg.pvc.uiAgent" . }}
- name: check-schedules
  configMap:
    name: {{ include "k8s-borg.checkSchedulesConfigMapName" . }}
    optional: true
- name: backup-schedules
  configMap:
    name: {{ include "k8s-borg.backupSchedulesConfigMapName" . }}
    optional: true
{{- end -}}

{{/*
Volume mounts shared by all backup workloads. Requires NODE_NAME in the env.
*/}}
{{- define "k8s-borg.volumeMounts.common" -}}
- name: ssh-credentials
  mountPath: /root/.ssh
- name: mounts
  mountPath: /mnt
- name: config
  mountPath: /root/.borg
  readOnly: true
- name: cache
  mountPath: /root/.cache
  subPathExpr: $(NODE_NAME)
- name: ui-agent
  mountPath: /etc/borg-ui-agent
  subPathExpr: $(NODE_NAME)
- name: check-schedules
  mountPath: /etc/borg-check-schedules
  readOnly: true
- name: backup-schedules
  mountPath: /etc/borg-backup-schedules
  readOnly: true
{{- end -}}

{{/*
DB secret volumes (cluster/app workloads).
*/}}
{{/*
Truthy (non-empty) when any database instance uses secretRef, i.e. its
credentials are resolved from the database's namespace at pod start.
*/}}
{{- define "k8s-borg.dbResolverEnabled" -}}
{{- $found := false -}}
{{- range $engine := splitList " " (include "k8s-borg.databases.configured" .) | compact -}}
{{- range (index $.Values.databases $engine).instances }}{{- if .secretRef }}{{- $found = true }}{{- end }}{{- end -}}
{{- end -}}
{{- if $found }}true{{- end }}
{{- end -}}

{{/*
The database engines the chart can dump. Adding one takes its name here, its
section databases.<engine> in values.yaml, its Secret template, its line
format in the credentials resolver, and backup-<engine> /
backup-cluster-<engine> / restore-<engine> in the image. Everything that
decides whether an engine's dump runs, is published or is attached goes by
k8s-borg.databases.configured below.
*/}}
{{- define "k8s-borg.databases.supported" -}}
mariadb mysql postgres mongodb
{{- end -}}

{{/*
The engines this release configures, space-separated in the order above: an
engine is configured when databases.<engine>.enabled is true AND it has at
least one instance or an existingSecret. Only these get the credentials
volume, the agent script backup-cluster-<engine>, the plan's pre-backup hook
and a run in the cluster CronJob (BORG_DB_ENGINES). An enabled engine with
neither fails the render (k8s-borg.validateDatabases).
*/}}
{{- define "k8s-borg.databases.configured" -}}
{{- include "k8s-borg.validateDatabases" . -}}
{{- $engines := list -}}
{{- range $engine := splitList " " (include "k8s-borg.databases.supported" .) -}}
{{- $database := index $.Values.databases $engine | default dict -}}
{{- if and $database.enabled (or $database.existingSecret $database.instances) -}}
{{- $engines = append $engines $engine -}}
{{- end -}}
{{- end -}}
{{- join " " $engines -}}
{{- end -}}

{{/* Validate database instances before rendering volumes or credentials.
A MongoDB secretRef either names the key of a whole connection string (uriKey,
e.g. the Community operator's connectionString.standard) or, like the other
engines, a host with a password key and a user. */}}
{{- define "k8s-borg.validateDatabases" -}}
{{- range $engine := splitList " " (include "k8s-borg.databases.supported" .) -}}
{{- $database := index $.Values.databases $engine | default dict -}}
{{- if $database.enabled -}}
{{- if and (not $database.existingSecret) (empty $database.instances) -}}
{{- fail (printf "databases.%s.enabled is true, but the engine has no instances and no existingSecret: configure databases.%s.instances or databases.%s.existingSecret, or set databases.%s.enabled=false" $engine $engine $engine $engine) -}}
{{- end -}}
{{- range $index, $instance := $database.instances -}}
{{- $path := printf "databases.%s.instances[%d]" $engine $index -}}
{{- if not $instance.name -}}{{- fail (printf "%s.name is required" $path) -}}{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" $instance.name) -}}{{- fail (printf "%s.name must be a safe file name containing only letters, digits, '.', '_' or '-'" $path) -}}{{- end -}}
{{- if and $instance.config $instance.secretRef -}}{{- fail (printf "%s must define either config or secretRef, not both" $path) -}}{{- end -}}
{{- if and (not $instance.config) (not $instance.secretRef) (not $database.existingSecret) -}}{{- fail (printf "%s must define either config or secretRef" $path) -}}{{- end -}}
{{- if $instance.secretRef -}}
{{- if not $instance.secretRef.namespace -}}{{- fail (printf "%s.secretRef.namespace is required" $path) -}}{{- end -}}
{{- if not $instance.secretRef.name -}}{{- fail (printf "%s.secretRef.name is required" $path) -}}{{- end -}}
{{- if and (eq $engine "mongodb") $instance.secretRef.uriKey -}}
{{- if or $instance.host $instance.port $instance.user $instance.options $instance.secretRef.usernameKey $instance.secretRef.passwordKey -}}{{- fail (printf "%s: secretRef.uriKey is the whole connection string; host, port, options, user, usernameKey and passwordKey go without it" $path) -}}{{- end -}}
{{- else -}}
{{- if not $instance.host -}}{{- fail (printf "%s.host is required with secretRef%s" $path (ternary " (or secretRef.uriKey)" "" (eq $engine "mongodb"))) -}}{{- end -}}
{{- if eq $engine "mongodb" -}}
{{- /* host, port and options go into the URI as they are: nothing in them may change where it splits */ -}}
{{- if not (regexMatch "^([A-Za-z0-9.-]+|\\[[0-9A-Fa-f:.]+\\])$" (toString $instance.host)) -}}{{- fail (printf "%s.host must be one host name or IP address (an IPv6 address in brackets); a seed list goes into secretRef.uriKey or a static config" $path) -}}{{- end -}}
{{- if and (hasKey $instance "port") (not (regexMatch "^([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$" (toString $instance.port))) -}}{{- fail (printf "%s.port must be a port number (1-65535)" $path) -}}{{- end -}}
{{- if and $instance.options (regexMatch "^[?&]|[#[:space:]]" (toString $instance.options)) -}}{{- fail (printf "%s.options is the URI's query (name=value&…, special characters in a value percent-encoded): no leading '?' or '&', no '#' or whitespace" $path) -}}{{- end -}}
{{- end -}}
{{- if not $instance.secretRef.passwordKey -}}{{- fail (printf "%s.secretRef.passwordKey is required" $path) -}}{{- end -}}
{{- if eq (empty $instance.user) (empty $instance.secretRef.usernameKey) -}}{{- fail (printf "%s must define exactly one of user or secretRef.usernameKey" $path) -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Truthy when static *.conf content exists for the engine (existingSecret or at
least one instance with inline config) — the secret volume is then still
mounted (staged for the resolver in secretRef mode).
*/}}
{{- define "k8s-borg.databases.staticConf" -}}
{{- $database := index .context.Values.databases .engine -}}
{{- if $database.existingSecret }}true{{- else }}{{- range $database.instances }}{{- if .config }}true{{- end }}{{- end }}{{- end }}
{{- end -}}

{{- define "k8s-borg.dbResolverSAName" -}}
{{- printf "%s-db-resolver" (include "common.names.fullname" .) -}}
{{- end -}}

{{- define "k8s-borg.volumes.db" -}}
{{- $resolver := include "k8s-borg.dbResolverEnabled" . -}}
{{- range $engine := splitList " " (include "k8s-borg.databases.configured" .) | compact }}
{{- if $resolver }}
- name: {{ $engine }}-conf
  emptyDir:
    medium: Memory
{{- end }}
{{- if or (not $resolver) (include "k8s-borg.databases.staticConf" (dict "context" $ "engine" $engine)) }}
- name: {{ $engine }}-secret
  secret:
    secretName: {{ include "k8s-borg.databases.secretName" (dict "context" $ "engine" $engine) }}
    defaultMode: 384
{{- end }}
{{- end }}
{{- end -}}

{{- define "k8s-borg.volumeMounts.db" -}}
{{- $resolver := include "k8s-borg.dbResolverEnabled" . -}}
{{- range $engine := splitList " " (include "k8s-borg.databases.configured" .) | compact }}
- name: {{ $engine }}-{{ ternary "conf" "secret" (not (empty $resolver)) }}
  mountPath: /root/.{{ $engine }}
  readOnly: true
{{- end }}
{{- end -}}

{{/*
Init container that builds the /root/.<engine> *.conf files (mariadb, mysql,
postgres, mongodb): copies static confs from the chart/existing Secret (if any)
and resolves secretRef instances by reading the referenced Secret from its
namespace via the API (needs the get-only ClusterRole from
db-credentials-rbac.yaml). Passwords are escaped for the target format
(pgpass ':'/'\', MySQL '"'/'\').
A MongoDB file is the YAML mongodump/mongorestore read with --config: the
connection string from uriKey as is, or one built from host, port, options and
the user (percent-encoded), the password in a field of its own; every value a
single-quoted YAML scalar.
An instance with `tls: false` gets its client's option for no TLS: `skip-ssl`
for MariaDB, whose client asks for TLS by default, which a server without a
certificate refuses; `ssl-mode=DISABLED` for MySQL, together with
`get-server-public-key`, without which a caching_sha2_password user cannot log
in over a connection without TLS.
*/}}
{{- define "k8s-borg.dbResolverInitContainer" -}}
{{- if (include "k8s-borg.dbResolverEnabled" .) }}
- name: resolve-db-credentials
  image: {{ .Values.databases.credentialsResolver.image.repository }}:{{ .Values.databases.credentialsResolver.image.tag }}
  imagePullPolicy: {{ .Values.databases.credentialsResolver.image.pullPolicy }}
  # Secret volumes are 0600 root:root and the generated files must retain that
  # mode, so this narrowly scoped init container has to run as root.
  securityContext:
    runAsUser: 0
    runAsGroup: 0
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]
  command:
    - /bin/bash
    - -c
    - |
      set -euo pipefail
      # A '.' in a key (connectionString.standard) is escaped for jsonpath.
      get_key() { kubectl get secret -n "$1" "$2" -o "jsonpath={.data.${3//./\\.}}" | base64 -d; }
      pg() { # ns secret userKey passKey host port user name
        local u p
        if [ -n "$3" ]; then u=$(get_key "$1" "$2" "$3"); else u=$7; fi
        p=$(get_key "$1" "$2" "$4"); p=${p//\\/\\\\}; p=${p//:/\\:}
        printf '%s:%s:*:%s:%s\n' "$5" "$6" "$u" "$p" > "/out/postgres/$8.conf"
        chmod 600 "/out/postgres/$8.conf"
      }
      my() { # engine ns secret userKey passKey host port user name extraOptions
        local u p f="/out/$1/$9.conf"
        if [ -n "$4" ]; then u=$(get_key "$2" "$3" "$4"); else u=$8; fi
        p=$(get_key "$2" "$3" "$5"); p=${p//\\/\\\\}; p=${p//\"/\\\"}
        printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\n' "$6" "$7" "$u" "$p" > "$f"
        # extraOptions unquoted on purpose: one option per line.
        if [ -n "${10}" ]; then printf '%s\n' ${10} >> "$f"; fi
        chmod 600 "$f"
      }
      yq1() { local v=${1//\'/\'\'}; printf "'%s'" "$v"; } # a single-quoted YAML scalar
      urlenc() { # percent-encode all but RFC 3986 unreserved characters, byte by byte
        local LC_ALL=C s=$1 out="" c i
        for ((i = 0; i < ${#s}; i++)); do
          c=${s:i:1}
          case "$c" in
            [A-Za-z0-9._~-]) out+=$c ;;
            *) printf -v c '%%%02X' "'$c"; out+=$c ;;
          esac
        done
        printf '%s' "$out"
      }
      mo() { # ns secret uriKey userKey passKey host port user options name
        local u p uri f="/out/mongodb/${10}.conf"
        if [ -n "$3" ]; then
          uri=$(get_key "$1" "$2" "$3")
          [ -n "$uri" ] || { echo "secret $1/$2 has no $3" >&2; return 1; }
          printf 'uri: %s\n' "$(yq1 "$uri")" > "$f"
        else
          if [ -n "$4" ]; then u=$(get_key "$1" "$2" "$4"); else u=$8; fi
          p=$(get_key "$1" "$2" "$5")
          [ -n "$u" ] && [ -n "$p" ] || { echo "secret $1/$2 has no user or password" >&2; return 1; }
          uri="mongodb://$(urlenc "$u")@$6:$7/?$9"
          printf 'uri: %s\npassword: %s\n' "$(yq1 "$uri")" "$(yq1 "$p")" > "$f"
        fi
        chmod 600 "$f"
      }
      for d in /static/mariadb /static/mysql /static/postgres /static/mongodb; do
        [ -d "$d" ] || continue
        for f in "$d"/*.conf; do
          [ -e "$f" ] || continue
          cp "$f" "/out/${d##*/}/"; chmod 600 "/out/${d##*/}/${f##*/}"
        done
      done
      {{- $engines := splitList " " (include "k8s-borg.databases.configured" .) }}
      {{- range $engine, $noTls := dict "mariadb" "skip-ssl" "mysql" "ssl-mode=DISABLED get-server-public-key" }}
      {{- if has $engine $engines }}
      {{- range (index $.Values.databases $engine).instances }}
      {{- if .secretRef }}
      my {{ $engine }} {{ .secretRef.namespace | quote }} {{ .secretRef.name | quote }} {{ .secretRef.usernameKey | default "" | quote }} {{ .secretRef.passwordKey | quote }} {{ .host | quote }} {{ .port | default 3306 | quote }} {{ .user | default "" | quote }} {{ .name | quote }} {{ ternary $noTls "" (and (hasKey . "tls") (not .tls)) | quote }}
      {{- end }}
      {{- end }}
      {{- end }}
      {{- end }}
      {{- if has "postgres" $engines }}
      {{- range .Values.databases.postgres.instances }}
      {{- if .secretRef }}
      pg {{ .secretRef.namespace | quote }} {{ .secretRef.name | quote }} {{ .secretRef.usernameKey | default "" | quote }} {{ .secretRef.passwordKey | quote }} {{ .host | quote }} {{ .port | default 5432 | quote }} {{ .user | default "" | quote }} {{ .name | quote }}
      {{- end }}
      {{- end }}
      {{- end }}
      {{- if has "mongodb" $engines }}
      {{- range .Values.databases.mongodb.instances }}
      {{- if .secretRef }}
      mo {{ .secretRef.namespace | quote }} {{ .secretRef.name | quote }} {{ .secretRef.uriKey | default "" | quote }} {{ .secretRef.usernameKey | default "" | quote }} {{ .secretRef.passwordKey | default "" | quote }} {{ .host | default "" | quote }} {{ .port | default 27017 | quote }} {{ .user | default "" | quote }} {{ .options | default "authSource=admin" | quote }} {{ .name | quote }}
      {{- end }}
      {{- end }}
      {{- end }}
      echo "db credentials resolved"
  volumeMounts:
    {{- range $engine := splitList " " (include "k8s-borg.databases.configured" .) | compact }}
    - name: {{ $engine }}-conf
      mountPath: /out/{{ $engine }}
    {{- if (include "k8s-borg.databases.staticConf" (dict "context" $ "engine" $engine)) }}
    - name: {{ $engine }}-secret
      mountPath: /static/{{ $engine }}
      readOnly: true
    {{- end }}
    {{- end }}
{{- end }}
{{- end -}}

{{/*
Repository server (repoServer.enabled).
*/}}
{{- define "k8s-borg.repoServer.fullname" -}}
{{- printf "%s-repo-server" (include "common.names.fullname" .) -}}
{{- end -}}

{{- define "k8s-borg.repoServer.claimName" -}}
{{- .Values.repoServer.persistence.existingClaim | default (printf "%s-data" (include "k8s-borg.repoServer.fullname" .)) -}}
{{- end -}}

{{/* Where the pod keeps its data and its scratch files. Fixed: they are part of
the account the chart renders into /etc/passwd. */}}
{{- define "k8s-borg.repoServer.dataDir" -}}/repos{{- end -}}
{{- define "k8s-borg.repoServer.runDir" -}}/run/borg-repo-server{{- end -}}

{{/*
Fail fast on a repository server that could not start, or that would grant more
than intended. The pod checks the same things again at start, and then also
what the chart cannot see: the content of an existing Secret. Here they fail
the install instead of a pod.
*/}}
{{- define "k8s-borg.repoServer.validate" -}}
{{- $rs := .Values.repoServer -}}
{{- if $rs.enabled -}}
{{- $permissionModes := list "all" "no-delete" "write-only" "read-only" -}}
{{- if not .Values.ssh.existingSecret -}}
{{- if not .Values.ssh.hostKey -}}
{{- fail "repoServer.enabled requires a host key: set ssh.hostKey, or use ssh.existingSecret with a key ssh_host_ed25519_key in it (create one with: ssh-keygen -t ed25519 -N \"\" -C \"\" -f ssh_host_ed25519_key)" -}}
{{- end -}}
{{- if not (trim (toString .Values.ssh.authorizedKeys)) -}}
{{- fail "repoServer.enabled requires the clients' public keys: set ssh.authorizedKeys, or use ssh.existingSecret with a key authorized_keys in it" -}}
{{- end -}}
{{- range $i, $line := splitList "\n" (toString .Values.ssh.authorizedKeys) -}}
{{- $line = trim $line -}}
{{- if and $line (not (hasPrefix "#" $line)) -}}
{{- if not (regexMatch "^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\\.com|sk-ecdsa-sha2-nistp256@openssh\\.com) [A-Za-z0-9+/]+=* [A-Za-z0-9][A-Za-z0-9._-]*( .*)?$" $line) -}}
{{- fail (printf "ssh.authorizedKeys line %d must be \"<type> <key> <name>\": no options, and a comment that names the client (letters, digits, \".\", \"_\", \"-\")" (add $i 1)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if lt (int $rs.port) 1024 -}}
{{- fail (printf "repoServer.port must be 1024 or higher, sshd runs as an unprivileged user (got %v)" $rs.port) -}}
{{- end -}}
{{- if or (lt (int $rs.runAsUser) 1) (lt (int $rs.runAsGroup) 1) -}}
{{- fail (printf "repoServer.runAsUser and repoServer.runAsGroup must be 1 or higher, the server does not run as root (got %v:%v)" $rs.runAsUser $rs.runAsGroup) -}}
{{- end -}}
{{- if not (has (toString $rs.defaultPermissions) $permissionModes) -}}
{{- fail (printf "repoServer.defaultPermissions must be \"all\", \"no-delete\", \"write-only\" or \"read-only\" (got %q)" (toString $rs.defaultPermissions)) -}}
{{- end -}}
{{- if not (has $rs.service.type (list "ClusterIP" "NodePort" "LoadBalancer")) -}}
{{- fail (printf "repoServer.service.type must be \"ClusterIP\", \"NodePort\" or \"LoadBalancer\" (got %q)" $rs.service.type) -}}
{{- end -}}
{{- if not (has $rs.service.externalTrafficPolicy (list "Cluster" "Local")) -}}
{{- fail (printf "repoServer.service.externalTrafficPolicy must be \"Cluster\" or \"Local\" (got %q)" $rs.service.externalTrafficPolicy) -}}
{{- end -}}
{{- $p := $rs.persistence -}}
{{- if and $p.local.createPV (not $p.existingClaim) -}}
{{- if not $p.local.nodeName -}}
{{- fail "repoServer.persistence.local.createPV requires repoServer.persistence.local.nodeName" -}}
{{- end -}}
{{- if not (hasPrefix "/" (toString $p.local.path)) -}}
{{- fail (printf "repoServer.persistence.local.path must be an absolute path on the node (got %q)" (toString $p.local.path)) -}}
{{- end -}}
{{- end -}}
{{- $names := dict -}}
{{- range $i, $c := $rs.clients -}}
{{- $at := printf "repoServer.clients[%d]" $i -}}
{{- $name := toString ($c.name | default "") -}}
{{- if not $name -}}
{{- fail (printf "%s.name is required" $at) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]*$" $name) -}}
{{- fail (printf "%s.name must start with a letter or digit and consist of letters, digits, \".\", \"_\" and \"-\" (got %q)" $at $name) -}}
{{- end -}}
{{- if hasKey $names $name -}}
{{- fail (printf "%s.name %q is used twice" $at $name) -}}
{{- end -}}
{{- $_ := set $names $name true -}}
{{- $path := toString ($c.path | default $name) -}}
{{- if hasPrefix "/" $path -}}
{{- fail (printf "%s.path must be relative to the data directory, without a leading \"/\" (got %q)" $at $path) -}}
{{- end -}}
{{- if has ".." (splitList "/" $path) -}}
{{- fail (printf "%s.path must not contain \"..\" (got %q)" $at $path) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*$" $path) -}}
{{- fail (printf "%s.path must be made of letters, digits, \".\", \"_\", \"-\" and \"/\", every segment starting with a letter, digit or \"_\" (got %q)" $at $path) -}}
{{- end -}}
{{- $permissions := toString ($c.permissions | default $rs.defaultPermissions) -}}
{{- if not (has $permissions $permissionModes) -}}
{{- fail (printf "%s.permissions must be \"all\", \"no-delete\", \"write-only\" or \"read-only\" (got %q)" $at $permissions) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
