# WordPress-NGINX Helm Chart

A production-ready Helm chart for deploying WordPress with NGINX on Kubernetes. Developed by [IO ANALYTICA](https://ioanalytica.com).

## Features

- **NGINX** as web server (instead of Apache) with PHP-FPM
- **Internal or external MariaDB** database
- **Internal Dragonfly** cache server (serves both Redis and Memcached protocols) or external cache
- **W3 Total Cache** auto-configuration for object and database caching
- **Full-text search sidecar** ([wordpress-idx](https://github.com/ioanalytica/wordpress-idx)) with FlexSearch-based API
- **Prometheus metrics** via NGINX exporter sidecar
- **Horizontal Pod Autoscaling** with CPU/memory targets
- **Network Policies** for pod-level firewall rules
- **Dual Ingress** support (primary + secondary for wp-admin restrictions)
- **OpenShift** compatibility via automatic security context adaptation
- **Resource presets** (nano through 2xlarge) for quick sizing

## Prerequisites

- Kubernetes 1.19+
- Helm 3.2+
- PV provisioner support in the underlying infrastructure (if persistence is enabled)

## Quick Start

```bash
helm repo add ioanalytica oci://ghcr.io/ioanalytica/charts

helm install my-wordpress ioanalytica/wordpress-nginx
```

Or install from local source:

```bash
helm install my-wordpress ./chart
```

## Configuration

### WordPress Settings

| Parameter | Description | Default |
|-----------|-------------|---------|
| `wordpressUsername` | WordPress admin username | `user` |
| `wordpressPassword` | WordPress admin password | random |
| `wordpressEmail` | WordPress admin email | `user@example.com` |
| `wordpressBlogName` | Blog name | `User's Blog!` |
| `wordpressScheme` | URL scheme (`http`/`https`) | `http` |
| `wordpressSkipInstall` | Skip the installation wizard | `false` |
| `wordpressConfigureCache` | Auto-configure W3 Total Cache | `false` |
| `wordpressPlugins` | Plugins to activate (`all`, `none`, or list) | `none` |

### Database (MariaDB)

The chart can deploy an internal MariaDB instance or connect to an external database.

#### Internal Database (default)

```yaml
mariadb:
  enabled: true
  image: "mariadb:12.2.2-noble"
  auth:
    rootPassword: "secretroot"
    database: wordpress
    username: wp_user
    password: "secretpass"
  primary:
    persistence:
      enabled: true
      size: 8Gi
    resources: {}
```

#### External Database

```yaml
mariadb:
  enabled: false

externalDatabase:
  host: db.example.com
  port: 3306
  user: wp_user
  password: "secretpass"
  database: wordpress
```

### Cache (Dragonfly)

The chart can deploy an internal [Dragonfly](https://www.dragonflydb.io/) instance (which serves both Redis and Memcached protocols simultaneously) or connect to an external cache server.

#### Internal Cache

```yaml
memcached:
  enabled: true
  image: "dragonflydb/dragonfly:v1.26.0"
  password: "cachepass"
  persistence:
    enabled: true
    size: 1Gi

wordpressConfigureCache: true
externalCache:
  type: redis  # or memcached - determines which protocol to use
```

#### External Cache

```yaml
memcached:
  enabled: false

externalCache:
  type: redis        # or memcached
  host: redis.example.com
  port: 6379

wordpressConfigureCache: true
```

### Ingress

```yaml
ingress:
  enabled: true
  hostname: wordpress.example.com
  ingressClassName: nginx
  tls: true
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
```

A secondary ingress can be configured for `/wp-admin` with separate annotations (e.g., IP restrictions):

```yaml
secondaryIngress:
  enabled: true
  hostname: wordpress.example.com
  path: /wp-admin
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/8"
```

### Search Index (wordpress-idx)

An optional FlexSearch-based full-text search sidecar:

```yaml
idx:
  enabled: true
  port: 3000
  basePath: /idx
  resourcesPreset: "small"
```

### Metrics & Monitoring

```yaml
metrics:
  enabled: true
  image:
    registry: docker.io
    repository: bitnami/nginx-exporter
    tag: 1.4.1-debian-12-r5
  serviceMonitor:
    enabled: true
```

### Resources

Resources can be set explicitly or via presets:

```yaml
# Using a preset
resourcesPreset: "small"  # nano, micro, small, medium, large, xlarge, 2xlarge

# Or explicit resources (overrides preset)
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 1Gi
```

| Preset | CPU Request | Memory Request |
|--------|------------|----------------|
| nano | 100m | 128Mi |
| micro | 250m | 256Mi |
| small | 500m | 512Mi |
| medium | 500m | 1Gi |
| large | 1.0 | 2Gi |
| xlarge | 2.0 | 4Gi |
| 2xlarge | 4.0 | 8Gi |

### Autoscaling

```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPU: 60
  targetMemory: 70
```

When using multiple replicas, ensure the PVC access mode supports `ReadWriteMany`.

### Security Context

```yaml
podSecurityContext:
  enabled: true
  fsGroup: 1001

containerSecurityContext:
  enabled: true
  runAsUser: 1001
  runAsNonRoot: true
  readOnlyRootFilesystem: true
```

OpenShift compatibility is handled automatically via `global.compatibility.openshift.adaptSecurityContext`.

## Upgrading

### To 6.9.4-10

Fixes the image tag alignment: chart version and image tag are now kept in sync (`6.9.4-10`).
No values changes required.

### To 6.9.4-9

Version 6.9.4-9 removes all Bitnami chart dependencies. Key changes:

- **MariaDB**: Now uses a native internal deployment (image: `mariadb:12.2.2-noble`) instead of the Bitnami MariaDB subchart. The `mariadb.image` parameter is new. The `mariadb.architecture` parameter (replication mode) is no longer supported for internal deployments.
- **Cache**: The `memcached.enabled` key is preserved for backward compatibility. When enabled, it now deploys [Dragonfly](https://www.dragonflydb.io/) (serving both Redis and Memcached protocols) instead of the Bitnami Memcached subchart. New parameters: `memcached.image`, `memcached.password`, `memcached.persistence.*`.
- **Resource presets**: Still available via `resourcesPreset` but now provided by the `ioanalytica/common` library chart.
- **Volume permissions**: The `volumePermissions` section has been removed.
- **Default credentials**: Database defaults changed from `bitnami_wordpress`/`bn_wordpress` to `wordpress`/`wp_user`.
- **Common chart**: Switched from `bitnami/common` to `ioanalytica/common`.

## License

Apache-2.0 — see [LICENSE](../LICENSE)

The WordPress software deployed by this chart is licensed under GPL-2.0+.
