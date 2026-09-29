#!/usr/bin/env python3
"""Print the Borg versions this image builds, from the borg-ui submodule.

The versions are stated once, in the borg-ui submodule, and this image reads
them from there. A Borg bump happens in one place, in borg-ui, and the pod agent
follows.

  * Borg 1 and Borg 2: `app/api/borg_binaries.json`, generated from the version
    its runtime base installs.
  * borgstore: `docker/runtime-base.env`. Borg 2 and borgstore belong together —
    a Borg 2 beta talks to the borgstore it was released with, on both ends of a
    connection — so the image installs exactly this one instead of whatever
    satisfies Borg's requirement on the day of the build.

The two files state the Borg 2 version independently. They have to agree:
otherwise the borgstore version belongs to another Borg 2 than the one that gets
built, and this script stops the build.

Output is shell-eval'able:

    BORG1_VERSION=1.4.5
    BORG2_VERSION=2.0.0b24
    BORGSTORE_VERSION=0.6.1
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

VERSION = re.compile(r"[0-9][0-9A-Za-z.]*")


def read_env(path: Path) -> dict[str, str]:
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        name, sep, value = line.partition("=")
        if sep and not name.lstrip().startswith("#"):
            values[name.strip()] = value.strip()
    return values


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: borg-versions.py MANIFEST RUNTIME_BASE_ENV")

    manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    env = read_env(Path(sys.argv[2]))
    current = manifest["current"]

    borgstore = env.get("BORGSTORE_VERSION", "")
    if not borgstore:
        raise SystemExit(f"{sys.argv[2]} states no BORGSTORE_VERSION")
    if env.get("BORG2_VERSION") != current.get("2"):
        raise SystemExit(
            f"Borg 2 is {current.get('2')} in {sys.argv[1]} but {env.get('BORG2_VERSION')} in "
            f"{sys.argv[2]}: BORGSTORE_VERSION={borgstore} belongs to another Borg 2"
        )

    versions = {f"BORG{major}_VERSION": version for major, version in sorted(current.items())}
    versions["BORGSTORE_VERSION"] = borgstore
    for name, version in versions.items():
        # The output is eval'ed by a shell.
        if not VERSION.fullmatch(version):
            raise SystemExit(f"{name}={version!r} is not a version")
        print(f"{name}={version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
