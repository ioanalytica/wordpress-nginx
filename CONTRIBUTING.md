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
| `tests/ci/` | The tests of the workflows and of the scripts a release runs |
| `wordpress-idx/` | The search sidecar's source, a git submodule; a release builds the sidecar's image from it |
| `scripts/chart-version.sh` | The version scheme, see [Versions and releases](#versions-and-releases) |
| `scripts/` | Besides that, the scripts of the release workflow and the daily scan |
| `site/` | The documentation site, see [The documentation site](#the-documentation-site) |
| `.github/workflows/` | The tests, the release build, the daily scan and the version trackers |

## Running the tests

The tests are shell scripts. They need `helm`, `docker`, `jq`,
[`yq`](https://github.com/mikefarah/yq) (the Go one, not the Python wrapper of
the same name) and Python 3 with PyYAML; the checks of the scripts and
Dockerfiles need [shellcheck](https://www.shellcheck.net/) and
[hadolint](https://github.com/hadolint/hadolint) as well. Each block of
commands starts in the repository root.

### Chart

```sh
helm dependency update chart/
helm lint chart/
./chart/tests/template-test.sh
./chart/tests/schema-test.sh
./docker/tests/htaccess-test.sh
./chart/tests/fim-test.sh
```

- `helm dependency update` fetches the `common` subchart, which is not checked
  in. Everything below needs it.
- `template-test.sh` renders the chart with many sets of values, the ones in
  `examples/` among them, and checks the manifests. It also checks that the
  version in `chart/Chart.yaml` follows the scheme and agrees with the image
  tags next to it.
- `schema-test.sh` compares `chart/values.schema.json` with
  `chart/values.yaml`: every documented value has its entry, with the same
  default. It also checks that the schema lets through the forms in which
  values reach the chart, and refuses what the chart cannot use.
- `htaccess-test.sh` runs the init container's `.htaccess` check, taken from
  the rendered chart, in the image the init container uses.
- `fim-test.sh` runs the file-integrity watcher against prepared volume trees,
  in a PHP container.

### Image

```sh
docker build -t wordpress-nginx:test ./docker
./docker/tests/smoke-test.sh wordpress-nginx:test
```

The smoke test starts the image and probes it: the ports it listens on, the
PHP execution allowlist, denied paths, the REST API hardening and the mail
wrapper. It also reads the image's layers, none of which may hold a private
key, and compares the image's configuration with the base image's.

### Workflows and release scripts

```sh
git submodule update --init
./tests/ci/test.sh
./tests/ci/shellcheck.sh
git ls-files -z '*Dockerfile' | xargs -0 hadolint
```

- `test.sh` holds every workflow to the project's rules (actions pinned by
  commit, a time limit per job, least permissions) and tests the scripts a
  release and the daily scan run, against a stand-in for the registry. It
  reads the search sidecar's version from the submodule and needs the chart's
  dependencies, like the chart tests.
- `shellcheck.sh` runs shellcheck over every shell script, `hadolint` checks
  the Dockerfiles.

Continuous integration runs all three blocks on every pull request, as the
jobs `chart-template-test`, `smoke-test`, `shellcheck` and `hadolint` of
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
  covers it, and gives it its entry in `chart/values.schema.json`, which is
  written by hand: type, description and the default of `values.yaml`. A
  changed default is changed in both files. `./chart/tests/schema-test.sh`
  names what is missing; keep the entry as permissive as its neighbours,
  since Helm refuses an install whose values the schema does not accept;
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
2. sets the tags of the `wordpress-nginx` and the `wordpress-idx` entry in
   `artifacthub.io/images` there, which must equal `version`: the chart
   version is the tag of both images;
3. turns `## Unreleased` in `chart/CHANGELOG.md` into the heading of that
   version, so that no line is left under `## Unreleased` when it is merged:
   `scripts/changelog-release.sh <version>`.

`./chart/tests/template-test.sh` fails while the places in `chart/Chart.yaml`
disagree, on a version outside the scheme, and when the version is not the
newest one in the changelog. The templates take the image tags from the
chart version itself.

After its merge the maintainers push a tag with the version's name on that
commit, and the release workflow (`.github/workflows/release.yml`) runs:

1. the tests, as a gate for everything that follows;
2. both images, the WordPress image and the search sidecar's, built for each
   platform and pushed to the registry under their digests, with an SBOM and
   provenance, and the smoke test on the built WordPress image;
3. the chart, packaged and pushed under its digest;
4. one job that signs the two images and the chart;
5. only then the tags: the version on both images and the chart, and
   `latest`;
6. the GitHub release, with the changelog entry of the version as its notes,
   and "Try it locally" against what was published.

A failed job can be re-run. [Verify a release](README.md#verify-a-release)
has the commands that check the signatures afterwards.

Where a change calls for it, a release candidate comes first: the tag
`<version>-rc.1` on the same commit runs the whole release and publishes
chart and images at the candidate's version, without moving `latest`. A fix
goes to `main` by pull request, and the next candidate, `-rc.2`, on the new
head. The release is then tagged on the commit its last candidate tested.

Tag the release pull request's merge commit by its hash, not whatever
`origin/main` is by then, and push the tag as a step of its own:

```sh
git fetch origin
git merge-base --is-ancestor <commit> origin/main   # the commit is on main
git rev-parse '<version>-rc.1^{commit}'             # after a candidate: the same commit
git tag <version> <commit>
git push origin <version>
```

A workflow asks wordpress.org every day for the current WordPress release. The
pull request it opens for a new one is such a release pull request, and the
three points hold for it as well: it runs the same script, so the lines under
`## Unreleased` stand under the new version's heading, below its line for
the WordPress update. It also raises
`WP_VERSION` in `docker/Dockerfile` and `appVersion` in `chart/Chart.yaml`,
which the template test holds equal.

The search sidecar is the git submodule `wordpress-idx`; a release builds its
image from the commit the submodule is pinned to. Moving the pin is a change
to that image: a pull request with the new commit and a line under
`## Unreleased` that names the wordpress-idx version. After a fresh clone,
`git submodule update --init` checks the submodule out.

Renovate opens the pull requests for new versions of GitHub Actions, the
third-party images the chart pins and the site's packages
(`.github/renovate.json`). A pull request that moves an image the chart pins
needs its line under `## Unreleased` as well; the bot's pull request says so.

The PHP series of the image is not Renovate's: the tag of the base image in
`docker/Dockerfile` names it, and the maintainers move it by hand, because the
plugins of a site depend on the PHP series. PHP patch releases need no change
there; every release build pulls the base image afresh.

The image takes the base image's files, not its layers, so that the
placeholder key pair of the base image is in no layer of it. The stage
`flat-base` of `docker/Dockerfile` therefore declares the base image's
configuration again. When a base image changes its environment, its working
directory or its user, the build fails and prints the difference; the smoke
test compares the rest (entrypoint, command, stop signal, volumes, labels).
Either way the fix is to change the lines of `flat-base` to match.

A tag is never moved and a version is never published a second time: a
deployment that pins a version would not see the change. The release workflow
refuses a version that is in the registry already. Any change after a
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
wrote the change or otherwise have the right to submit it under the license of
the part it changes. `git commit -s` adds the line from your git name and
e-mail.

There is no contributor license agreement.

## License

wordpress-nginx is licensed under the [Apache License 2.0](LICENSE);
[NOTICE](NOTICE) says what the license covers. A contribution is accepted
under the license of the part it changes. WordPress itself, which the image
contains, is licensed under the GNU General Public License, version 2 or
later.

## Conduct

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
