---
source: chart/README.md
editPage: true
---

# Install

## Prerequisites

<!--@include: ../../chart/README.md#prerequisites-->

## Install the chart

<!--@include: ../../chart/README.md#install-->

Without further values the release runs WordPress with a MariaDB server of its
own and no Ingress; passwords that are not set are generated and kept in the
release's Secret. A first values file usually sets the administrator and the
host name:

```yaml
wordpressUsername: admin
wordpressEmail: admin@example.com

ingress:
  enabled: true
  hostname: blog.example.com
```

```bash
helm install my-wordpress oci://ghcr.io/ioanalytica/charts/wordpress-nginx -f values.yaml
```

## Pin a version

`helm install` without `--version` installs the newest chart version. For
production, pin one of the
[released versions](https://github.com/ioanalytica/wordpress-nginx/releases):

```bash
helm install my-wordpress oci://ghcr.io/ioanalytica/charts/wordpress-nginx --version <version> -f values.yaml
```

The chart version names the WordPress release and the chart's build on it;
[Versioning](/reference/versioning) explains the scheme, and the
[Changelog](/reference/changelog) lists the versions.

## Next steps

- [Configuration](/guide/configuration): WordPress settings, resources and
  persistence.
- [Ingress and redirects](/features/ingress): ingress classes, TLS, alias and
  retired domains.
- [Security overview](/security/): what is on by default and what is opt-in.
- [Coming from the Bitnami chart](/guide/migrating): what differs for an
  existing values file.
