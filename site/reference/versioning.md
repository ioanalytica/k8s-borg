# Versioning

`appVersion` is the agent image version, and `image.tag` defaults to it — the
agent image tag is never written down a second time. `version` is `appVersion`
for a new agent release, and gains a `-N` suffix for chart-only changes on top
of it (`1.0.23-1`, `1.0.23-2`, …).

The UI image is a different lifecycle: `borgUI.image.tag` follows the pinned
`borg-ui` submodule. It is `git describe` of the pinned commit against
borg-ui's release tags (`docker/ui-app-version.sh`): `2.3.10` when the pin is
exactly tag `v2.3.10`, `2.3.10-27-gcdd5712c9` for a commit after it. Every pin
gets its own image that way; borg-ui's `VERSION` file stays the same across
many commits, and a tag reused for another pin would overwrite the image an
older chart version still points at.

The managed agent's own version comes from the pin too. Borg UI raises it only
at a release, so a pin past a release that changed the agent gets that pin's
distance appended in both images (`2.3.10-64-g…` → agent `0.1.21.64`,
`docker/agent-version-stamp.sh`): it sorts above the release and below the
next one, and enrolled agents are offered the new code. A pin at a release tag,
or one that left the agent unchanged, keeps the plain version.
The `annotations.images` block in `Chart.yaml` restates all of this for chart
scanners, so it has to be updated along with any bump.

`tests/chart-versions.bats` enforces the whole set — a mismatch fails CI rather
than shipping a chart that points at an image tag nobody built.
