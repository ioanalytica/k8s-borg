# Security policy

## Reporting a vulnerability

Report it privately through GitHub:
[**Report a vulnerability**](https://github.com/ioanalytica/k8s-borg/security/advisories/new)
(the Security tab of this repository). Please do not open a public issue,
discussion or pull request for a vulnerability that is not public yet.

A useful report names the chart or image version, the configuration it needs
(values, mode, Borg major) and what an attacker gains. We confirm the report,
keep you informed while we work on it, and credit you in the advisory unless
you prefer otherwise.

## Supported versions

Fixes go into the next release; there are no backports to older ones. Upgrade
to the [latest release](https://github.com/ioanalytica/k8s-borg/releases/latest)
to receive them.

## Scope

This policy covers what this repository builds: the Helm chart, the
`k8s-borg` and `k8s-borg-ui` images, and the scripts in them.

- A vulnerability in **Borg UI** (server, web interface, agent) that is not
  specific to k8s-borg belongs to [Borg UI](https://github.com/karanhudia/borg-ui).
- A vulnerability in **BorgBackup** belongs to
  [BorgBackup](https://github.com/borgbackup/borg).
- Known CVEs in the images' third-party packages, and in the third-party images
  the chart runs, are found by a daily Trivy scan; an issue about one that is
  already public is fine. The ones with a fix k8s-borg cannot install yet are
  listed, with the reason, in [`.github/cve-scan-accepted.yaml`](.github/cve-scan-accepted.yaml).

The chart's security model — which pods run privileged and why, what a
repository with a datastore snapshot holds — is described in "Security posture"
in [`chart/README.md`](chart/README.md#security-posture).
