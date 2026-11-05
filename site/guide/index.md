---
source: chart/README.md
editPage: true
---

# Introduction

<!--@include: ../../chart/README.md#intro-->

wordpress-nginx is a Helm chart and a container image. The chart deploys
WordPress on Kubernetes; the image holds WordPress, NGINX and PHP-FPM, and its
tag is the chart version, so a chart version always names one image.

## Why this chart

**A place to go from the Bitnami WordPress chart.** The chart's values keep the
names of the Bitnami chart's: database, ingress, persistence, probes,
scheduling and most other settings are set through the same keys.
What differs is listed in [Coming from the Bitnami chart](/guide/migrating).
The chart depends on no Bitnami chart or image.

**Security and comfort for the people who run the site.**

- NGINX executes PHP only for WordPress's own entry points
  ([PHP execution allowlist](/security/php-execution-allowlist)), and the
  chart can refuse further paths before any request reaches PHP
  ([Denied paths](/security/denied-paths)).
- An optional watcher reports unexpected files on the site's volume as
  Prometheus metrics ([File-integrity monitoring](/security/file-integrity-monitoring)).
- A daily tracker proposes each new WordPress release as a chart release, and
  a daily scan checks the published image. [Update policy](/security/update-policy)
  describes both, including what the scan cannot see.
- The [wordpress-idx](/features/search-index) sidecar gives the site a
  full-text search over posts, pages and comments, with an API that an
  [agent can use for research](/features/search-index-agents).

## Features

<!--@include: ../../chart/README.md#features-->

## What a release runs

| Part | Image | Runs |
|---|---|---|
| WordPress, NGINX, PHP-FPM | `ghcr.io/ioanalytica/wordpress-nginx`, tagged with the chart version | always |
| MariaDB | the `mariadb` image of the MariaDB project | by default; off with an [external database](/features/database) |
| Dragonfly | the Dragonfly project's image | with `memcached.enabled`, see [Cache](/features/cache) |
| wordpress-idx | `ghcr.io/ioanalytica/wordpress-idx` | with `idx.enabled`, see [Search index](/features/search-index) |
| NGINX Prometheus exporter | `nginx/nginx-prometheus-exporter` | with `metrics.enabled`, see [Metrics](/features/metrics) |
| File-integrity watcher | the `wordpress-nginx` image | with `fim.enabled`, see [File-integrity monitoring](/security/file-integrity-monitoring) |

[The image](/reference/image) describes what the `wordpress-nginx` image
contains.

## Next steps

- [Install](/guide/install) the chart.
- [Configuration](/guide/configuration): the settings most sites change first.
- [Parameters](/reference/parameters): where each group of values is described.
