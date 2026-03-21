# WordPress-NGINX Helm Chart

A production-ready Helm chart for deploying WordPress with NGINX on Kubernetes. Developed by [IO ANALYTICA](https://ioanalytica.com), originally derived from the [Bitnami WordPress chart](https://github.com/bitnami/charts/tree/main/bitnami/wordpress) but extensively modified to use NGINX instead of Apache and to support additional caching backends.

## Features

- **NGINX** as web server (instead of Apache)
- **PHP-FPM** with configurable settings
- **Memcached** or **Redis** for object caching (including [Dragonfly](https://www.dragonflydb.io/) as drop-in replacement)
- **Full-text search sidecar** ([wordpress-idx](https://github.com/ioanalytica/wordpress-idx)) with FlexSearch-based API
- Multi-arch Docker image (`linux/amd64`, `linux/arm64`)
- Horizontal Pod Autoscaling (HPA)
- Pod Disruption Budget (PDB)
- Network Policies
- Prometheus metrics via nginx-exporter
- Ingress with TLS support (primary + secondary)
- ReadWriteMany volumes for multi-replica deployments

## Prerequisites

- Kubernetes 1.23+
- Helm 3.8.0+
- PV provisioner support in the underlying infrastructure
- External MariaDB/MySQL database
- (Optional) External Memcached, Redis, or Dragonfly instance

## Quick Start

```console
helm install my-wordpress ./chart \
  --set externalDatabase.host=mydb.example.com \
  --set externalDatabase.user=wordpress \
  --set externalDatabase.password=secret \
  --set externalDatabase.database=wordpress \
  --set ingress.enabled=true \
  --set ingress.hostname=blog.example.com
```

## Docker Image

The chart uses a custom WordPress-NGINX image based on [shinsenter/php](https://code.shin.company/php) with PHP-FPM and NGINX on Alpine Linux.

| Registry | Image |
|---|---|
| GitHub Container Registry | `ghcr.io/ioanalytica/wordpress-nginx` |

The image includes:
- WordPress (version tracked in `Chart.yaml` `appVersion`)
- NGINX with optimised configuration
- PHP 8.4 with FPM, imagick, and memcache extensions
- WP-CLI
- Health check endpoint at `/healthz.php`

## Configuration

The chart is configured identically to the Bitnami WordPress chart. All standard Bitnami WordPress values are supported. Key differences and additions are documented below.

### Current Limitations

The Bitnami sub-charts for MariaDB, Memcached, and Redis are **not fully ported**. Use external services instead:

```yaml
mariadb:
  enabled: false

externalDatabase:
  host: mydb.example.com
  port: 3306
  user: wordpress
  password: secret
  database: wordpress
```

### Caching

The chart supports Memcached and Redis for WordPress object caching via [W3 Total Cache](https://wordpress.org/plugins/w3-total-cache/). [Dragonfly](https://www.dragonflydb.io/) can be used as a drop-in replacement for either.

#### Memcached / Dragonfly (Memcached protocol)

```yaml
wordpressConfigureCache: true
memcached:
  enabled: false
externalCache:
  host: my-memcached.example.com
  port: 11211
```

#### Redis / Dragonfly (Redis protocol)

```yaml
wordpressConfigureCache: true
externalCache:
  host: my-redis.example.com
  port: 6379
```

### Full-Text Search Sidecar (wordpress-idx)

The chart supports the [wordpress-idx](https://github.com/ioanalytica/wordpress-idx) sidecar for full-text search:

```yaml
idx:
  enabled: true
  basePath: /idx
  startupDelay: 30
  resourcesPreset: "small"
  image:
    registry: ghcr.io
    repository: ioanalytica/wordpress-idx
    tag: "0.1.6"
    pullPolicy: Always
```

When enabled:
- The sidecar runs in the same pod as WordPress
- Shares the pod's PVC at `/idx` (subPath: `idx`) for persistent index storage
- Database credentials are derived from the WordPress database configuration
- Ingress path `/idx` is routed to the sidecar's port 3000
- NetworkPolicy allows ingress on port 3000
- Liveness probe on `/healthz`, readiness probe on `/readyz`

### NGINX Configuration

Custom NGINX configuration can be provided:

```yaml
nginxConfiguration: |
  # Custom nginx.conf content
```

Or via an existing ConfigMap:

```yaml
existingNginxConfigurationConfigMap: my-nginx-config
```

Additional server block directives:

```yaml
nginxCustomServerBlockAddition: |
  location /custom {
    # ...
  }
```

### Ingress

```yaml
ingress:
  enabled: true
  hostname: blog.example.com
  tls: true
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
```

A secondary ingress is also supported for multi-domain setups.

### Prometheus Metrics

```yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
```

Deploys an [nginx-exporter](https://github.com/nginx/nginx-prometheus-exporter) sidecar with a `ServiceMonitor` for Prometheus Operator.

## Parameters

### Global Parameters

| Name | Description | Default |
|---|---|---|
| `global.imageRegistry` | Global Docker image registry | `""` |
| `global.imagePullSecrets` | Global Docker registry secret names | `[]` |
| `global.defaultStorageClass` | Global default StorageClass | `""` |

### WordPress Image

| Name | Description | Default |
|---|---|---|
| `image.registry` | Image registry | `ghcr.io` |
| `image.repository` | Image repository | `ioanalytica/wordpress-nginx` |
| `image.tag` | Image tag | (see `Chart.yaml`) |
| `image.pullPolicy` | Image pull policy | `Always` |

### WordPress Configuration

| Name | Description | Default |
|---|---|---|
| `wordpressUsername` | Admin username | `user` |
| `wordpressPassword` | Admin password | `""` |
| `wordpressEmail` | Admin email | `user@example.com` |
| `wordpressBlogName` | Blog name | `User's Blog!` |
| `wordpressTablePrefix` | Database table prefix | `wp_` |
| `wordpressSkipInstall` | Skip installation wizard | `false` |
| `wordpressConfigureCache` | Enable W3 Total Cache | `false` |
| `wordpressPlugins` | Plugins to activate | `none` |

### Database

| Name | Description | Default |
|---|---|---|
| `externalDatabase.host` | Database host | `localhost` |
| `externalDatabase.port` | Database port | `3306` |
| `externalDatabase.user` | Database user | `bn_wordpress` |
| `externalDatabase.password` | Database password | `""` |
| `externalDatabase.database` | Database name | `bitnami_wordpress` |

### Cache

| Name | Description | Default |
|---|---|---|
| `externalCache.host` | Cache server host | `localhost` |
| `externalCache.port` | Cache server port | `11211` |

### IDX Search Sidecar

| Name | Description | Default |
|---|---|---|
| `idx.enabled` | Enable wordpress-idx sidecar | `false` |
| `idx.basePath` | API base path | `/idx` |
| `idx.startupDelay` | Seconds to wait before DB connection | `0` |
| `idx.resourcesPreset` | Resource preset | `"small"` |
| `idx.image.registry` | Sidecar image registry | `ghcr.io` |
| `idx.image.repository` | Sidecar image repository | `ioanalytica/wordpress-idx` |
| `idx.image.tag` | Sidecar image tag | `"0.1.6"` |

### Deployment

| Name | Description | Default |
|---|---|---|
| `replicaCount` | Number of replicas | `1` |
| `updateStrategy.type` | Deployment strategy | `RollingUpdate` |
| `resources` | Container resource requests/limits | `{}` |
| `resourcesPreset` | Resource preset (nano, small, medium, large) | `micro` |

### Persistence

| Name | Description | Default |
|---|---|---|
| `persistence.enabled` | Enable persistence | `true` |
| `persistence.storageClass` | StorageClass | `""` |
| `persistence.accessModes` | Access modes | `[ReadWriteOnce]` |
| `persistence.size` | Volume size | `10Gi` |

### Ingress

| Name | Description | Default |
|---|---|---|
| `ingress.enabled` | Enable ingress | `false` |
| `ingress.hostname` | Default hostname | `wordpress.local` |
| `ingress.tls` | Enable TLS | `false` |
| `ingress.annotations` | Ingress annotations | `{}` |

### Metrics

| Name | Description | Default |
|---|---|---|
| `metrics.enabled` | Enable Prometheus metrics | `false` |
| `metrics.serviceMonitor.enabled` | Create ServiceMonitor | `false` |

For the complete list of parameters, refer to `values.yaml`.

## Known Limitations

- NGINX does not process `.htaccess` files. Directory-level configuration must be added via NGINX configuration directives.
- The Bitnami sub-charts for MariaDB, Memcached, and Redis are included as dependencies but not fully ported. Use external services.
- When running multiple replicas, WordPress maintenance mode only activates on one replica. Use WP-CLI across all replicas for admin operations.

## Attribution

This chart is derived from the [Bitnami WordPress chart](https://github.com/bitnami/charts/tree/main/bitnami/wordpress) and uses the [Bitnami Common library chart](https://github.com/bitnami/charts/tree/main/bitnami/common). It uses a custom Docker image based on [shinsenter/php](https://code.shin.company/php).

## License

Copyright &copy; 2024-2026 [IO ANALYTICA](https://ioanalytica.com).

Licensed under the Apache License, Version 2.0. See [LICENSE](../LICENSE) for details.
