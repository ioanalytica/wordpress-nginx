# WordPress-NGINX

A production-ready WordPress stack for Kubernetes, built on NGINX and PHP-FPM. Developed by [IO ANALYTICA](https://ioanalytica.com).

Documentation: [wordpress-nginx.ioanalytica.com](https://wordpress-nginx.ioanalytica.com)

## Components

### [Helm Chart](chart/)

Deploys WordPress with NGINX on Kubernetes. Supports Memcached, Redis, and Dragonfly for caching, plus an optional [wordpress-idx](https://github.com/ioanalytica/wordpress-idx) sidecar for full-text search.

```bash
kubectl create secret generic my-wordpress-db --from-file=mariadb-password=./db-password.txt

helm install my-wordpress oci://ghcr.io/ioanalytica/charts/wordpress-nginx \
  --set mariadb.enabled=false \
  --set externalDatabase.host=mydb.example.com \
  --set externalDatabase.existingSecret=my-wordpress-db \
  --set ingress.enabled=true \
  --set ingress.hostname=blog.example.com
```

This example uses a database server of your own: `mariadb.enabled=false` switches the bundled MariaDB off, and the `externalDatabase.*` values are read only then. The database password comes from a Secret with the key `mariadb-password`, here created from a file that holds nothing but the password, so that it appears neither on the command line nor in the release's values. Without the three database values the chart deploys its own MariaDB next to WordPress.

The chart version is also the image tag. It names the WordPress release the chart ships and the chart's build on it: `7.1.408` is build 8 on WordPress 7.1.4 (see [Chart versions](chart/README.md#chart-versions)).

To see the chart run before you point it at a cluster of your own, follow [Try it locally](examples/k3d/README.md): a throwaway k3d cluster on one machine, with the search sidecar and file-integrity monitoring switched on, in about two minutes.

See [chart/README.md](chart/README.md) for full documentation and values reference.

### [Docker Image](docker/)

<!-- #region image -->

Custom WordPress image based on [shinsenter/php](https://code.shin.company/php) with PHP 8.4 FPM, NGINX, and Alpine Linux. Multi-arch (`linux/amd64`, `linux/arm64`).

| Registry | Image |
|---|---|
| GitHub Container Registry | `ghcr.io/ioanalytica/wordpress-nginx` |

Includes WordPress, NGINX with optimised configuration, PHP extensions (imagick, memcache, redis), WP-CLI, and a health check endpoint at `/healthz.php`. A PHP execution allowlist restricts PHP execution to known WordPress entry points, so PHP files planted in writable locations such as `wp-content/uploads` are never executed (see the [chart README](chart/README.md#php-execution-allowlist)).

<!-- #endregion image -->

## Related Projects

- [wordpress-idx](https://github.com/ioanalytica/wordpress-idx) — FlexSearch-based full-text search sidecar for WordPress

## Contributing

Issues, questions in [Discussions](https://github.com/ioanalytica/wordpress-nginx/discussions) and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately, as [SECURITY.md](SECURITY.md) describes.

## License

Copyright &copy; 2024-2026 [IO ANALYTICA](https://ioanalytica.com).

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for details.

WordPress itself, which the image contains and the chart deploys, is licensed under the GNU General Public License, version 2 or later.
