# WordPress-NGINX

A production-ready WordPress stack for Kubernetes, built on NGINX and PHP-FPM. Developed by [IO ANALYTICA](https://ioanalytica.com).

Documentation: [wordpress-nginx.ioanalytica.com](https://wordpress-nginx.ioanalytica.com)

## Components

### [Helm Chart](chart/)

Deploys WordPress with NGINX on Kubernetes. Supports Memcached, Redis, and Dragonfly for caching, plus an optional [wordpress-idx](https://github.com/ioanalytica/wordpress-idx) sidecar for full-text search, whose image is built here as well, from the `wordpress-idx` submodule.

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

## Verify a release

<!-- #region verify -->
Releases after 7.1.408 sign both images and the chart with
[Sigstore](https://www.sigstore.dev/) cosign, keyless: the certificate is
issued to this repository's `release.yml` running for the release tag, and
each signature is recorded in the public Rekor log. Every platform of an image
also carries an SPDX SBOM and SLSA provenance. Both are attestation manifests
listed in the image index, so the index's signature covers them.

A release sets its tags only once the signatures are in place: until then the
images and the chart are in the registry under their digests alone, so no tag
names an artifact that is not signed yet.

Resolve the tag once and use the digest from then on, so that what you read
afterwards belongs to what you verified. The identity names the release's
tag, so the check also fails for a tag that was pointed at the image of
another release. With
[cosign](https://docs.sigstore.dev/cosign/system_config/installation/) 3:

```sh
# Signed: ghcr.io/ioanalytica/wordpress-nginx, ghcr.io/ioanalytica/wordpress-idx
# and ghcr.io/ioanalytica/charts/wordpress-nginx
version=<version>
repo=ghcr.io/ioanalytica/wordpress-nginx
digest=$(docker buildx imagetools inspect "$repo:$version" --format '{{json .Manifest}}' | jq -r .digest)
cosign verify "$repo@$digest" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity "https://github.com/ioanalytica/wordpress-nginx/.github/workflows/release.yml@refs/tags/$version"
```

For `latest`, which names no version, `--certificate-identity-regexp` with
the same address up to `@refs/tags/`, written as a regular expression,
accepts any release of this project; the output names the tag that signed.

The SBOM and the provenance of an image, per platform:

```sh
docker buildx imagetools inspect "$repo@$digest" --format '{{json .SBOM}}'
docker buildx imagetools inspect "$repo@$digest" --format '{{json .Provenance}}'
```

The image of the search sidecar, `ghcr.io/ioanalytica/wordpress-idx`, is
built and signed by the same release, from the
[wordpress-idx](https://github.com/ioanalytica/wordpress-idx) source this
repository pins as a submodule, and carries the chart version as its tag. Its
labels `org.opencontainers.image.version` and
`org.opencontainers.image.revision` name the wordpress-idx version and commit
it was built from. The first release that builds a new wordpress-idx version
also gives its image that version as a tag, which then stays on that build.
The tags `1.x.y` up to `1.3.7` were published by the wordpress-idx repository
before that and are not signed.
<!-- #endregion verify -->

## Related Projects

- [wordpress-idx](https://github.com/ioanalytica/wordpress-idx) — FlexSearch-based full-text search sidecar for WordPress

## Contributing

Issues, questions in [Discussions](https://github.com/ioanalytica/wordpress-nginx/discussions) and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately, as [SECURITY.md](SECURITY.md) describes.

## License

Copyright &copy; 2024-2026 [IO ANALYTICA](https://ioanalytica.com).

Licensed under the Apache License, Version 2.0: see [LICENSE](LICENSE), and [NOTICE](NOTICE) for what the license covers.

WordPress itself, which the image contains and the chart deploys, is licensed under the GNU General Public License, version 2 or later.
