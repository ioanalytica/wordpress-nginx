# WordPress-NGINX

A production-ready WordPress stack for Kubernetes, built on NGINX and PHP-FPM. Developed by [IO ANALYTICA](https://ioanalytica.com).

## Components

### [Helm Chart](chart/)

Deploys WordPress with NGINX on Kubernetes. Supports Memcached, Redis, and Dragonfly for caching, plus an optional [wordpress-idx](https://github.com/ioanalytica/wordpress-idx) sidecar for full-text search.

```bash
helm install my-wordpress oci://ghcr.io/ioanalytica/charts/wordpress-nginx \
  --set externalDatabase.host=mydb.example.com \
  --set externalDatabase.password=secret \
  --set ingress.enabled=true \
  --set ingress.hostname=blog.example.com
```

See [chart/README.md](chart/README.md) for full documentation and values reference.

### [Docker Image](docker/)

Custom WordPress image based on [shinsenter/php](https://code.shin.company/php) with PHP 8.4 FPM, NGINX, and Alpine Linux. Multi-arch (`linux/amd64`, `linux/arm64`).

| Registry | Image |
|---|---|
| GitHub Container Registry | `ghcr.io/ioanalytica/wordpress-nginx` |

Includes WordPress, NGINX with optimised configuration, PHP extensions (imagick, memcache, redis), WP-CLI, and a health check endpoint at `/healthz.php`.

## Related Projects

- [wordpress-idx](https://github.com/ioanalytica/wordpress-idx) — FlexSearch-based full-text search sidecar for WordPress

## License

Copyright &copy; 2024-2026 [IO ANALYTICA](https://ioanalytica.com).

Licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
