# Contributing to wordpress-nginx

Thanks for helping. Bug reports, questions and pull requests are all welcome.

## Where things go

- **Bugs and feature requests**: [open an issue](https://github.com/ioanalytica/wordpress-nginx/issues/new/choose).
  For a bug, the chart version and the values that differ from the defaults
  usually decide where to look.
- **Questions and ideas**: [Discussions](https://github.com/ioanalytica/wordpress-nginx/discussions).
- **Security issues**: never in a public issue — see [SECURITY.md](SECURITY.md).
- **The search sidecar** the chart can deploy is developed in
  [wordpress-idx](https://github.com/ioanalytica/wordpress-idx). How the chart
  deploys it (the `idx` values, its probes, its ingress path) is decided here;
  the search API and the search plugin are decided there.
- **WordPress itself**, its plugins and themes belong to their own projects;
  the [WordPress support forums](https://wordpress.org/support/forums/) are
  the place for questions about them.

## What is where

| Path | What it holds |
|---|---|
| `chart/` | The Helm chart: `templates/`, `values.yaml`, its `README.md` and `CHANGELOG.md`, and its tests in `tests/` |
| `chart/files/fim.php` | The file-integrity watcher the chart can run next to WordPress |
| `docker/` | The image: `Dockerfile`, the files it adds in `rootfs/`, and its tests in `tests/` |
| `examples/k3d/` | The page "Try it locally" and its values file |
| `tests/try-locally/` | The run of that page in a k3d cluster, and its guard test |
| `scripts/chart-version.sh` | The version scheme, see [Versions and releases](#versions-and-releases) |
| `site/` | The documentation site, see [The documentation site](#the-documentation-site) |
| `.github/workflows/` | The tests, the release build, the daily scan and the version trackers |

## Running the tests

The tests are shell scripts. They need `helm`, `docker` and Python 3 with
PyYAML. Each block of commands starts in the repository root.

### Chart

```sh
helm dependency update chart/
helm lint chart/
./chart/tests/template-test.sh
./docker/tests/htaccess-test.sh
./chart/tests/fim-test.sh
```

- `helm dependency update` fetches the `common` subchart, which is not checked
  in. Everything below needs it.
- `template-test.sh` renders the chart with many sets of values, the ones in
  `examples/` among them, and checks the manifests. It also checks that the
  version in `chart/Chart.yaml` follows the scheme and agrees with the image
  tags next to it.
- `htaccess-test.sh` runs the init container's `.htaccess` check, taken from
  the rendered chart, in the image the init container uses.
- `fim-test.sh` runs the file-integrity watcher against prepared volume trees,
  in a PHP container.

### Image

```sh
docker build -t wordpress-nginx:test ./docker
./docker/tests/smoke-test.sh wordpress-nginx:test
```

The smoke test starts the image and probes it: the PHP execution allowlist,
denied paths, the REST API hardening and the mail wrapper.

Continuous integration runs both blocks on every pull request, as the jobs
`chart-template-test` and `smoke-test` of
[`.github/workflows/docker-test.yml`](.github/workflows/docker-test.yml).

### Try it locally

```sh
tests/try-locally/test.sh
tests/try-locally/run.sh ./chart
```

The page [Try it locally](examples/k3d/README.md) runs as written.
`test.sh` checks in a second, without a cluster, that the page, its runner and
its workflow still name the same things. `run.sh` creates the page's k3d
cluster, runs every shell block of the page against the chart of the checkout
and deletes the cluster again; it needs `docker`, `k3d`, `kubectl`, `helm`,
`curl` and `openssl`, and the images the chart names in the registry
(`--import` takes a locally built image instead, see the script's header). Continuous integration runs both on a pull request that
changes the chart, the image, `examples/k3d/` or these tests
([`.github/workflows/try-locally.yml`](.github/workflows/try-locally.yml)).

## Pull requests

A pull request is easiest to review when it:

- covers one change, with a test that fails without it: a case in
  `chart/tests/template-test.sh` for the chart, in `docker/tests/smoke-test.sh`
  for the image, in `chart/tests/fim-test.sh` for the file-integrity watcher;
- documents a new value with a `## @param` comment in `chart/values.yaml` and,
  where it needs more than a line, in the section of `chart/README.md` that
  covers it;
- keeps the `<!-- #region name -->` and `<!-- #endregion name -->` comments of
  the READMEs around their sections: the documentation site shows the sections
  by these names;
- adds its lines under `## Unreleased` in
  [`chart/CHANGELOG.md`](chart/CHANGELOG.md) when it changes the chart or the
  image, and leaves the chart version alone, see
  [Versions and releases](#versions-and-releases);
- uses the commit style of the history: a plain imperative summary
  (`Add …`, `Fix …`, `Let …`), with the reason in the body. The commit of a
  release starts with `Version <chart version>: `;
- has every commit signed off, see [Sign your commits (DCO)](#sign-your-commits-dco).

Code, comments, documentation and commit messages are in English.

### Before it is merged

A pull request is merged when all three hold:

1. every check is green;
2. [CodeRabbit](https://www.coderabbit.ai/), which reviews every pull request,
   has approved its latest state;
3. every review thread is resolved.

### Security fixes are worded as hardening

A changelog entry, a commit message and a pull request say what is stricter or
safer now and that upgrading is recommended. They do not describe how an
earlier release could be attacked: installations upgrade at their own pace,
and such a description would point at the ones that have not yet.

A vulnerability that is not public is reported privately first, not fixed in a
public pull request; see [SECURITY.md](SECURITY.md).

## Versions and releases

The chart version is also the image tag. For WordPress `x.y.z` and build `N`
it is `x.y.P` with `P = z * 100 + N`, so `7.1.408` is build 8 on WordPress
7.1.4; [Chart versions](chart/README.md#chart-versions) has the scheme with
examples. `scripts/chart-version.sh next <chart version>` prints the next
build, `scripts/chart-version.sh first <WordPress version>` the first version
for a new WordPress release.

A change to the chart or the image reaches users with the next chart version.
The pull request that makes the change does not raise the version. It adds its
lines under `## Unreleased` at the top of
[`chart/CHANGELOG.md`](chart/CHANGELOG.md), with that heading if it is not
there yet, and says in them what a user of the chart notices.

A release is a pull request of its own. It

1. sets `version` in `chart/Chart.yaml`;
2. sets `annotations.imageTag` there, which must equal `version`;
3. sets the tag of the `wordpress-nginx` entry in `annotations.images` there,
   which must equal `version` too;
4. turns `## Unreleased` in `chart/CHANGELOG.md` into the heading of that
   version.

`./chart/tests/template-test.sh` fails while the three places in
`chart/Chart.yaml` disagree and on a version outside the scheme.

After its merge the maintainers push a tag with the version's name on that
commit. The tag's build tests the image and the chart again, builds the image
for both platforms, publishes image and chart under that version and creates
the GitHub release.

A workflow asks wordpress.org every day for the current WordPress release. The
pull request it opens for a new one is such a release pull request: it also
raises `WP_VERSION` in `docker/Dockerfile` and `appVersion` in
`chart/Chart.yaml`, which no test compares with each other.

A new release of the search sidecar is pinned in two places of
`chart/Chart.yaml`: `annotations.idxImageTag` and the tag of the
`wordpress-idx` entry in `annotations.images`. The template test fails while
they disagree. Check that the image exists before pinning it
(`docker manifest inspect ghcr.io/ioanalytica/wordpress-idx:<tag>`); a release
tag alone does not say that its image was published.

A tag is never moved and a version is never published a second time: a
deployment that pins a version would not see the change. Any change after a
release, however small, gets the next build number.

## The documentation site

The site at [wordpress-nginx.ioanalytica.com](https://wordpress-nginx.ioanalytica.com)
is built with [VitePress](https://vitepress.dev/) from `site/` and needs
Node.js 22.18 or later:

```sh
cd site
npm ci --ignore-scripts
npm run dev      # http://localhost:5173, reloads on every change
```

Most pages show sections of `README.md` and `chart/README.md` by region
(`<!-- #region name -->`) instead of copying them, and `chart/CHANGELOG.md`,
`CONTRIBUTING.md`, `SECURITY.md` and `examples/k3d/README.md` whole. So each
text has one source: edit the file and the page follows.

A pull request that changes the site or a file it shows runs these in
continuous integration:

```sh
site/tests/site-test.sh
(cd site && npm run build)
site/scripts/check-links.sh site/.vitepress/dist
```

## Sign your commits (DCO)

Every commit must carry a `Signed-off-by` line, certifying the
[Developer Certificate of Origin](https://developercertificate.org/): that you
wrote the change or otherwise have the right to submit it under the project's
license. `git commit -s` adds the line from your git name and e-mail.

There is no contributor license agreement.

## License

wordpress-nginx is licensed under the [Apache License 2.0](LICENSE), and
contributions are accepted under the same license. WordPress itself, which the
image contains, is licensed under the GNU General Public License, version 2 or
later.

## Conduct

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
