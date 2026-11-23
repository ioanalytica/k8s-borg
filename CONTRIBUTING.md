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

The tests need `shellcheck`, `bats`, `helm`, Node.js 22.18 or later (it runs
the site's link code) and Python 3 with PyYAML (`apt-get install python3-yaml`,
or `pip install PyYAML` in a virtual environment); the end-to-end suites need
docker.
[`tests/README.md`](tests/README.md) describes each layer. CI runs all of them
on every pull request, except the end-to-end suites on one that changes only
documentation: Markdown at the top level, `LICENSE`, `examples/` or the
documentation site in `site/`.

The site's page "Try it locally" runs as written in a k3d cluster:
`tests/try-locally/run.sh` (docker, k3d, kubectl, helm, jq). CI runs it with
`.github/workflows/try-locally.yml`, on a pull request that changes the chart,
`examples/k3d/` or the page, with the pull request's chart, every Monday
with the latest release, and after each tag's build with the chart and the
images that tag published, signed and tagged (`build.yml` calls it after
its tag job, beside the release, which does not wait for it). A pull request
whose chart names images not published yet, a release for one, gets a notice
instead of a run; the tag's run then checks the page. A red run on an rc
means the page or the release needs a fix before `X.Y.Z` is tagged; a red
run on `X.Y.Z` holds up nothing, its rc has passed the same page. To check a
page change against a prerelease, run the workflow by hand with that
version.

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

## Releases

A release is one pull request: `version` and `appVersion` in
`chart/Chart.yaml` at `X.Y.Z`, with the `k8s-borg` entry of
`artifacthub.io/images` and the pin in `examples/helm/k8s-borg.yaml`, and
`## Unreleased` in `CHANGELOG.md` turned into `## X.Y.Z`, led by the line for
the Borg UI pin. Its commit on `main` is then tagged twice:

1. `X.Y.Z-rc.1` builds a prerelease of that commit: the chart and the agent
   image at `X.Y.Z-rc.1`, the entry of `## X.Y.Z` as its notes, no `latest`
   tag moved. "Try it locally" runs against it.
2. Once it passed, `X.Y.Z` on the same commit: the release is the source the
   candidate tested.

A fix goes to `main` by pull request, and its commit is tagged `X.Y.Z-rc.2`.
`tests/check-release-tag.sh` takes the chart's version and any `-suffix` of it
as a tag. Prereleases are public: they stay, like releases.

## Dependency updates

[Renovate](https://docs.renovatebot.com/) opens the update pull requests, as
[`.github/renovate.json`](.github/renovate.json) configures it on top of the
shared preset of
[ioanalytica/renovate-config](https://github.com/ioanalytica/renovate-config):
every night (Europe/Berlin), each with a review request, and never merged by
the bot. A release must be three days old before its pull request comes, with
three exceptions. etcd, rclone, s3fs and the MySQL client of the agent image
come in the night after their release (its Python packages wait the three
days). A new digest under an unchanged tag has no release date and does not
wait. And a fix for a vulnerability that Renovate raises an alert for comes at
any time, in a monthly group as well. It raises one where GitHub's advisories
or the OSV database list the vulnerability for a package it follows through a
package manager, from OSV for a direct dependency only. A security fix without
such an alert, as in a base image or a binary taken from a release page, comes
like any other release of that component. The groups that come once a month,
listed below, stay monthly. Nothing waits for approval on its Dependency
Dashboard issue, which lists every dependency it found: an update that is a
deliberate move, every new major among them, comes as a pull request with the
label `decision`. What closing a pull request declines depends on the update
(with `recreateWhen` at its default, `auto`):

- A minor or patch update: only that version is declined. The next release
  comes as a new pull request.
- A major: every release of that major is declined, and the next major comes
  as a new pull request. Moving to the declined major by hand brings its
  updates back.
- A digest, such as a moved action tag: only that digest is declined.
- A pull request whose body says ":ghost: **Immortal**", usually a group
  whose updates go to different versions: nothing is declined, and Renovate
  opens it again at its next scheduled run, without a comment. To hold one of
  its updates back, constrain it in `.github/renovate.json`, as
  `allowedVersions` holds the MySQL client to 8.4. Any other group, such as
  `renovate-config`, whose updates go to one version, is declined like a
  single update.

When Renovate declines, it says so in a comment on the closed pull request;
renaming the closed pull request lifts the decline.

The hash pins that go with a version pin are listed in
[`.github/checksums.yaml`](.github/checksums.yaml). On the bot's branch, the
workflow `.github/workflows/pin-checksums.yml` fills them from the release,
after checking its PGP signature where the table names a key, and adds the
`CHANGELOG.md` line, as a signed commit of the GitHub App
`ioanalytica-renovate-helper`. When a check fails it commits nothing and says
why in a comment; the rebase checkbox of the pull request runs it again (a
re-run by hand does nothing). A new hash pin needs its entry in the table
(`tests/renovate-config.bats`), and pins in `.github/workflows/` belong in a
local action under `.github/actions/`: the app may not change workflows.

- **GitHub Actions** are pinned to a commit, with the release in a comment
  (`uses: actions/checkout@<sha> # v7.0.1`); `tests/renovate-config.bats`
  fails on a tag. Minor and patch releases come as one pull request, together
  with the Helm and cosign versions the workflows install and the runner
  images; a new major comes on its own. A new commit under an unchanged
  release means the tag was moved: its pull request carries the label
  `decision`. oras, which a release installs with `.github/actions/setup-oras`,
  comes on its own, with its `ORAS_SHA256` filled from the release's signed
  checksums; the job `oras` of Lint & test fails until it matches.
- **The agent image's pins** in `docker/Dockerfile` and `docker/rclone.env`
  each sit under a `# renovate: datasource=… depName=…` line, and a new pin
  needs one too (`tests/renovate-config.bats`). MySQL (version and digest,
  held to the 8.4 LTS series), pymongo, dnspython and PyYAML come as one pull
  request, which gets its line in `CHANGELOG.md` on the bot's branch by hand.
  etcd, rclone and s3fs come on their own, with their sums and their
  `CHANGELOG.md` line from the workflow; the build fails while a sum is
  wrong. A new etcd minor and every s3fs release (it is built with a patch)
  carry the label `decision`.
- **k3d**, which `.github/workflows/try-locally.yml` installs, and **the k3s
  image** the page "Try it locally" creates its cluster with
  (`k3d cluster create … --image rancher/k3s:…`) come on their own; each pull
  request runs the job, which runs the page's command. A new minor of either
  fails `tests/try-locally.bats` until the page's "Tested with k3d … and
  k3s …" names it.
- **The local test stack** (`local/`) and **the documentation site's npm
  packages** (`site/`) come once a month, a pull request each, and so does the
  Renovate that `.github/workflows/renovate-config.yml` runs to validate a
  change to the config.

Left alone on purpose: the `borg-ui` submodule (a pin move is a release, with
its line in `CHANGELOG.md`), the image tags in `chart/values.yaml` and the
chart's dependency (they move with the chart's releases), and the versions
that Borg UI's runtime base sets, `PYTHON_VERSION` included: those move with
the `borg-ui` pin. Renovate does not look into `tests/` and `examples/`.

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
