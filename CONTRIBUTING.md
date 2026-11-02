# Contributing to k8s-borg

Thanks for helping. Bug reports, questions and pull requests are all welcome.

## Where things go

- **Bugs and feature requests**: [open an issue](https://github.com/ioanalytica/k8s-borg/issues/new/choose).
  For a bug, the chart version, the Borg major and the mode (standalone or Borg
  UI agent) usually decide where to look.
- **Questions and ideas**: [Discussions](https://github.com/ioanalytica/k8s-borg/discussions).
- **Security issues**: never in a public issue — see [SECURITY.md](SECURITY.md).
- **Borg UI itself** (the web interface, the server, the agent): k8s-borg ships
  it from the [`borg-ui`](https://github.com/karanhudia/borg-ui) submodule,
  pinned to a release. Changes to it belong upstream, in
  [karanhudia/borg-ui](https://github.com/karanhudia/borg-ui/issues).

## Development

```sh
git clone --recurse-submodules https://github.com/ioanalytica/k8s-borg.git
cd k8s-borg
./docker/ui-app-version.sh --fetch-tags   # borg-ui's release tags, read by the version tests
./run-tests.sh --quick    # shellcheck + bats unit tests, a few minutes
./run-tests.sh            # adds the end-to-end suites (needs docker)
```

The tests need `shellcheck`, `bats`, `helm` and Python 3 with PyYAML
(`apt-get install python3-yaml`, or `pip install PyYAML` in a virtual
environment); the end-to-end suites need docker.
[`tests/README.md`](tests/README.md) describes each layer. CI runs all of them
on every pull request, except the end-to-end suites on one that changes only
documentation: Markdown at the top level, `LICENSE` or `examples/`.

A pull request is easiest to review when it:

- covers one change, with a test that fails without it — chart changes get a
  `tests/chart-*.bats` case, script changes a bats test of the script;
- documents a new chart parameter with a `## @param` comment in
  `chart/values.yaml` and, where it needs more than a line, in
  [`chart/README.md`](chart/README.md);
- adds an entry under `## Unreleased` in [`CHANGELOG.md`](CHANGELOG.md) for
  anything a user notices;
- uses the commit style of the history: `feat(chart): …`, `fix: …`,
  `test(e2e): …`, `docs: …`, with the reason in the body.

## Sign your commits (DCO)

Every commit must carry a `Signed-off-by` line, certifying the
[Developer Certificate of Origin](https://developercertificate.org/): that you
wrote the change or otherwise have the right to submit it under the project's
license. `git commit -s` adds the line from your git name and e-mail.

There is no contributor license agreement.

## License

k8s-borg is licensed under the [GNU Affero General Public License v3.0](LICENSE)
(`AGPL-3.0-only`), and contributions are accepted under the same license.

## Conduct

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
