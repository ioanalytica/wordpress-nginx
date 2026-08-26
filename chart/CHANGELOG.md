# Changelog

## 7.1.0-9

* **Fix: post-init scripts never executed.** The Deployment mounted the post-init ConfigMap as a directory at `/etc/hook/application/…`, while the image's hook runner executes `/etc/hooks/<hook>` (plural) — and its `run-parts` invocation neither descends into subdirectories nor runs non-executable files, so even the correct path would not have executed a directory mount. `customPostInitScripts` and the `wordpressConfigureCache` W3 Total Cache configuration (introduced in 7.1.0-5) have therefore never run. Scripts are now mounted as single files (`/etc/hooks/application/zz-<name>`, mode 0750 — the hook runs as root, nothing else needs the bits) with a `checksum/postinit` rollout annotation; the smoke test pins the image-side execution contract and the template test pins the mount shape. **After upgrading, the first rollout executes these scripts for the first time** — the next two items define what that means.
* **Behavior change: `wordpressConfigureCache` configures W3 Total Cache only when it is the active caching plugin.** It no longer activates it (and never installs it): sites that set the value but run a different caching plugin would otherwise get a second page cache activated on the first rollout that actually executes the script, with both fighting over the `advanced-cache.php`/`object-cache.php` drop-ins. On such sites the script now logs `[configure-cache] w3-total-cache is not active` and exits. To install and activate W3TC declaratively, list it in `wordpressPreinstallPlugins`. Where W3TC **is** active, the chart's engine/server/password settings are (re)applied on every container start — verify after the first rollout that they match expectations, since they have never been applied by the chart before.
* New `wordpressPreinstallPlugins`: plugins the pod installs, activates and sets to auto-update, idempotently on every container start. **Default: [two-factor](https://wordpress.org/plugins/two-factor/)** — given the constant credential-stuffing against WordPress accounts, two-factor authentication should at least be available everywhere. Activation makes 2FA available per user; it does not enforce it (enforcement via the plugin's `two_factor_*` filters remains a deliberate per-site step). The install needs egress to wordpress.org; without it the step logs and skips, never blocking the pod. Set `wordpressPreinstallPlugins: []` to opt out.
* `customPostInitScripts` accepts `.sh` scripts only, and templating fails loudly on other extensions — the previously documented `.sql`/`.php` support was never real in this image. The scripts run on every container start (the old "1st boot" wording was misleading), so they must be idempotent.

## 7.1.0-8

* New `redirect.goneHosts`: retired hostnames whose content no longer exists anywhere. Crawlers (matched by User-Agent keywords, including an empty User-Agent) are answered **410 Gone on every path** of such a host — the signal to drop the URLs and stop recrawling — while browsers get a courtesy 301 to `targetUrl`'s root (deliberately not path-preserving: the old paths do not exist at the target). This complements `redirect.hosts`, which stays the right choice for aliases whose content lives on at `targetUrl` — there, everyone including crawlers should follow the redirect so search engines consolidate onto the canonical name.
* Gone hosts are routed to the backend through the primary Ingress (with an automatic ingress-shim TLS entry when the Ingress carries a cert-manager issuer annotation) instead of through the controller-level redirect resources, and NGINX answers in the rewrite phase — **ahead of the PHP execution allowlist**. This matters: a host-based `return 410` in `nginxCustomServerBlockAddition` never fires for `.php` paths, because the allowlist answers 403 first — exactly the URLs a crawler replaying a dead site keeps requesting, and a 403 reads as "temporarily forbidden", so it never stops. `deniedPaths` still ranks first, so a `honeypot` path keeps answering 418 on a retired host.
* `redirect.enabled` with an empty `redirect.hosts` list is now valid as long as `redirect.goneHosts` has an entry; no controller-level redirect resources are emitted in that case.
* Extended the image smoke test (crawler/browser/empty-UA matrix, allowlist and honeypot precedence, `hostnames` suffix entries) and the chart template test (map rendering, checksum, primary-Ingress routing, no leakage into the redirect resources).
* Bump `idxImageTag` to `1.3.1` (wordpress-idx sidecar). Image availability on GHCR verified before the bump.

## 7.1.0-7

* **Fix: an empty or comments-only `.htaccess` under `wp-content` stopped the pod from starting.** The init container runs with `set -e`, and the filter that strips comments from a `.htaccess` exits non-zero when nothing is left — aborting the init script whatever `nginx.htaccessPolicy` is set to. Any plugin leaving such a file behind would have taken the site down on the next roll. Such files are now reported as "empty or only comments — no access control at all". Affects 7.1.0-6 only; upgrade if you are on it.
* **Fix: changes to NGINX configuration values never reached running pods.** The four NGINX ConfigMaps (`nginxConfiguration`, `nginxCustomServerBlockAddition`, `phpExecutionAllowlist`, `restApiHardening`, `nginx.deniedPaths`) are mounted with `subPath`, and a `subPath` mount never receives ConfigMap updates — the kubelet projects the file once at container start. With the Deployment spec unchanged, no rollout happened, and pods kept serving the previous configuration with nothing to indicate it. The pod template now carries a checksum annotation per ConfigMap, so any value change rolls the pods; identical values keep the checksum stable, so no pod is restarted needlessly.

## 7.1.0-6

* The init container's `.htaccess` report now classifies files by content instead of proposing `deny` for every one. The first version did that, and on a real site three of seven proposals were wrong: W3 Total Cache's `pub/.htaccess` guards PHP execution and wants its admin assets served (a directory deny broke the W3TC admin UI), Contact Form 7's captcha directory denies everything except its images (a directory deny breaks the captcha), and an `.htaccess` that says `allow from all` for `.php` in an upload directory is not a protection at all — it is the usual companion of a webshell, and is now flagged **SUSPICIOUS** rather than covered up by a deny. Directories that already have a `location` or `rewrite` in the site's `/wordpress/nginx.conf` — W3 Total Cache writes its own NGINX rules there — are reported as plugin-managed; a `deniedPaths` entry would override those rules. Under `htaccessPolicy: fail` only an uncovered blanket deny blocks the start. Listing a deny-with-exceptions directory in `deniedPaths` now produces a warning.
* Added `docker/tests/htaccess-test.sh`, wired into CI: it runs the check in busybox against a `wp-content` tree rebuilt from the real files found on that site.

## 7.1.0-5

* **Fix: the chart now deploys its own image.** 7.1.0-4 bumped the chart `version` but not the `imageTag` annotation in `Chart.yaml`, which is the single source for the image tag — so the 7.1.0-4 chart deployed the 7.1.0-3 image. In the default configuration nothing was visibly wrong; with `restApiHardening.mode` set to `enforce` or `report`, the mounted configuration referenced an NGINX variable that only the 7.1.0-4 image defines, and NGINX would have refused to start. If you are on 7.1.0-4 and enabled REST hardening, upgrade. The chart template test now fails when `version`, `imageTag` and the `images` annotation disagree, or when the rendered image tag differs from the chart version.
* New `nginx.deniedPaths`: directories or URL patterns NGINX refuses for every caller, declared in values, rendered into a ConfigMap and enforced in the rewrite phase — ahead of location matching and ahead of the PHP execution allowlist. `action: deny` answers 403, `action: honeypot` answers 418 (useful with a CrowdSec teapot-ban scenario: probers of a known-removed backdoor ban themselves). A plain `location /dir { deny all; }` in the per-site `nginx.conf` does **not** achieve this: it loses to the static-file regex location for `zip|doc|xls|…`, and can never produce a honeypot status on a `.php` path. Default is an empty list; nothing changes unless you add entries.
* New `nginx.htaccessPolicy` (`warn` [default] | `fail`): the init container now reports `.htaccess` files under `wp-content` on every start — NGINX never reads them, so a plugin-written `deny from all` protects nothing and says nothing — together with the `deniedPaths` entry that would close the directory. `fail` refuses to start while any such directory is not covered.
* The Prometheus exporter moved from `bitnami/nginx-exporter` to NGINX's own **`nginx/nginx-prometheus-exporter:1.5.3`**. Bitnami withdrew the versioned tags from `bitnami/*` — only `latest` remains there — so the pinned `1.4.1-debian-12-r5` could no longer be pulled and `metrics.enabled: true` ended in `ImagePullBackOff`. The new image is distroless, its entrypoint is the exporter binary (the chart's `command: [exporter]` override is gone) and it runs as `1001:1001`; `--nginx.scrape-uri` and `--web.listen-address` are the same upstream flags as before, so `metrics.extraArgs` carries over. If you pin a Bitnami image via `metrics.image`, note that those images need the command override this chart no longer sets.
* Added a weekly workflow tracking the pinned `nginx-prometheus-exporter` and `wordpress-idx` versions, opening a bump PR when a newer one appears. It pulls the candidate image before opening the PR, because a release tag existing does not mean the image was published.
* Dragonfly is bumped to **v1.40.1** and now pulled from the project's own registry, `docker.dragonflydb.io/dragonflydb/dragonfly`. The previous reference `dragonflydb/dragonfly:v1.26.0` had no registry prefix and therefore resolved to Docker Hub, where that tag does not exist — `memcached.enabled: true` ended in `ImagePullBackOff`. The Docker Hub namespace of that name is not where the project publishes; the vanity domain fronts ghcr.io, and both serve the same digest. Verified that v1.40.1 still accepts `--requirepass` and `--memcached_port` and comes up on both ports with the flags the chart passes.
* Added a weekly workflow that tracks upstream Dragonfly releases and opens a bump PR, mirroring the existing WordPress tracker. It only proposes a bump after checking that the new image still accepts those two flags and starts with them, so a release that drops either fails the workflow instead of producing a PR that breaks the cache.
* The cache password now reaches W3 Total Cache. The bundled Dragonfly starts with `--requirepass` and its password is managed by the chart, but the post-init script configured only the server addresses — so with `externalCache.type: redis` the plugin connected to an authenticated cache without credentials. All three caches now receive it.
* New values `externalCache.password`, `externalCache.existingSecret` and `externalCache.existingSecretPasswordKey`: an external Redis with `requirepass` could not be used at all before. The password is passed through an environment variable sourced from a Secret and is never rendered into the post-init ConfigMap; the chart template test enforces that with a sentinel value.
* `WP_CACHE` is now defined in the generated `wp-config.php`, controlled by the new `wordpressWpCache` value (`null` [default] follows `wordpressConfigureCache`, `true`/`false` set it explicitly). WordPress only loads `wp-content/advanced-cache.php` when this constant is true, so without it every page cache plugin degrades to no page caching. Those plugins normally write the constant themselves, which does not survive here: the chart regenerates `wp-config.php` on every container start, so a plugin-written constant was lost on the next restart or rollout.
* The bundled W3 Total Cache integration (`wordpressConfigureCache`) now configures the **page cache** as well. It previously set up only the database and object caches, both of which work through `object-cache.php` and need no constant — which is why the gap went unnoticed.

## 7.1.0-4

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
