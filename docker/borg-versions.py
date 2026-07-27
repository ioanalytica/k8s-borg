#!/usr/bin/env python3
"""Print the Borg versions this image builds, from the borg-ui manifest.

The versions are stated once, in the borg-ui submodule
(`app/api/borg_binaries.json`, generated from the version its runtime base
installs). This image reads them from there so a Borg bump happens in one
place, in borg-ui, and the pod agent follows.

Output is shell-eval'able:

    BORG1_VERSION=1.4.5
    BORG2_VERSION=2.0.0b21
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: borg-versions.py MANIFEST")

    manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    for major, version in sorted(manifest["current"].items()):
        print(f"BORG{major}_VERSION={version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
