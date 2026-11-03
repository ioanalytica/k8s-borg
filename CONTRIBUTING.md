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
documentation: Markdown at the top level, `LICENSE`, `examples/` or the
documentation site in `site/`.

The documentation site is [VitePress](https://vitepress.dev/) and needs Node.js:

```sh
npm --prefix site ci
npm --prefix site run dev     # http://localhost:5173, reloads on every change
```

Its pages include sections of `README.md` and `chart/README.md` by region
(`<!-- #region name -->`) instead of copying them, and `CONTRIBUTING.md`,
`SECURITY.md` and `CHANGELOG.md` whole.

A pull request is easiest to review when it:

- covers one change, with a test that fails without it — chart changes get a
  `tests/chart-*.bats` case, script changes a bats test of the script;
- documents a new chart parameter with a `## @param` comment in
  `chart/values.yaml` and, where it needs more than a line, on the page of the
  documentation site ([`site/`](site)) that covers it;
- adds an entry under `## Unreleased` in [`CHANGELOG.md`](CHANGELOG.md) for
  anything a user notices;
- uses the commit style of the history: `feat(chart): …`, `fix: …`,
  `test(e2e): …`, `docs: …`, with the reason in the body.

## Dependency updates

[Renovate](https://docs.renovatebot.com/) opens the update pull requests, as
[`.github/renovate.json`](https://github.com/ioanalytica/k8s-borg/blob/main/.github/renovate.json) configures it: early on
Mondays (Europe/Berlin), for releases at least three days old, and never
merged by the bot. Its Dependency Dashboard issue lists every dependency it
found and the updates that wait for approval there.

- **GitHub Actions** are pinned to a commit, with the release in a comment
  (`uses: actions/checkout@<sha> # v7.0.1`); `tests/renovate-config.bats`
  fails on a tag. Minor and patch releases come as one pull request, together
  with the Helm and cosign versions the workflows install and the runner
  images; a new major comes on its own. A new commit under an unchanged
  release means the tag was moved, and waits for approval on the dashboard.
- **The agent image's pins** in `docker/Dockerfile` and `docker/rclone.env`
  each sit under a `# renovate: datasource=… depName=…` line, and a new pin
  needs one too (`tests/renovate-config.bats`). MySQL (version and digest),
  pymongo, dnspython and PyYAML come as one pull request. etcd and rclone come
  on their own: their checksums are updated by hand on the bot's branch, from
  the source the pull request names, and the build fails until they match. A
  new etcd minor, every s3fs release (it is built with a patch) and every new
  major wait for approval on the dashboard. A pull request that changes the
  agent image gets its line in `CHANGELOG.md` on the bot's branch.
- **The local test stack** (`local/`) and **the documentation site's npm
  packages** (`site/`) come once a month, a pull request each, and so does the
  Renovate that `.github/workflows/renovate-config.yml` runs to validate a
  change to the config.

Left alone on purpose: the `borg-ui` submodule (a pin move is a release, with
its line in `CHANGELOG.md`), the image tags in `chart/values.yaml` and the
chart's dependency (they move with the chart's releases), and what Borg UI's
runtime base pins, `PYTHON_VERSION` included: those move with the `borg-ui`
pin. Renovate does not look into `tests/` and `examples/`.

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
