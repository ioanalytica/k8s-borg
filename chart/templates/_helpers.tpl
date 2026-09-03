{{- /*
Copyright IO ANALYTICA. All Rights Reserved.
SPDX-License-Identifier: Apache-2.0
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

{{- define "k8s-borg.mariadbSecretName" -}}
{{- .Values.databases.mariadb.existingSecret | default (printf "%s-mariadb" (include "common.names.fullname" .)) -}}
{{- end -}}

{{- define "k8s-borg.postgresSecretName" -}}
{{- .Values.databases.postgres.existingSecret | default (printf "%s-postgres" (include "common.names.fullname" .)) -}}
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
{{- if .Values.databases.mariadb.enabled -}}
{{- $scripts = merge $scripts (dict "backup-cluster-mariadb" (include "k8s-borg.defaultDbDumpScript" (dict "engine" "mariadb"))) -}}
{{- end -}}
{{- if .Values.databases.postgres.enabled -}}
{{- $scripts = merge $scripts (dict "backup-cluster-postgres" (include "k8s-borg.defaultDbDumpScript" (dict "engine" "postgres"))) -}}
{{- end -}}
{{- toYaml $scripts -}}
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
is healthy and fully reconciled). Needs the agent ServiceAccount's RBAC (get on
that one ConfigMap). Uses the agent image (curl + python3).
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
      while :; do
        val=$(curl -sS --cacert "$SA/ca.crt" -H "Authorization: Bearer $(cat "$SA/token")" \
                "https://kubernetes.default.svc/api/v1/namespaces/${ns}/configmaps/${RECONCILE_STATUS_CONFIGMAP}" 2>/dev/null \
              | python3 -c 'import sys,json; print(json.load(sys.stdin).get("data",{}).get("reconciled",""))' 2>/dev/null || true)
        [ "$val" = "${RECONCILE_TOKEN}" ] && break
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
- name: S3_MOUNTPOINT
  value: {{ .Values.s3.mountPath | quote }}
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
Managed-agent enrollment env. Rendered per component when it runs as an agent
(node.backupMode=agent, cluster.backupMode=plan). Username is fixed to "admin"
server-side; the password matches the server's INITIAL_ADMIN_PASSWORD.
*/}}
{{- define "k8s-borg.env.agent" -}}
- name: BORG_UI_AGENT
  value: "true"
- name: BORG_UI_SERVER
  value: {{ include "k8s-borg.ui.serverUrl" . | quote }}
# Preferred credential: the admin PAT minted by the reconcile Job (optional —
# absent before the first reconcile or for out-of-cluster agents, then run-agent.sh
# falls back to the admin user/password below).
- name: BORG_UI_ADMIN_PAT
  valueFrom:
    secretKeyRef:
      name: {{ include "k8s-borg.ui.patSecretName" . }}
      key: BORG_UI_ADMIN_PAT
      optional: true
- name: BORG_UI_ADMIN_USER
  value: {{ .Values.borgUI.adminUser | quote }}
- name: BORG_UI_ADMIN_PASS
  valueFrom:
    secretKeyRef:
      name: {{ .Values.borgUI.adminPassword.existingSecret | default (include "k8s-borg.secretName" .) }}
      key: {{ .Values.borgUI.adminPassword.existingSecretKey | default "BORG_UI_ADMIN_PASS" }}
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
{{- if .Values.databases.mariadb.enabled }}{{- range .Values.databases.mariadb.instances }}{{- if .secretRef }}{{- $found = true }}{{- end }}{{- end }}{{- end }}
{{- if .Values.databases.postgres.enabled }}{{- range .Values.databases.postgres.instances }}{{- if .secretRef }}{{- $found = true }}{{- end }}{{- end }}{{- end }}
{{- if $found }}true{{- end }}
{{- end -}}

{{/* Validate database instances before rendering volumes or credentials. */}}
{{- define "k8s-borg.validateDatabases" -}}
{{- range $engine := list "mariadb" "postgres" -}}
{{- $database := index $.Values.databases $engine -}}
{{- if $database.enabled -}}
{{- if and (not $database.existingSecret) (empty $database.instances) -}}
{{- fail (printf "databases.%s.instances must contain at least one instance when enabled without existingSecret" $engine) -}}
{{- end -}}
{{- range $index, $instance := $database.instances -}}
{{- $path := printf "databases.%s.instances[%d]" $engine $index -}}
{{- if not $instance.name -}}{{- fail (printf "%s.name is required" $path) -}}{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" $instance.name) -}}{{- fail (printf "%s.name must be a safe file name containing only letters, digits, '.', '_' or '-'" $path) -}}{{- end -}}
{{- if and $instance.config $instance.secretRef -}}{{- fail (printf "%s must define either config or secretRef, not both" $path) -}}{{- end -}}
{{- if and (not $instance.config) (not $instance.secretRef) (not $database.existingSecret) -}}{{- fail (printf "%s must define either config or secretRef" $path) -}}{{- end -}}
{{- if $instance.secretRef -}}
{{- if not $instance.host -}}{{- fail (printf "%s.host is required with secretRef" $path) -}}{{- end -}}
{{- if not $instance.secretRef.namespace -}}{{- fail (printf "%s.secretRef.namespace is required" $path) -}}{{- end -}}
{{- if not $instance.secretRef.name -}}{{- fail (printf "%s.secretRef.name is required" $path) -}}{{- end -}}
{{- if not $instance.secretRef.passwordKey -}}{{- fail (printf "%s.secretRef.passwordKey is required" $path) -}}{{- end -}}
{{- if eq (empty $instance.user) (empty $instance.secretRef.usernameKey) -}}{{- fail (printf "%s must define exactly one of user or secretRef.usernameKey" $path) -}}{{- end -}}
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
{{- define "k8s-borg.mariadbStaticConf" -}}
{{- if .Values.databases.mariadb.existingSecret }}true{{- else }}{{- range .Values.databases.mariadb.instances }}{{- if .config }}true{{- end }}{{- end }}{{- end }}
{{- end -}}

{{- define "k8s-borg.postgresStaticConf" -}}
{{- if .Values.databases.postgres.existingSecret }}true{{- else }}{{- range .Values.databases.postgres.instances }}{{- if .config }}true{{- end }}{{- end }}{{- end }}
{{- end -}}

{{- define "k8s-borg.dbResolverSAName" -}}
{{- printf "%s-db-resolver" (include "common.names.fullname" .) -}}
{{- end -}}

{{- define "k8s-borg.volumes.db" -}}
{{- include "k8s-borg.validateDatabases" . -}}
{{- $resolver := include "k8s-borg.dbResolverEnabled" . -}}
{{- if .Values.databases.mariadb.enabled }}
{{- if $resolver }}
- name: mariadb-conf
  emptyDir:
    medium: Memory
{{- end }}
{{- if or (not $resolver) (include "k8s-borg.mariadbStaticConf" .) }}
- name: mariadb-secret
  secret:
    secretName: {{ include "k8s-borg.mariadbSecretName" . }}
    defaultMode: 384
{{- end }}
{{- end }}
{{- if .Values.databases.postgres.enabled }}
{{- if $resolver }}
- name: postgres-conf
  emptyDir:
    medium: Memory
{{- end }}
{{- if or (not $resolver) (include "k8s-borg.postgresStaticConf" .) }}
- name: postgres-secret
  secret:
    secretName: {{ include "k8s-borg.postgresSecretName" . }}
    defaultMode: 384
{{- end }}
{{- end }}
{{- end -}}

{{- define "k8s-borg.volumeMounts.db" -}}
{{- $resolver := include "k8s-borg.dbResolverEnabled" . -}}
{{- if .Values.databases.mariadb.enabled }}
- name: {{ ternary "mariadb-conf" "mariadb-secret" (not (empty $resolver)) }}
  mountPath: /root/.mariadb
  readOnly: true
{{- end }}
{{- if .Values.databases.postgres.enabled }}
- name: {{ ternary "postgres-conf" "postgres-secret" (not (empty $resolver)) }}
  mountPath: /root/.postgres
  readOnly: true
{{- end }}
{{- end -}}

{{/*
Init container that builds /root/.mariadb and /root/.postgres *.conf files:
copies static confs from the chart/existing Secret (if any) and resolves
secretRef instances by reading the referenced Secret from its namespace via
the API (needs the get-only ClusterRole from db-credentials-rbac.yaml).
Passwords are escaped for the target format (pgpass ':'/'\', MySQL '"'/'\').
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
      get_key() { kubectl get secret -n "$1" "$2" -o "jsonpath={.data.$3}" | base64 -d; }
      pg() { # ns secret userKey passKey host port user name
        local u p
        if [ -n "$3" ]; then u=$(get_key "$1" "$2" "$3"); else u=$7; fi
        p=$(get_key "$1" "$2" "$4"); p=${p//\\/\\\\}; p=${p//:/\\:}
        printf '%s:%s:*:%s:%s\n' "$5" "$6" "$u" "$p" > "/out/postgres/$8.conf"
        chmod 600 "/out/postgres/$8.conf"
      }
      my() { # ns secret userKey passKey host port user name
        local u p
        if [ -n "$3" ]; then u=$(get_key "$1" "$2" "$3"); else u=$7; fi
        p=$(get_key "$1" "$2" "$4"); p=${p//\\/\\\\}; p=${p//\"/\\\"}
        printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\n' "$5" "$6" "$u" "$p" > "/out/mariadb/$8.conf"
        chmod 600 "/out/mariadb/$8.conf"
      }
      for d in /static/mariadb /static/postgres; do
        [ -d "$d" ] || continue
        for f in "$d"/*.conf; do
          [ -e "$f" ] || continue
          cp "$f" "/out/${d##*/}/"; chmod 600 "/out/${d##*/}/${f##*/}"
        done
      done
      {{- range .Values.databases.mariadb.instances }}
      {{- if .secretRef }}
      my {{ .secretRef.namespace | quote }} {{ .secretRef.name | quote }} {{ .secretRef.usernameKey | default "" | quote }} {{ .secretRef.passwordKey | quote }} {{ .host | quote }} {{ .port | default 3306 | quote }} {{ .user | default "" | quote }} {{ .name | quote }}
      {{- end }}
      {{- end }}
      {{- range .Values.databases.postgres.instances }}
      {{- if .secretRef }}
      pg {{ .secretRef.namespace | quote }} {{ .secretRef.name | quote }} {{ .secretRef.usernameKey | default "" | quote }} {{ .secretRef.passwordKey | quote }} {{ .host | quote }} {{ .port | default 5432 | quote }} {{ .user | default "" | quote }} {{ .name | quote }}
      {{- end }}
      {{- end }}
      echo "db credentials resolved"
  volumeMounts:
    {{- if .Values.databases.mariadb.enabled }}
    - name: mariadb-conf
      mountPath: /out/mariadb
    {{- if (include "k8s-borg.mariadbStaticConf" .) }}
    - name: mariadb-secret
      mountPath: /static/mariadb
      readOnly: true
    {{- end }}
    {{- end }}
    {{- if .Values.databases.postgres.enabled }}
    - name: postgres-conf
      mountPath: /out/postgres
    {{- if (include "k8s-borg.postgresStaticConf" .) }}
    - name: postgres-secret
      mountPath: /static/postgres
      readOnly: true
    {{- end }}
    {{- end }}
{{- end }}
{{- end -}}
