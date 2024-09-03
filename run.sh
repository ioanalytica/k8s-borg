#!/bin/bash

set -e

ENVVARS=(
  "S3_ENDPOINT"
  "S3_MOUNTPOINT"
  "S3_BUCKETS"
  "AWS_KEY"
  "AWS_SECRET_KEY"
  "BORG_PATTERNS"
  "BORG_EXCLUDES"
  "BORG_REPO_BASE"
  "NODE_NAME"
  "BORG_PASSPHRASE"
  "BORGBACKUP_ARCHIVE_PREFIX"
  "BORG_ARCHIVE_GLOB"
)

echo "Checking environment for required settings …"
for var in "${ENVVARS[@]}"
do
  if [[ ! -n "${!var}" ]]; then
    echo "The environment variable ${var} must be set via mounted secret!"
    exit 1
  fi
done

echo "Creating borg mount point /mnt/borg …"
mkdir -p /mnt/borg

echo "Creating S3 mount point ${S3_MOUNTPOINT} …"
mkdir -p ${S3_MOUNTPOINT}

echo "Checking S3 mount point …"
if [[ ! -d ${S3_MOUNTPOINT} ]]; then
  echo "The S3 mount point ${S3_MOUNTPOINT} does not exist!"
  exit 1
fi

echo "Checking ${S3_BUCKETS} for S3 buckets to be mounted …"
if [[ ! -f "${S3_BUCKETS}" ]]; then
  echo "No S3 buckets specified to be mounted in ${S3_BUCKETS}. Skipping S3 mounts."
else
  echo "${AWS_KEY}:${AWS_SECRET_KEY}" > /root/.s3fs
  chmod 600 /root/.s3fs

  while read bucket; do
    echo "Mounting S3 bucket ${bucket} …"
    mkdir -p ${S3_MOUNTPOINT}/${bucket}
    s3fs ${bucket} ${S3_MOUNTPOINT}/${bucket} -o passwd_file=/root/.s3fs,use_path_request_style,url=${S3_ENDPOINT}
  done < ${S3_BUCKETS}
fi

echo "Configuration successfully completed."

if [[ "$1" = "run" ]]; then
    echo "Running borg-backup …"
    borg-backup
else
    echo "Running inspection mode …"
    tail -F /var/log/borg-backup.log
fi

ret_code=$?
exit $ret_code

# end
