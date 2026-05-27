# Changelog

## 7.0.0-2

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
