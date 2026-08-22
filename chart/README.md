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

### PHP Execution Allowlist

Since **7.1.0-2** NGINX only executes PHP for known WordPress entry points:
`index.php`, `wp-login.php`, `wp-cron.php`, `wp-comments-post.php`,
`wp-signup.php`, `wp-activate.php`, `wp-admin/*.php` and the chart's
`healthz.php` probe. Any other `.php` request — most importantly PHP files
written to `wp-content/uploads` — is answered with **403**.

Plugins and themes are not affected: their code is `include()`d by WordPress
and reached through the entry points above (front controller, `admin-ajax.php`,
REST API, cron). Only legacy plugins that expose their own direct-access `.php`
endpoints (typically files that bootstrap `wp-load.php` themselves) need an
explicit allow entry:

```yaml
phpExecutionAllowlist:
  mode: enforce            # enforce | report | off
  extraAllowedPaths:
    - '~*^/wp-content/plugins/myplugin/callback\.php$'
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `phpExecutionAllowlist.mode` | `enforce` blocks non-allowlisted PHP requests with 403, `report` only logs them, `off` disables the allowlist | `enforce` |
| `phpExecutionAllowlist.extraAllowedPaths` | Additional NGINX map regex patterns allowed to execute PHP | `[]` |

To validate an existing installation before enforcing, set `mode: report` and
watch the container logs for `[php-allowlist]` lines: each one shows a request
that `enforce` would have blocked. If nothing legitimate shows up after a
representative period, switch back to `enforce` (the default). To find plugins
that may need an allow entry up front:

```bash
grep -rl "wp-load\.php" wp-content/plugins/ --include="*.php"
```

### REST API and Author Enumeration Hardening

Since **7.1.0-4** NGINX answers **403** for anonymous requests that would reveal
the site's login names — half of a credential pair, and the opening move of
every automated login attack. WordPress exposes all of these to unauthenticated
callers by design:

- the `wp/v2/users` REST route, as `/wp-json/wp/v2/users` and as the
  `/?rest_route=/wp/v2/users` fallback that works with pretty permalinks off
- the author archive addressed by numeric id, `/?author=1`, which redirects to
  `/author/<login>/` and thereby maps an id to a name

Matching runs on the normalized path, so percent-encoding, duplicate slashes and
`.` segments do not get around it. The pretty author archive `/author/<slug>/`
is a legitimate public feature and stays reachable.

```yaml
restApiHardening:
  mode: enforce            # enforce | report | off
  extraDeniedPaths:
    - '~*^/wp-json/wp/v2/comments(/|\?)'
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `restApiHardening.mode` | `enforce` answers denied requests from anonymous callers with 403, `report` only logs them, `off` disables the check | `enforce` |
| `restApiHardening.extraDeniedPaths` | Additional NGINX map regex patterns to deny, matched against `"$uri?rest_route=$arg_rest_route&author=$arg_author"` | `[]` |

**Requests carrying a WordPress session cookie are exempt.** Without that
exemption the rules would also hit the block editor's author selector and the
author filter in the wp-admin posts list, both of which request the very URLs
the rules deny, from a logged-in browser. NGINX cannot tell those apart from a
scanner any other way — validating a WordPress session is beyond what the
reverse proxy can do.

Be clear about what the exemption is worth: the cookie is checked for presence,
not validated, so sending a made-up `wordpress_logged_in_` cookie gets past it.
It is the line between an automated scanner and a browser that has logged in,
which is the threat this feature addresses. Authorization that must hold against
a targeted attacker belongs in WordPress — a `rest_endpoints` filter requiring
the `list_users` capability — not in the reverse proxy.

To validate before enforcing, set `mode: report` and watch the container logs
for `[rest-hardening]` lines; each one is a request that `enforce` would have
refused:

```bash
kubectl logs deploy/<release>-wordpress-nginx | grep '\[rest-hardening\]'
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

### Security Response Headers

Security headers are **edge policy** and this chart deliberately does not set
them on the pod. They belong on the ingress, next to TLS termination and any
WAF: changing a header there needs no image rebuild and no pod restart, and
`Strict-Transport-Security` can only be set meaningfully by whatever terminates
TLS. The pod's own NGINX cannot serve as a single source of truth anyway —
`add_header` is not inherited into a location that defines any `add_header` of
its own, and the base image's asset locations do exactly that.

Set them through `ingress.annotations`, which is passed through verbatim. A
policy worth starting from:

```
Content-Security-Policy: frame-ancestors 'self'; base-uri 'self'; form-action 'self'; object-src 'none'
Referrer-Policy: strict-origin-when-cross-origin
Strict-Transport-Security: max-age=31536000; includeSubDomains
```

Those four CSP directives block clickjacking, `<base>` tag injection, form
exfiltration and plugin-object abuse without touching script loading, so they
do not break a normal WordPress site. Note what is missing: a `script-src`
without `'unsafe-inline'` is the directive that actually contains XSS, and
WordPress cannot satisfy it without nonces on every inline `<script>` — theme
or mu-plugin work, not something the ingress can add. A CSP that keeps
`'unsafe-inline'` looks like protection in a scanner report and provides none,
so it is better to ship the four directives above honestly than a permissive
`default-src` line.

**Traefik** (`ingressClassName: traefik` or `nginx-traefik`) — a `Middleware`
holding the headers, referenced from the Ingress. `customResponseHeaders`
replaces a header rather than appending to it, so this also cleanly overrides
the `Referrer-Policy` the base image emits:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: wordpress-security-headers
  namespace: my-namespace
spec:
  headers:
    customResponseHeaders:
      Content-Security-Policy: "frame-ancestors 'self'; base-uri 'self'; form-action 'self'; object-src 'none'"
      Referrer-Policy: "strict-origin-when-cross-origin"
    stsSeconds: 31536000
    stsIncludeSubdomains: true
```

```yaml
ingress:
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: my-namespace-wordpress-security-headers@kubernetescrd
```

**ingress-nginx** (`ingressClassName: nginx`) — a configuration snippet.
`more_set_headers` replaces rather than appends, same as above:

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/configuration-snippet: |
      more_set_headers "Content-Security-Policy: frame-ancestors 'self'; base-uri 'self'; form-action 'self'; object-src 'none'";
      more_set_headers "Referrer-Policy: strict-origin-when-cross-origin";
```

This requires **`allow-snippet-annotations: true`** in the ingress-nginx
controller ConfigMap. The controller has defaulted it to `false` since v1.9,
and it is a cluster-wide setting owned by the controller, not by this chart —
so on a hardened ingress-nginx the per-site route is closed and the only
built-in alternative is the controller-global `add-headers` ConfigMap, which
applies the same headers to every site behind that controller.

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

### To 7.1.0-4

NGINX now refuses the `wp/v2/users` REST route and numeric author archives
(`/?author=N`) with 403 for anonymous callers
(`restApiHardening.mode: enforce`). Username enumeration stops; the front end,
the login flow, wp-admin and the pretty `/author/<slug>/` archives are
unaffected, and requests carrying a WordPress session cookie are exempt so the
block editor and the wp-admin author filter keep working.

If your theme links author archives by numeric id rather than by slug, or a
plugin reads `?author=N` anonymously, set `restApiHardening.mode: report`
before upgrading and review the `[rest-hardening]` log lines.

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
