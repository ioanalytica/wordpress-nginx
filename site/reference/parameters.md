---
source: chart/README.md
editPage: true
---

# Parameters

Every value is described where it is defined, in
[`values.yaml`](https://github.com/ioanalytica/wordpress-nginx/blob/main/chart/values.yaml).
This page says which part of the documentation covers which group of values.

| Values | Page |
|---|---|
| `wordpress*` settings, `persistence`, `resources`, `resourcesPreset`, `autoscaling`, `podSecurityContext`, `containerSecurityContext` | [Configuration](/guide/configuration) |
| `mariadb`, `externalDatabase` | [Database](/features/database) |
| `memcached`, `externalCache`, `wordpressConfigureCache`, `wordpressCacheInstanceId`, `wordpressWpCache` | [Cache](/features/cache) |
| `ingress`, `secondaryIngress`, `redirect` | [Ingress and redirects](/features/ingress) |
| `wordpressPreinstallPlugins` | [Plugins](/features/plugins) |
| `smtp*` | [Mail](/features/mail) |
| `idx` | [Search index](/features/search-index) |
| `metrics` | [Metrics](/features/metrics) |
| `phpExecutionAllowlist` | [PHP execution allowlist](/security/php-execution-allowlist) |
| `restApiHardening` | [REST API hardening](/security/rest-api-hardening) |
| `nginx.deniedPaths`, `nginx.htaccessPolicy` | [Denied paths and .htaccess](/security/denied-paths) |
| `fim` | [File-integrity monitoring](/security/file-integrity-monitoring) |
| `networkPolicy`, `automountServiceAccountToken` | [Security overview](/security/) |
| `nginxConfiguration`, `nginxCustomServerBlockAddition` | [Applying NGINX configuration changes](/operations/nginx-changes) |

The remaining values (labels and annotations, scheduling, probes, the
Service, extra volumes, containers and environment variables) keep the names
of the Bitnami WordPress chart's; see
[Coming from the Bitnami chart](/guide/migrating) for what differs.

## WordPress settings

<!--@include: ../../chart/README.md#wordpress-settings-->
