# Changelog

## 6.9.4-13

* Remove overly restrictive nginx method allow-list (`if ($request_method !~ ^(GET|HEAD|POST)$) { return 444; }`) that broke the WordPress REST API for `OPTIONS`, `PUT`, `DELETE`, `PATCH` — these are required by the Gutenberg block editor and other REST API clients.
* Fix `nginxCustomServerBlockAddition` / `existingCustomServerBlockAdditionConfigMap`: the ConfigMap volume was declared in the Deployment but never mounted into the nginx container, so any user-supplied server-block content was silently ignored. The ConfigMap is now mounted at `/etc/nginx/custom.d/01_userconfig.conf` via `subPath` so the image's baked-in `02-userconfig.conf` remains visible.
* Document in `values.yaml` that `existingCustomServerBlockAdditionConfigMap` must expose its content under the key `01_userconfig.conf`.

## 6.9.4-12

* Update wordpress-idx image to 0.1.10

## 6.9.4-11

* Update wordpress-idx image to 0.1.9

## 6.9.4-5

* Migrate to GitHub and ghcr.io
* Rewrite README, remove Bitnami branding
* Update Chart.yaml with IO ANALYTICA attribution
* Add GitHub Actions for Docker image build

## 6.9.4-4

* Version bump

## 6.9.4-3

* Version bump

## 6.9.4-2

* Version bump

## 6.9.4-1

* Update to WordPress 6.9.4

## 6.9.1-7

* Update wordpress-idx image tag

## 6.9.1-6

* Fix default image tags

## 6.9.1-5

* Allow idx port in NetworkPolicy

## 6.9.1-4

* Fix idx OOM and probe split
