# Coming from the Bitnami chart

The values of wordpress-nginx keep the key names of the Bitnami WordPress
chart, so a values file written for that chart mostly carries over. This page
lists what does not: keys that are gone, keys whose default or meaning
changed, and what the comparison leaves out.

::: warning This page compares values, not installations
Taking over the volume and database of an existing Bitnami release is neither
documented nor tested. The chart is not a drop-in replacement for a running
release.
:::

## How much carries over

Compared on 2026-11-05 with version 27.0.1 of the Bitnami WordPress chart: 89
of its 95 top-level keys exist in wordpress-nginx under the same name. That
includes `wordpressUsername` and the other `wordpress*` settings, `ingress`,
`secondaryIngress`, `persistence`, `mariadb`, `externalDatabase`, `memcached`,
`externalCache`, `metrics`, `autoscaling`, `networkPolicy`, `pdb`, the probes,
the `smtp*` settings, `extraEnvVars`, `extraVolumes`, `sidecars`,
`initContainers` and the scheduling settings (`affinity`, `nodeSelector`,
`tolerations`, `topologySpreadConstraints`).

Helm passes over a top-level key the chart does not read, without a message.
Go through the lists below instead of relying on an error.

## Keys that do not exist here

| Bitnami key | Here |
|---|---|
| `apacheConfiguration`, `existingApacheConfigurationConfigMap` | The web server is NGINX: `nginxConfiguration`, `existingNginxConfigurationConfigMap`, and `nginxCustomServerBlockAddition` for additions to the server block. |
| `allowOverrideNone`, `htaccessPersistenceEnabled` | NGINX reads no `.htaccess`. Directories a plugin protects that way are closed with `nginx.deniedPaths`; the chart reports the files it finds. See [Denied paths and .htaccess](/security/denied-paths). |
| `volumePermissions` | Removed. |
| `usePasswordFiles` | Not supported; credentials reach the containers through environment variables sourced from Secrets. |
| `mariadb.architecture` | The bundled MariaDB is a single server. For replication, run the database outside the chart and set `externalDatabase`. |
| `memcached.auth.*`, `memcached.service.*` | The bundled cache is Dragonfly and always has a password: `memcached.password` or `memcached.existingSecret`. See [Cache](/features/cache). |
| `image.tag` | Not read. The image tag is always the chart version; `image.digest` still overrides it. |

## Same key, different default

| Key | Bitnami | wordpress-nginx |
|---|---|---|
| `mariadb.auth.database`, `externalDatabase.database` | `bitnami_wordpress` | `wordpress` |
| `mariadb.auth.username`, `externalDatabase.user` | `bn_wordpress` | `wp_user` |
| `containerPorts.http`, `containerPorts.https` | `8080`, `8443` | `80`, `443` |
| `podSecurityContext.enabled`, `containerSecurityContext.enabled` | `true` | `false` |
| `readinessProbe.httpGet.path`, `startupProbe.httpGet.path` | `/wp-login.php` | `/healthz.php` |
| `image.pullPolicy` | `IfNotPresent` | `Always` |
| `metrics.image` | an Apache exporter | `nginx/nginx-prometheus-exporter` |
| `metrics.containerPorts.metrics` | `9117` | `9113` |
| `hostAliases` | an entry for `status.localhost` | empty |

A values file that names the database and its user explicitly is not affected
by the changed defaults; one that relied on them is. One that enables the
security contexts explicitly needs a test first; see
[Configuration](/guide/configuration#security-context).

## Same key, different meaning

- **`memcached.enabled`** deploys [Dragonfly](https://www.dragonflydb.io/),
  which serves the Memcached and the Redis protocol, instead of a Memcached
  server. `externalCache.type` chooses the protocol WordPress uses.
- **`mariadb.enabled`** deploys one MariaDB server from the MariaDB project's
  image (`mariadb.image`) instead of a subchart.
- **`wordpressConfigureCache`** configures W3 Total Cache only where the
  plugin is already active; it does not install it. See [Cache](/features/cache).
- **`wordpressExtraConfigContent`** is accepted, but the `wp-config.php` the
  chart generates does not evaluate it. Constants set that way, such as
  `DISALLOW_FILE_EDIT`, move to the environment variable
  `WORDPRESS_CONFIG_EXTRA`, set through `extraEnvVars`; see
  [Configuration](/guide/configuration#wordpress-settings).
- **`customHTAccessCM`** is accepted and has no effect, as NGINX reads no
  `.htaccess`.
- **The ingress annotation `nginx.ingress.kubernetes.io/from-to-www-redirect`**
  is not honoured. Redirects are declared in the `redirect` block, which works
  with every supported ingress class; see
  [Ingress and redirects](/features/ingress).

## What is new

Keys without a counterpart in the Bitnami chart: `phpExecutionAllowlist`,
`restApiHardening`, `nginx` (denied paths), `redirect`, `fim`, `idx`,
`wordpressPreinstallPlugins`, `wordpressWpCache` and
`wordpressCacheInstanceId`. The [Security overview](/security/) and the
feature pages describe them. Of these, the PHP execution allowlist and the
preinstalled two-factor plugin are on by default.

## Checking a values file

Render the chart with your values and read the result before installing
anything:

```bash
helm template my-wordpress oci://ghcr.io/ioanalytica/charts/wordpress-nginx -f values.yaml
```

The upgrade notes for the releases that parted with the Bitnami dependencies
are under [Upgrading](/operations/upgrading).
