# Security policy

## Reporting a vulnerability

Report it privately through GitHub:
[**Report a vulnerability**](https://github.com/ioanalytica/wordpress-nginx/security/advisories/new)
(the Security tab of this repository). Please do not open a public issue,
discussion or pull request for a vulnerability that is not public yet.

A useful report names the chart version, the values it needs and what an
attacker gains. We confirm the report, keep you informed while we work on it,
and credit you in the advisory unless you prefer otherwise.

## Supported versions

Fixes go into the next chart version; there are no backports to older ones.
The chart version is also the image tag, so upgrading the chart to the
[latest release](https://github.com/ioanalytica/wordpress-nginx/releases/latest)
brings the fixed image with it.

The exception is a release that sets `image.digest`: the digest takes the
place of the tag, and the release keeps the image it names through a chart
upgrade. Set the new image's digest with the upgrade, or remove the value.

## Scope

This policy covers what this repository builds:

- the **Helm chart** in `chart/`;
- the **`wordpress-nginx` image** in `docker/`, with the NGINX and PHP
  configuration and the scripts it adds;
- the **file-integrity watcher** (`chart/files/fim.php`) that the chart can
  run next to WordPress.

Not covered here:

- A vulnerability in **WordPress** itself belongs to the
  [WordPress project](https://wordpress.org/about/security/), one in a plugin
  or theme to its author.
- A vulnerability in the **search sidecar** belongs to
  [wordpress-idx](https://github.com/ioanalytica/wordpress-idx/security); how
  the chart deploys the sidecar is covered here.
- A vulnerability in **PHP**, **NGINX** or an Alpine package belongs to its
  project. One that is already public is no secret: a normal issue that asks
  for a new build is fine.

## TLS and the key in the image

TLS for a site belongs to the Ingress: the chart serves the site over HTTP
inside the cluster. The image's NGINX also listens on port 443, with a
self-signed certificate for `localhost` that the base image creates when it
is built. That pair is a placeholder that lets NGINX start; it is the same in
every copy of the image and no secret, so the Service's HTTPS port is not
meant to be exposed. An image scanner reports the key as a private key.
Removing the listener is tracked in
[#32](https://github.com/ioanalytica/wordpress-nginx/issues/32).

The chart's default `service.type` is `LoadBalancer`. Where the cluster
gives such a Service an address, the pod's ports, 443 among them, are
reachable on it beside the Ingress, and without what the Ingress adds. With
an Ingress in front, set `service.type: ClusterIP`.

## What the daily scan covers

Once a day a workflow scans every image the chart can run with
[Trivy](https://trivy.dev/) for known vulnerabilities of severity high and
critical: the project's own images as last released, every other image at
the version the chart pins. All findings go to the repository's code
scanning. The run fails when a finding has a fixed version: for the project's
own image that is the signal for a new build, for another image the signal to
raise its pin. A fix that has to come with a new image from the image's own
project is listed, with its reason and an expiry date, in
[`.github/cve-scan-accepted.yaml`](.github/cve-scan-accepted.yaml) and fails
the run again once that date has passed.

In the project's own image the scan sees the **Alpine packages**. It does not
see:

- **PHP.** The base image builds PHP from source, so PHP is not an Alpine
  package, and a vulnerability in PHP does not show in the scan.
- **WordPress core.** It is in the image as files, not as a package.
- **Plugins and themes.** They live on the site's volume, not in the image.

A green scan therefore says that the image's Alpine packages have no known
high or critical vulnerability with a fixed version, apart from any accepted
finding; one without a fix is listed in code scanning. It says nothing about
PHP, WordPress or a site's plugins.

What covers the rest:

- **PHP** comes with the base image,
  [shinsenter/php](https://code.shin.company/php), which follows the PHP
  releases. Every release build starts from the base image as its registry
  serves it at that time, and upgrades all Alpine packages on top. A new PHP
  release in the base image does not start a build by itself: it arrives with
  the next build, which a maintainer starts. The image stays on one PHP
  series (8.4 at present); a new series is a deliberate move by the
  maintainers, because the plugins of a site depend on it.
- **WordPress core** is tracked by a workflow that asks wordpress.org once a
  day for the current release and opens the pull request that raises it.
- **Plugins and themes** are updated by WordPress's own auto-updates. The
  chart switches them on for the plugins it preinstalls; for everything else
  it is the site's setting. The file-integrity watcher reports files that do
  not belong on the volume.

The [update policy](https://wordpress-nginx.ioanalytica.com/security/update-policy)
on the documentation site describes these mechanisms in full.
