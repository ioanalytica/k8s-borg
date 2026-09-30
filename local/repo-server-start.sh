#!/usr/bin/env bash
#
# The repository server of the local stack, in one container: what the chart
# spreads over a ConfigMap, a Secret, an init container and the server
# container is set up here as root, then the image's own two scripts run as the
# unprivileged user, exactly as they do in a pod.
set -euo pipefail

SERVER_UID=20222
DATA=/repos
STAGE=/run/borg-repo-server

grep -q '^borg:' /etc/passwd \
  || echo "borg:x:$SERVER_UID:$SERVER_UID:Borg repository server:$STAGE/home:/bin/sh" >>/etc/passwd
grep -q '^borg:' /etc/group || echo "borg:x:$SERVER_UID:" >>/etc/group

install -d -o "$SERVER_UID" -g "$SERVER_UID" "$DATA"
install -d -m 1777 "$STAGE"

# The key files arrive from the host with whatever owner Docker maps them to;
# the server reads its own copies.
install -d /etc/borg-repo-server/ssh
install -m 0444 /local/ssh/ssh_host_ed25519_key /local/ssh/authorized_keys /etc/borg-repo-server/ssh/

su -s /bin/sh borg -c /prepare-repo-server.sh
exec su -s /bin/sh borg -c /run-repo-server.sh
