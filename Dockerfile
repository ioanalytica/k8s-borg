# hadolint ignore=DL3007
FROM alpine:latest

# hadolint ignore=DL3018
RUN sed -i 's/#\(.*\/community\)/\1/' /etc/apk/repositories; \
    apk update && apk upgrade --no-cache; \
    rm -rf /var/cache/apk/*; \
    apk --update --no-cache add \
    tzdata \
    s3fs-fuse \
    borgbackup \
    py3-llfuse \
    openssh-client \
    ca-certificates \
    postgresql-client \
    mariadb-client \
    rsync \
    bash

RUN mkdir -p /root/.secrets && \
    mkdir -p /root/.borg && \
    mkdir -p /root/.cache && \
    mkdir -p /root/.ssh

COPY borg/borg-* /usr/local/bin/
COPY borg/backup-* /usr/local/bin/
COPY borg/restore-* /usr/local/bin/
COPY run.sh /run.sh

# Run the command on container startup
RUN chmod -R 700 /root/.secrets && \
    chmod -R 700 /root/.borg && \
    chmod -R 700 /root/.ssh && \
    chmod 750 /run.sh && \
    chmod 755 /usr/local/bin/borg-* && \
    chmod 755 /usr/local/bin/backup-* && \
    chmod 755 /usr/local/bin/restore-* && \
    touch /var/log/borg-backup.log

CMD [ "/run.sh" ]
