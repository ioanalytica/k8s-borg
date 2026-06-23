#!/bin/sh
# Entry point for the k8s-borg agent image.
#
# This image is "cold": it ships Borg + the borg-ui-agent but is NOT enrolled.
# Enrollment (`borg-ui-agent register ...`) happens at first run and will be
# wired up in a later iteration. For now this runs a self-test proving the
# image is correctly built, then execs whatever CMD/arguments were given.
set -eu

echo "k8s-borg agent image — setup self-test"
echo "  borg : $(borg --version 2>/dev/null || echo 'MISSING')"
if borg-ui-agent --help >/dev/null 2>&1; then
    echo "  agent: borg-ui-agent installed ($(command -v borg-ui-agent))"
else
    echo "  agent: MISSING"
    exit 1
fi
if [ ! -f /etc/borg-ui-agent/config.toml ]; then
    echo "  state: not enrolled (no /etc/borg-ui-agent/config.toml)"
fi

exec "$@"
