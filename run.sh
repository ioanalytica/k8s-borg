#!/bin/bash

set -e

S3_BUCKETS="/root/.borg/cluster-s3-buckets"

ENVVARS=(
  "S3_ENDPOINT"
  "S3_MOUNTPOINT"
  "AWS_KEY"
  "AWS_SECRET_KEY"
  "BORG_REPO_BASE"
  "NODE_NAME"
  "BORG_PASSPHRASE"
  "BORGBACKUP_ARCHIVE_PREFIX"
  "BORG_ARCHIVE_GLOB"
)

FILEVARS=(
  "/root/.borg/cluster-exclude.patterns"
  "/root/.borg/cluster-include.patterns"
  "/root/.borg/node-exclude.patterns"
  "/root/.borg/node-include.patterns"
  "${S3_BUCKETS}"
)

SSHFILES=(
  "/root/.ssh/id_ed25519"
  "/root/.ssh/id_ed25519.pub"
  "/root/.ssh/known_hosts"
)

echo "Checking environment for required settings …"
for var in "${ENVVARS[@]}"
do
  if [[ ! -n "${!var}" ]]; then
    echo "The environment variable ${var} must be set via mounted secret!"
    exit 1
  else
    echo "${var} - ok"
  fi
done

echo "Checking for required config files …"
for var in "${FILEVARS[@]}"
do
  if [[ ! -f "${var}" ]]; then
    echo "The file ${var} must be mapped into the pod via mounted configMap!"
    exit 1
  else
    echo "${var} - ok"
  fi
done

echo "Checking for required ssh files …"
for var in "${SSHFILES[@]}"
do
  if [[ ! -f "${var}" ]]; then
    echo "The file ${var} must be mapped into the pod!"
    exit 1
  else
    echo "${var} - ok"
  fi
done

echo "Creating borg mount point /mnt/borg …"
mkdir -p /mnt/borg

echo "Creating S3 mount point ${S3_MOUNTPOINT} …"
mkdir -p ${S3_MOUNTPOINT}

# mount S3 buckets for app and cluster job only!
if [[ ! "${BORG_MODE}" = "node" ]]; then
  echo "Checking ${S3_BUCKETS} for S3 buckets to be mounted …"
  if [[ -f "${S3_BUCKETS}" ]]; then
    echo "${AWS_KEY}:${AWS_SECRET_KEY}" > /root/.s3fs
    chmod 600 /root/.s3fs

    while read bucket; do
      echo "Mounting S3 bucket ${bucket} …"
      mkdir -p ${S3_MOUNTPOINT}/${bucket}
      s3fs ${bucket} ${S3_MOUNTPOINT}/${bucket} -o passwd_file=/root/.s3fs,use_path_request_style,url=${S3_ENDPOINT}
    done < ${S3_BUCKETS}
  fi
fi

echo "Configuration successfully completed."

if [[ "$1" = "run" ]]; then
  if [[ "${BORG_MODE}" = "node" ]]; then
    echo "Running borg-backup for node ${NODE_NAME} …"
  else
    echo "Running borg-backup for cluster …"
  fi
  borg-backup
else
  echo "Running inspection mode …"
  tail -F /var/log/borg-backup.log
fi

ret_code=$?
exit $ret_code

# end
