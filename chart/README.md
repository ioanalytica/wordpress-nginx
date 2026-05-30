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

#### Supported `ingressClassName` values

Since **7.0.0-2** the chart renders correctly under all three values
relevant for the nginx → Traefik migration arc:

| Class | Served by | nginx-style annotations | Use when |
| --- | --- | --- | --- |
| `nginx` | `rke2-ingress-nginx` / upstream ingress-nginx | interpreted natively | legacy path, nginx-ingress is your only controller |
| `nginx-traefik` | Traefik `kubernetesIngressNGINX` bridge provider | **translated** on the fly (proxy-body-size, whitelist-source-range, auth-url, backend-protocol, cors-*, …) | transition — same `kind:Ingress` manifest, swap controllers without touching annotations |
| `traefik` | Traefik native `kubernetesIngress` provider | **silently ignored** | steady state — manage behaviour via `traefik.ingress.kubernetes.io/router.middlewares: …` annotations and Middleware CRDs |

The chart itself emits no `nginx.ingress.kubernetes.io/*` annotations
on the primary Ingress; everything in `ingress.annotations` and
top-level `commonAnnotations` is the user's responsibility. Under
`traefik` the user is expected to attach a middleware chain (e.g. body
size limit, IP allowlist, forward auth) via the standard Traefik
annotation rather than expecting the chart to translate.

A secondary ingress can be configured for `/wp-admin` with separate annotations (e.g., IP restrictions):

```yaml
secondaryIngress:
  enabled: true
  hostname: wordpress.example.com
  path: /wp-admin
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/8"
```

#### Redirects (vanity / backup domains, www variants)

The `redirect:` block emits a permanent redirect from a list of source
hostnames to a single `targetUrl`. Works across all three supported
IngressClasses (`nginx`, `nginx-traefik`, `traefik`) — the chart picks
the right resource shape per class automatically (an Ingress with the
`permanent-redirect` annotation on `nginx`, a Middleware +
IngressRoute + optional Certificate on the Traefik variants).

Example: apex `example.com` is the primary site; `example.org`,
`example.net`, and the `www.` variants of each should all redirect to
`https://example.com`:

```yaml
ingress:
  enabled: true
  hostname: example.com
  ingressClassName: traefik   # or nginx-traefik / nginx
  tls: true
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod

redirect:
  enabled: true
  targetUrl: https://example.com
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - example.org
    - example.net
    - www.example.org
    - www.example.net
  tls:
    - hosts:
        - example.org
        - example.net
        - www.example.org
        - www.example.net
      secretName: example-aliases-tls
```

**Path preservation differs by class**:

| Class | Resource emitted | Path-preserving? | Notes |
| --- | --- | --- | --- |
| `nginx` | `kind:Ingress` with `nginx.ingress.kubernetes.io/permanent-redirect` | **No** | Annotation issues a static-target 308; path is dropped. `https://www.example.org/foo?x=1` → `https://example.com/` |
| `nginx-traefik` | `kind:Middleware` (`redirectRegex` with capture group) + `kind:IngressRoute` (the IngressRoute itself sets `ingressClassName: traefik` regardless of the primary's class — only the chart's main Ingress goes through the bridge provider) | **Yes** | `https://www.example.org/foo?x=1` → `https://example.com/foo?x=1` |
| `traefik` | identical to `nginx-traefik` (the IngressRoute / Middleware shape is the same) | **Yes** | same as above |

When a cert-manager `cluster-issuer` annotation is set on the
`redirect:` block, the chart additionally emits a free-standing
`kind:Certificate` for the redirect hosts (cert-manager's ingress-shim
doesn't watch IngressRoute resources). The Certificate is owned only
by the Helm release — independent of any Ingress lifecycle, survives
chart upgrades.

> **Retired in 7.0.0-2**: the bitnami-compatible
> `nginx.ingress.kubernetes.io/from-to-www-redirect: "true"` annotation
> is no longer honoured. Use `redirect:` for the actual redirect
> (works on every class, supports arbitrary host lists, path-preserving
> on Traefik), and set `ingress.tlsWwwPrefix: true` separately when the
> primary cert should also cover the `www.` variant.

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

Only releases that require operator action are documented here. For the full release history (including routine maintenance / CVE rebuilds), see [CHANGELOG.md](./CHANGELOG.md).

### To 7.0.0-2

* **First-class Traefik support**: `ingress.ingressClassName: traefik`
  is now a fully supported steady-state value alongside `nginx` and
  `nginx-traefik`. See "Supported `ingressClassName` values" in the
  Ingress section for the per-class behaviour matrix (which provider
  serves the Ingress, whether nginx-style annotations are translated,
  silently ignored, or interpreted natively).

* **New**: `redirect:` values block (see Ingress → Redirects section
  above). Backwards-compatible — opt-in, defaults to disabled. Renders
  a `kind:Ingress` on `nginx` and a `kind:Middleware` +
  `kind:IngressRoute` (+ optional `kind:Certificate`) on
  `nginx-traefik` / `traefik`. **Note**: the `nginx`-path redirect
  drops the request path (annotation limitation); the Traefik-path
  redirect preserves it (`redirectRegex` with capture group).

* **Breaking**: the bitnami-compatible
  `nginx.ingress.kubernetes.io/from-to-www-redirect: "true"` annotation
  is no longer honoured. If you relied on it for cert expansion only,
  set `ingress.tlsWwwPrefix: true` (or
  `secondaryIngress.tlsWwwPrefix: true`). If you relied on it for the
  actual www-magic redirect, declare the redirect explicitly via the
  new `redirect:` block.

### To 7.0.0-1

Updates WordPress to 7.0.0. Review the [WordPress 7.0 release notes](https://wordpress.org/news/) for breaking changes before upgrading. No chart values changes required.

### To 6.9.4-13

Two nginx behavior fixes:

- Removes an overly restrictive method allow-list in the image's nginx config that returned `444` (TCP RST) for any method outside `GET` / `HEAD` / `POST`. This silently broke the WordPress REST API for `OPTIONS` (capability discovery + CORS preflights), `PUT`, `DELETE`, and `PATCH` — methods the Gutenberg block editor and most REST clients rely on. After upgrading, all HTTP methods reach PHP-FPM, and WordPress handles unsupported methods itself with proper `405 Method Not Allowed` responses.
- Fixes a dead `volumeMount` so that `nginxCustomServerBlockAddition` / `existingCustomServerBlockAdditionConfigMap` actually take effect. Previously the ConfigMap volume was declared in the Deployment but never mounted, so user-supplied server-block additions were ignored.

No values changes are required. If you use `existingCustomServerBlockAdditionConfigMap`, ensure the ConfigMap exposes its content under the key `01_userconfig.conf`.

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
