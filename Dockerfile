FROM alpine:latest

ENV BEEGFS_MNT /mnt/beegfs

RUN sed -i 's/#\(.*\/community\)/\1/' /etc/apk/repositories; \
    apk update && apk upgrade --no-cache; \
    rm -rf /var/cache/apk/*; \
    apk --update --no-cache add \
    s3fs-fuse \
    borgbackup \
    py3-llfuse \
    openssh-client \
    ca-certificates \
    bash

RUN mkdir -p "$BEEGFS_MNT" && \
    mkdir -p /root/.secrets && \
    mkdir -p /root/.ssh

COPY ../borg/borg-* /usr/local/bin/
COPY ../run.sh /run.sh

# Run the command on container startup
RUN chmod -R 700 /root/.secrets && \
    chmod -R 700 /root/.ssh && \
    chmod 750 /run.sh && \
    chmod 755 /usr/local/bin/borg-* && \
    touch /var/log/borg-backup.log

CMD /run.sh

