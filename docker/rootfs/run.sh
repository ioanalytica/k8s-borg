#!/usr/bin/env bash
#
# Container entrypoint: validate the environment, set up mounts, then either
# hand over to the Borg UI managed agent (BORG_UI_AGENT=true) or run the legacy
# backup flow ("run" = backup, anything else = inspection).
#
set -euo pipefail

die() { echo "FATAL: $*" >&2; exit 1; }

require_env() {
  local var
  for var in "$@"; do
    [[ -n "${!var:-}" ]] || die "environment variable ${var} must be set via mounted secret"
    echo "  ${var} - ok"
  done
}

require_file() {
  local f
  for f in "$@"; do
    [[ -f $f ]] || die "file ${f} must be mapped into the pod"
    echo "  ${f} - ok"
  done
}

S3_BUCKETS="/root/.borg/cluster-s3-buckets"
BORG_MODE="${BORG_MODE:-cluster}"
# Normalize the S3 toggle (chart sets S3_ENABLED=true|false; default off).
S3_ENABLED="$(printf %s "${S3_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')"
# S3 sources are cluster/app scope only — never mounted on node backups. This one
# flag drives every S3 step below (validate, mkdir, mount).
s3_active=false
[[ "${S3_ENABLED}" = "true" && "${BORG_MODE}" != "node" ]] && s3_active=true

echo "Checking environment for required settings …"
require_env BORG_VERSION \
            BORG_REPO \
            NODE_NAME \
            BORG_PASSPHRASE \
            BORGBACKUP_ARCHIVE_PREFIX \
            BORG_ARCHIVE_GLOB \
            DB_BACKUP_LOCATION
if [[ "${s3_active}" = "true" ]]; then
  require_env S3_ENDPOINT S3_MOUNTPOINT AWS_KEY AWS_SECRET_KEY
fi

echo "Checking for required config files …"
require_file /root/.borg/cluster-exclude.patterns /root/.borg/cluster-include.patterns \
             /root/.borg/node-exclude.patterns /root/.borg/node-include.patterns
[[ "${s3_active}" = "true" ]] && require_file "${S3_BUCKETS}"

echo "Checking for required ssh files …"
require_file /root/.ssh/id_ed25519 /root/.ssh/id_ed25519.pub /root/.ssh/known_hosts

echo "Creating mount point /mnt/borg …"
mkdir -p /mnt/borg
[[ "${s3_active}" = "true" ]] && mkdir -p "${S3_MOUNTPOINT}"

# Mount S3 buckets as read sources — app/cluster jobs only, never on node backups.
if [[ "${s3_active}" = "true" && -f "${S3_BUCKETS}" ]]; then
  echo "Mounting S3 buckets listed in ${S3_BUCKETS} …"
  install -m 600 /dev/null /root/.s3fs
  printf '%s:%s\n' "${AWS_KEY}" "${AWS_SECRET_KEY}" > /root/.s3fs
  while read -r bucket || [[ -n "${bucket}" ]]; do
    [[ -n "${bucket}" ]] || continue
    echo "  mounting ${bucket} …"
    mkdir -p "${S3_MOUNTPOINT}/${bucket}"
    s3fs "${bucket}" "${S3_MOUNTPOINT}/${bucket}" \
      -o "passwd_file=/root/.s3fs,use_path_request_style,url=${S3_ENDPOINT}"
  done < "${S3_BUCKETS}"
fi

echo "Configuration successfully completed."

echo "Checking BORG_REPO and creating it if necessary."
borg-init >/dev/null

# --- Managed-agent mode: enroll (once) and run the agent ---------------------
if [[ "${BORG_UI_AGENT:-}" = "true" ]]; then
  exec /run-agent.sh
fi

# --- Legacy backup mode ------------------------------------------------------
if [[ "${1:-}" != "run" ]]; then
  echo "Running inspection mode …"
  exec tail -F /var/log/borg-backup.log
fi

# Database dumps before the filesystem backup — cluster/app scope only. Node
# backups capture the node filesystem, not logical DB dumps.
if [[ "${BORG_MODE}" = "node" ]]; then
  echo "Running borg-backup for node ${NODE_NAME} …"
else
  shopt -s nullglob
  backup-cluster-mariadb
  backup-cluster-postgres
  echo "Running borg-backup for cluster …"
fi
exec borg-backup
