# A bare Debian machine with systemd: what the server's install.sh expects to
# find. Everything the agent needs is left for the installer to bring.
FROM debian:12

# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends systemd systemd-sysv dbus curl ca-certificates openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl mask getty.target console-getty.service systemd-logind.service

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
