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

{{/*
Per-component standard labels. Usage: include "k8s-borg.labels" (dict "context" $ "component" "node")
*/}}
{{- define "k8s-borg.labels" -}}
{{- include "common.labels.standard" (dict "customLabels" (dict "app.kubernetes.io/component" .component) "context" .context) -}}
{{- end -}}

{{- define "k8s-borg.matchLabels" -}}
{{- include "common.labels.matchLabels" (dict "customLabels" (dict "app.kubernetes.io/component" .component) "context" .context) -}}
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
Borg UI in-cluster Service URL (used for agent enrollment and the bootstrap Job).
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
Whether any backup workload enrols at Borg UI as a managed agent — the console/app
pod (app.mode=agent) or the DaemonSet (node.backupMode=agent). Gates the schedule
ConfigMaps and the enrollment admin credentials. Emits "true" or "".
*/}}
{{- define "k8s-borg.anyAgent" -}}
{{- if or (and .Values.app.enabled (eq .Values.app.mode "agent")) (and .Values.node.enabled (eq .Values.node.backupMode "agent")) -}}
true
{{- end -}}
{{- end -}}

{{/*
Names for the bootstrap Job's PAT Secret, ServiceAccount and Role.
*/}}
{{- define "k8s-borg.ui.patSecretName" -}}
{{- printf "%s-ui-pat" (include "common.names.fullname" .) -}}
{{- end -}}
{{- define "k8s-borg.bootstrapSAName" -}}
{{- printf "%s-bootstrap" (include "common.names.fullname" .) -}}
{{- end -}}

{{/*
Where the SSH key is staged for the Borg UI server to import as its system key.
*/}}
{{- define "k8s-borg.ui.sshKeyDir" -}}/etc/borg-ui-ssh{{- end -}}

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
server (and its bootstrap Job) that isn't up yet. Uses the agent image (has curl).
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
- name: BORG_PASSPHRASE
  valueFrom:
    secretKeyRef:
      name: {{ .Values.borg.passphrase.existingSecret | default (include "k8s-borg.secretName" .) }}
      key: {{ .Values.borg.passphrase.existingSecretKey | default "BORG_PASSPHRASE" }}
- name: BORGBACKUP_ARCHIVE_PREFIX
  value: {{ .Values.borg.archivePrefix | quote }}
- name: BORG_ARCHIVE_GLOB
  value: {{ .Values.borg.archiveGlob | quote }}
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
# Preferred credential: the admin PAT minted by the server bootstrap (optional —
# absent before the first bootstrap or for out-of-cluster agents, then run-agent.sh
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
{{- define "k8s-borg.volumes.db" -}}
{{- if .Values.databases.mariadb.enabled }}
- name: mariadb-secret
  secret:
    secretName: {{ include "k8s-borg.mariadbSecretName" . }}
    defaultMode: 384
{{- end }}
{{- if .Values.databases.postgres.enabled }}
- name: postgres-secret
  secret:
    secretName: {{ include "k8s-borg.postgresSecretName" . }}
    defaultMode: 384
{{- end }}
{{- end -}}

{{- define "k8s-borg.volumeMounts.db" -}}
{{- if .Values.databases.mariadb.enabled }}
- name: mariadb-secret
  mountPath: /root/.mariadb
  readOnly: true
{{- end }}
{{- if .Values.databases.postgres.enabled }}
- name: postgres-secret
  mountPath: /root/.postgres
  readOnly: true
{{- end }}
{{- end -}}
