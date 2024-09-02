#!/bin/bash

echo "Examining secrets …"
echo "export BORG_REPO=${BORG_REPO}" >/root/.borg.cfg
echo "export BORG_PASSPHRASE=${BORG_PASSPHRASE}" >>/root/.borg.cfg
chmod 600 /root/.borg.cfg

echo "${AWS_KEY}:${AWS_SECRET_KEY}" > /root/.s3fs
chmod 600 /root/.s3fs

echo "Mounting ${GITLAB_BACKUP_MNT} …"

s3fs gitlab-backups ${GITLAB_BACKUP_MNT} -o passwd_file=/root/.s3fs,use_path_request_style,url=${S3_ENDPOINT}

if [ $# -eq 0 ]
  then
    echo "No arguments supplied. "
fi
if [[ "$1" = "run" ]]; then
    echo "Running borg-backup …"
    borg-backup
else
    echo "Running inspection mode …"
    /usr/local/bin/borg-list > /var/log/borg-backup.log
    tail -F /var/log/borg-backup.log
fi

ret_code=$?
exit $ret_code

# end
