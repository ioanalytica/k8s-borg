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
Borg UI in-cluster Service URL (used for agent enrollment). Derived from the
release unless borgUI.agent.server overrides it.
*/}}
{{- define "k8s-borg.ui.serverUrl" -}}
{{- if .Values.borgUI.agent.server -}}
{{- .Values.borgUI.agent.server -}}
{{- else -}}
{{- printf "http://%s-ui.%s.svc.cluster.local:%v" (include "common.names.fullname" .) .Release.Namespace .Values.borgUI.service.port -}}
{{- end -}}
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
Managed-agent enrollment env (DEV/TEST). Rendered only when borgUI.agent.enabled.
Username is fixed to "admin" server-side; the password matches the server's
INITIAL_ADMIN_PASSWORD.
*/}}
{{- define "k8s-borg.env.agent" -}}
- name: BORG_UI_AGENT
  value: "true"
- name: BORG_UI_SERVER
  value: {{ include "k8s-borg.ui.serverUrl" . | quote }}
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
