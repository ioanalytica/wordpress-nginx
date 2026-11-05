# Update policy

How new WordPress releases and fixed packages reach a chart release, what
checks the published image every day, and what those checks cannot see.

## What a release contains

A chart version names the images a release builds with it: the chart version
is their tag ([Versioning](/reference/versioning)). The WordPress image holds
WordPress, NGINX, PHP-FPM and the Alpine packages below them; the image of
the optional search sidecar is built from the wordpress-idx source the
repository pins. A change to any of them is a new chart version; an existing
version is never published again with different content. Images and chart
are signed before their tags are set
([Verify a release](/security/verify)).

## New WordPress releases

A workflow asks wordpress.org once a day for the current WordPress release.
When it is newer than the one in the image, the workflow opens a pull request
that raises the WordPress version, the chart version and the changelog
together. A maintainer reviews and merges it and then tags the release. The
tag starts the release build, which runs the image's and the chart's tests
before it publishes anything.

There is no promised time between a WordPress release and the chart release
that ships it. The pull request is there within a day; merging it and tagging
the release are a person's decisions.

## Package updates

Every release build starts from the base image as its registry serves it at
that time, and upgrades all Alpine packages on top. A release therefore
carries the packages current on its build day.

Between WordPress releases, a fixed package arrives with a new build of the
same WordPress release: the last two digits of the chart version count these
builds.

## The daily scan

Once a day a workflow scans every image the chart can run with
[Trivy](https://trivy.dev/) for vulnerabilities of severity high and critical:
the project's own images as last released, every other image at the version
the chart pins. All findings go to the repository's code scanning.

The run fails when a finding has a fixed version. For the project's own image
that is the signal for a new build, for another image the signal to raise its
pin. A fix that has to come with a new image from the image's own project
cannot be installed here; such a finding is listed with its reason and an
expiry date among the
[accepted findings](https://github.com/ioanalytica/wordpress-nginx/blob/main/.github/cve-scan-accepted.yaml)
and fails the run again once that date has passed. A finding without any fix
stays in code scanning and does not fail the run.

### What the scan does not see

In the project's own image the scan sees the Alpine packages. It does not cover:

- **PHP.** The base image builds PHP from source, so PHP is not an Alpine
  package and a vulnerability in PHP does not show in the scan.
- **WordPress core.** It is part of the image as files, not as a package.
- **Plugins and themes.** They live on the site's volume, not in the image.

A green scan therefore says that the Alpine packages have no known high or
critical vulnerability with a fixed version, apart from any accepted finding
named above; one without a fix is listed in code scanning. It says nothing
about PHP, WordPress or a site's plugins.

### What covers the rest

- **PHP** comes from the base image,
  [shinsenter/php](https://code.shin.company/php), which follows the PHP
  releases. Because every release build starts from the current base image, a
  new build picks up the PHP release the base image has by then. The changelog
  names the PHP version of a build where it matters.
- **WordPress core** is covered by the daily tracker above.
- **Plugins and themes** update through WordPress's own auto-updates. The
  plugins the chart preinstalls are set to auto-update; for everything else it
  is the site's setting. The
  [file-integrity watcher](/security/file-integrity-monitoring) reports files
  that do not belong on the volume, whichever way they got there.

## Other images

| Image | Tracked |
|---|---|
| Dragonfly (`memcached.image`) | weekly, by a workflow of its own; the pull request is opened only after a container has started with the flags the chart passes |
| NGINX Prometheus exporter (`metrics.image`) | weekly, by [Renovate](https://docs.renovatebot.com/) |
| wordpress-idx | built by every release from the source this repository pins as a submodule; the pin is moved by hand, with a changelog line |
| MariaDB (`mariadb.image`) | weekly, by Renovate. A new MariaDB series upgrades the data directory of an existing installation, so its pull request waits for a maintainer's approval. Set `mariadb.image` to follow MariaDB releases on your own schedule |

Renovate also proposes new versions of the GitHub Actions and tools the
workflows use. A pull request it opens runs the same tests as any other and is
merged by a maintainer.

## Following releases

Releases are listed in the [Changelog](/reference/changelog) and on the
repository's [releases page](https://github.com/ioanalytica/wordpress-nginx/releases).
Each changelog entry says what the release changes, a rebuilt image with
current packages included. Watching the repository's releases on GitHub sends a notification for each
one.
