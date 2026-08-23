# Changelog

## 7.1.0-4

* `WP_CACHE` is now defined in the generated `wp-config.php`, controlled by the new `wordpressWpCache` value (`null` [default] follows `wordpressConfigureCache`, `true`/`false` set it explicitly). WordPress only loads `wp-content/advanced-cache.php` when this constant is true, so without it every page cache plugin degrades to no page caching. Those plugins normally write the constant themselves, which does not survive here: the chart regenerates `wp-config.php` on every container start, so a plugin-written constant was lost on the next restart or rollout.
* The bundled W3 Total Cache integration (`wordpressConfigureCache`) now configures the **page cache** as well. It previously set up only the database and object caches, both of which work through `object-cache.php` and need no constant — which is why the gap went unnoticed.
* New **opt-in** hardening, `restApiHardening.mode` (`off` [default] | `enforce` | `report`): NGINX answers 403 for anonymous requests that reveal the site's login names — the `wp/v2/users` REST route in both of its spellings (`/wp-json/wp/v2/users` and the `/?rest_route=/wp/v2/users` fallback), and the author archive addressed by numeric id (`/?author=1`). Matching runs on the normalized path, so percent-encoding, duplicate slashes and `.` segments do not get around it. `restApiHardening.extraDeniedPaths` adds further patterns; `report` mode logs would-be blocks as `[rest-hardening]` lines on container stderr without blocking.
* **No default changes in this release.** The feature is off unless you enable it, and it is off on purpose: the session-cookie exemption it needs in order not to break the block editor is satisfied by any forged cookie, and the same login names stay reachable through the pretty author archive and through oEmbed. It stops bulk automated enumeration and nothing more — worth having as an option, not worth a breaking default. The chart README documents the root-cause fix instead (decoupling `user_nicename` from `user_login`), which closes every channel and breaks nothing.
* When enabled, requests carrying a WordPress session cookie are exempt, so the block editor's author selector and the wp-admin posts-list author filter keep working. The pretty `/author/<slug>/` archive and ordinary REST author filters such as `/wp-json/wp/v2/posts?author=1` stay reachable.
* Added a chart template test (`chart/tests/template-test.sh`, wired into CI alongside `helm lint`) that renders the chart across a matrix of value combinations and checks structural invariants lint does not: that every ConfigMap a Deployment mounts is actually rendered, that every volumeMount refers to a declared volume, and that every `subPath` exists as a key in the mounted ConfigMap. This is the failure class behind the 7.1.0-2 server block regression — a mount for a resource the templates never create passes lint and leaves the pod stuck.
* Extended the smoke test with normalization variants for the PHP execution allowlist (percent-encoded extension and dot, duplicate slashes, `.` and `..` segments, uppercase extension, trailing dot). These assert that PHP is never executed rather than pinning a status code, so the test states the security property instead of today's behavior.
* Added a smoke test covering every route spelling, the encoding variants, numeric and non-numeric author arguments, REST author filters, the session-cookie exemption, the extra-deny patterns and all three modes.
* Documented how to set security response headers (CSP, `Referrer-Policy`, HSTS) on the ingress rather than on the pod, with recipes for Traefik and ingress-nginx. Documentation only — the chart adds no values for it. On ingress-nginx the snippet route needs `allow-snippet-annotations: true` in the controller ConfigMap, a cluster-wide setting the chart does not own.

## 7.1.0-3

* The `/healthz.php` readiness endpoint is now executed by PHP-FPM, so the probe genuinely verifies PHP-FPM, WordPress core and database connectivity. Previously NGINX served the file statically, and the readiness probe effectively only verified that NGINX itself was up.
* **Behavior change to be aware of**: a pod whose PHP stack or database is unavailable now fails its readiness probe and is taken out of the Service endpoints until the dependency recovers. Liveness is unaffected (it remains a plain TCP check), so pods are not restarted during a database outage.
* Extended the smoke test to assert that `/healthz.php` responses are rendered by PHP.
* The published container images now carry an `org.opencontainers.image.source` label, linking the GHCR packages to this repository.
* Added `docker/wpscan/`, a small Alpine image bundling WPScan for scanning self-hosted instances from inside the cluster (as an ephemeral debug container, so scans are not seen by an edge WAF). Both `docker-build.sh` scripts now take `--push`/`--no-push`, `-y` and `--cache`, lint the Dockerfile before building, and build multi-arch only when pushing — local builds produce a host-arch image loaded into the Docker daemon.

## 7.1.0-2

* Security hardening release. **Upgrading promptly is recommended for all installations.**
* NGINX now enforces a **PHP execution allowlist**: PHP is only executed for known WordPress entry points (`index.php`, `wp-login.php`, `wp-cron.php`, `wp-comments-post.php`, `wp-signup.php`, `wp-activate.php`, `wp-admin/*.php` and the `healthz.php` probe); every other `.php` request is answered with 403. The check runs as an `$uri` map plus a rewrite-phase guard, independent of location matching order. Plugins and themes are unaffected — their code is `include()`d by WordPress via the entry points above; only legacy plugins with direct-access `.php` endpoints need an explicit allow entry.
* New values: `phpExecutionAllowlist.mode` (`enforce` [default] | `report` | `off`) and `phpExecutionAllowlist.extraAllowedPaths` (additional NGINX map regex patterns). `report` mode logs would-be blocks as `[php-allowlist]` lines on container stderr without blocking — use it to validate existing installations before enforcing. See the chart README for details.
* Added a smoke test (`docker/tests/smoke-test.sh`, wired into CI) that asserts the allowlist blocks and allows the right URLs in all three modes.
* When upgrading, auditing the uploads directory for stray PHP files is good practice: `find wp-content/uploads -name '*.php'`.
* Fix: setting only `nginxCustomServerBlockAddition` did not render the server block addition ConfigMap (the `wordpress.nginx.createServerblockConfigmap` helper checked `nginxConfiguration` instead), while the Deployment still mounted it — leaving the pod stuck on a missing ConfigMap. The helper now checks `nginxCustomServerBlockAddition` and `existingCustomServerBlockAdditionConfigMap`.

## 7.1.0-1

* Update to WordPress 7.1. Review the [WordPress release notes](https://wordpress.org/news/) before upgrading.

## 7.0.4-1

* Update to WordPress 7.0.4. Review the [WordPress release notes](https://wordpress.org/news/) before upgrading.

## 7.0.3-2

* Add `idx.pluginAutoUpdate` (default `true`): when the wordpress-idx sidecar serves the bundled WordPress plugin, WordPress installs plugin updates automatically. Set to `false` to only surface updates in wp-admin. Passed to the sidecar as the `PLUGIN_AUTO_UPDATE` environment variable.
* Bump `idxImageTag` to `1.3.0`, the wordpress-idx image that serves the bundled plugin and its update manifest.

## 7.0.3-1

* Update to WordPress 7.0.3. Review the [WordPress release notes](https://wordpress.org/news/) before upgrading.

## 7.0.2-1

* Update to WordPress 7.0.2 (includes the 7.0.1 and 7.0.2 maintenance releases). Review the [WordPress release notes](https://wordpress.org/news/) before upgrading.

## 7.0.0-11

* Maintenance release: rebuild image to address CVEs (incl. ImageMagick 7.1.2.27-r0).
* Fix: bump `imageTag` annotation so the rebuilt image is actually deployed (it was still pinned to 7.0.0-9).

## 7.0.0-10

* Maintenance release: rebuild image to address CVEs.

## 7.0.0-9

* Maintenance release: rebuild image to address CVEs.

## 7.0.0-8

* Maintenance release: rebuild image to address CVEs.

## 7.0.0-7

* Maintenance release: rebuild image to address CVEs.

## 7.0.0-6

* Maintenance release: update wordpress-idx image to 0.1.11 to address CVEs.

## 7.0.0-5

* Maintenance release: rebuild image to address CVEs in base images.

## 7.0.0-4

* Maintenance release: rebuild image to address CVEs.

## 7.0.0-3

* Maintenance release: rebuild image to address CVEs.

## 7.0.0-2

* **Maintenance**: `imageTag` / `idxImageTag` annotations bumped in
  lockstep with the chart version (chart convention is that the
  application image tag and the chart version always match). For this
  release the image content is unchanged from 7.0.0-1 — a rebuild +
  retag is required as part of the release pipeline.

* **First-class Traefik support**. The chart's primary Ingress now
  renders correctly under all three supported values of
  `ingress.ingressClassName`:
  - `nginx`: served by `rke2-ingress-nginx` (or upstream
    ingress-nginx) — the legacy path; nginx-style annotations are
    interpreted directly by the controller.
  - `nginx-traefik`: served by Traefik's `kubernetesIngressNGINX`
    bridge provider, which reads the same `kind:Ingress` and translates
    most nginx-style annotations into Traefik's internal middleware
    chain on the fly (proxy-body-size, whitelist-source-range,
    auth-url, backend-protocol, cors-*, etc.). Useful as a transition
    class — same Ingress manifest works on both controllers.
  - `traefik`: served by Traefik's native `kubernetesIngress`
    provider. nginx-style annotations are silently ignored; the user
    is expected to manage behaviour via Traefik annotations
    (`traefik.ingress.kubernetes.io/router.middlewares: …`,
    `service.serversscheme: …`) and Middleware CRDs. This is the
    target steady state after the nginx→Traefik migration.

* **New feature**: chart-rendered redirect support via the `redirect:`
  block. Emits the right resource shape per `ingress.ingressClassName`:
  - `nginx`: one `kind:Ingress` with
    `nginx.ingress.kubernetes.io/permanent-redirect` (cert-manager
    ingress-shim manages the cert).
  - `nginx-traefik` / `traefik`: one `kind:Middleware` (RedirectRegex
    with capture group → path-preserving 308) + `kind:IngressRoute`
    matching all `redirect.hosts`, plus a free-standing
    `kind:Certificate` if
    `redirect.annotations["cert-manager.io/cluster-issuer"]` is set.

  Unlike the retired `from-to-www-redirect` annotation (which only
  toggled nginx-ingress's built-in www-magic), the new block supports
  any set of source hostnames in one declaration — vanity domains,
  backup TLDs, multiple www variants. See the README "Redirects"
  section for an example covering apex + www across multiple TLDs.

  All chart-emitted redirect resources (Ingress on `nginx`; Middleware
  + IngressRoute + Certificate on `nginx-traefik`/`traefik`) inherit
  the top-level `commonAnnotations` and the `redirect.annotations`
  overrides — same convention as the primary Ingress.

  **Path preservation matrix** (different by design):
  - `nginx`: redirect **drops** the request path. Limitation of
    nginx-ingress's `permanent-redirect` annotation — it issues a
    static-target 308 with no path interpolation.
    `https://www.example.org/foo?x=1` → `https://example.com/`
  - `nginx-traefik` / `traefik`: redirect **preserves** path AND
    query string. The chart emits a `Middleware` with `redirectRegex`
    (`^https?://[^/]+(/.*)?$` → `<target>${1}`, `permanent: true`),
    which produces a 308 with the captured path appended.
    `https://www.example.org/foo?x=1` → `https://example.com/foo?x=1`

* **BREAKING / retired**: the bitnami-compatible
  `nginx.ingress.kubernetes.io/from-to-www-redirect: "true"` annotation
  is no longer honoured by the chart. It previously had two effects:
  (1) triggered nginx-ingress's built-in www-magic redirect — a feature
  that doesn't translate to Traefik anyway; (2) expanded the primary
  TLS host list to also cover `www.<hostname>`.

  **Migration path**:
  - For the cert-expansion side effect: set `ingress.tlsWwwPrefix: true`
    (already existed as a first-class flag, just the annotation
    fallback was removed).
  - For the actual www→apex (or apex→www) redirect: use the new
    `redirect:` block. It works across all three IngressClasses and
    supports arbitrary source hostnames in one declaration.

## 7.0.0-1

* Update to WordPress 7.0.0.

## 6.9.4-15

* Maintenance release: rebuild image to address CVEs.

## 6.9.4-14

* Maintenance release: rebuild image to address CVEs.

## 6.9.4-13

* Remove overly restrictive nginx method allow-list (`if ($request_method !~ ^(GET|HEAD|POST)$) { return 444; }`) that broke the WordPress REST API for `OPTIONS`, `PUT`, `DELETE`, `PATCH` — these are required by the Gutenberg block editor and other REST API clients.
* Fix `nginxCustomServerBlockAddition` / `existingCustomServerBlockAdditionConfigMap`: the ConfigMap volume was declared in the Deployment but never mounted into the nginx container, so any user-supplied server-block content was silently ignored. The ConfigMap is now mounted at `/etc/nginx/custom.d/01_userconfig.conf` via `subPath` so the image's baked-in `02-userconfig.conf` remains visible.
* Document in `values.yaml` that `existingCustomServerBlockAdditionConfigMap` must expose its content under the key `01_userconfig.conf`.

## 6.9.4-12

* Update wordpress-idx image to 0.1.10

## 6.9.4-11

* Update wordpress-idx image to 0.1.9

## 6.9.4-5

* Migrate to GitHub and ghcr.io
* Rewrite README, remove Bitnami branding
* Update Chart.yaml with IO ANALYTICA attribution
* Add GitHub Actions for Docker image build

## 6.9.4-4

* Version bump

## 6.9.4-3

* Version bump

## 6.9.4-2

* Version bump

## 6.9.4-1

* Update to WordPress 6.9.4

## 6.9.1-7

* Update wordpress-idx image tag

## 6.9.1-6

* Fix default image tags

## 6.9.1-5

* Allow idx port in NetworkPolicy

## 6.9.1-4

* Fix idx OOM and probe split
