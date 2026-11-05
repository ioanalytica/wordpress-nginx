# Update policy

How new WordPress releases and fixed packages reach a chart release, what
checks the published image every day, and what those checks cannot see.

## What a release contains

A chart version names one image: the image tag is the chart version
([Versioning](/reference/versioning)). The image holds WordPress, NGINX,
PHP-FPM and the Alpine packages below them. A change to any of them is a new
chart version; an existing version is never published again with different
content.

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

Once a day a workflow scans the newest published image with
[Trivy](https://trivy.dev/) for vulnerabilities of severity high and critical,
reports the findings to the repository's code scanning, and fails when there
are any. A failing scan is the signal for a new build.

### What the scan does not see

In this image the scan sees the Alpine packages. It does not cover:

- **PHP.** The base image builds PHP from source, so PHP is not an Alpine
  package and a vulnerability in PHP does not show in the scan.
- **WordPress core.** It is part of the image as files, not as a package.
- **Plugins and themes.** They live on the site's volume, not in the image.

A green scan therefore says that the Alpine packages have no known high or
critical vulnerability. It says nothing about PHP, WordPress or a site's
plugins.

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
| Dragonfly (`memcached.image`) | weekly; the pull request is opened only after a container has started with the flags the chart passes |
| NGINX Prometheus exporter (`metrics.image`) | weekly |
| wordpress-idx | weekly |
| MariaDB (`mariadb.image`) | not tracked by a workflow; the pin is raised by hand. Set `mariadb.image` to follow MariaDB releases on your own schedule |

## Following releases

Releases are listed in the [Changelog](/reference/changelog) and on the
repository's [releases page](https://github.com/ioanalytica/wordpress-nginx/releases).
Each changelog entry says what the release changes, a rebuilt image with
current packages included. Watching the repository's releases on GitHub sends a notification for each
one.
