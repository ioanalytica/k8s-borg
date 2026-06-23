#!/bin/sh
# Entry point for the k8s-borg agent image.
#
# This image is "cold": it ships Borg 1 + Borg 2 + the borg-ui-agent but is NOT
# enrolled. Enrollment (`borg-ui-agent register ...`) happens at first run and
# will be wired up in a later iteration. For now this runs a self-test proving
# the image is correctly built, then execs whatever CMD/arguments were given.
set -eu

echo "k8s-borg agent image — setup self-test (user: $(id -un) $(id -u):$(id -g))"
echo "  borg      : $(borg --version 2>/dev/null || echo 'MISSING')"
echo "  borg2     : $(borg2 --version 2>/dev/null || echo 'MISSING')"
echo "  sudo borg : $(sudo -n borg --version 2>/dev/null || echo 'NO SUDO')"
echo "  sudo borg2: $(sudo -n borg2 --version 2>/dev/null || echo 'NO SUDO')"
if borg-ui-agent --help >/dev/null 2>&1; then
    echo "  agent     : borg-ui-agent installed ($(command -v borg-ui-agent))"
else
    echo "  agent     : MISSING"
    exit 1
fi
if [ ! -f /etc/borg-ui-agent/config.toml ]; then
    echo "  state     : not enrolled (no /etc/borg-ui-agent/config.toml)"
fi

exec "$@"
