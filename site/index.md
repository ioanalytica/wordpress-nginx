---
layout: home
title: wordpress-nginx
titleTemplate: WordPress on NGINX for Kubernetes
source: chart/README.md
editPage: true
hero:
  name: wordpress-nginx
  text: WordPress on NGINX for Kubernetes
  tagline: A Helm chart and image that keep the values keys of the Bitnami WordPress chart, run WordPress on NGINX and PHP-FPM, and add hardening, file-integrity monitoring and a full-text search sidecar.
  actions:
    - theme: brand
      text: Install
      link: /guide/install
    - theme: alt
      text: Coming from Bitnami
      link: /guide/migrating
    - theme: alt
      text: Introduction
      link: /guide/
    - theme: alt
      text: GitHub
      link: https://github.com/ioanalytica/wordpress-nginx
features:
  - icon: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h11"/><path d="m11 3 4 4-4 4"/><path d="M20 17H9"/><path d="m13 13-4 4 4 4"/></svg>'
    title: Coming from the Bitnami chart
    details: The values keep the Bitnami chart's keys, so most of an existing values file carries over. The page lists the keys and defaults that differ.
    link: /guide/migrating
  - icon: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 5 6v5c0 4.5 2.9 8.4 7 10 4.1-1.6 7-5.5 7-10V6z"/><path d="m9 12 2 2 4-4"/></svg>'
    title: Hardening by default
    details: NGINX runs PHP only for WordPress's own entry points, so a PHP file written to the uploads directory is never executed. A two-factor plugin is preinstalled, and SMTP credentials are not sent unencrypted.
    link: /security/
  - icon: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h4"/><path d="M14 3v5h5"/><path d="M19 8v3"/><circle cx="16.5" cy="16.5" r="3"/><path d="m21 21-2.3-2.3"/></svg>'
    title: File-integrity monitoring
    details: An optional watcher reads the site's volume read-only and reports unexpected files and changed drop-ins as Prometheus metrics, with no baseline upkeep after plugin updates.
    link: /security/file-integrity-monitoring
  - icon: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20 12a8 8 0 1 1-2.4-5.7"/><path d="M20 4v4h-4"/><path d="M12 8v4l3 2"/></svg>'
    title: Updates
    details: A daily tracker opens the pull request for a new WordPress release, a daily scan checks the published image, and every release build upgrades the Alpine packages. The page says what the scan does not see.
    link: /security/update-policy
  - icon: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.4-4.4"/><path d="M8.5 11h5M11 8.5v5"/></svg>'
    title: Full-text search
    details: The wordpress-idx sidecar indexes posts, pages and comments and serves a search and statistics API, for the site's own search and for agents doing research.
    link: /features/search-index
  - icon: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 3 7.5l9 4.5 9-4.5z"/><path d="m3 12 9 4.5 9-4.5"/><path d="m3 16.5 9 4.5 9-4.5"/></svg>'
    title: Upstream images only
    details: MariaDB, Dragonfly and the NGINX Prometheus exporter run from their projects' own images. The chart has no Bitnami dependency.
    link: /guide/#what-a-release-runs
---

## How it fits together

A release is one WordPress Deployment. Its container runs NGINX and PHP-FPM
from the `wordpress-nginx` image, whose tag is the chart version. WordPress
itself is part of the image; `wp-content` and the site's own `nginx.conf` live
on the release's volume, and the chart writes `wp-config.php` on every start.
An init container prepares the volume and reports `.htaccess` files that NGINX
would not honour.

Next to it the chart runs a MariaDB server by default, or connects to an
external one, and on request a Dragonfly cache, the wordpress-idx search
sidecar, an NGINX Prometheus exporter and the file-integrity watcher.
[What a release runs](/guide/#what-a-release-runs) lists them.

## Quick start

<!--@include: ../chart/README.md#install-->

[Install](/guide/install) covers the prerequisites and pinning a version,
[Configuration](/guide/configuration) the settings most sites change first.
