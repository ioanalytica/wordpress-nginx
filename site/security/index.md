# Security overview

What the chart and the image do for the security of a site, what is on
without a setting, what has to be switched on, and what the chart leaves to
other layers on purpose.

## On by default

| Measure | What it does | Setting |
|---|---|---|
| [PHP execution allowlist](/security/php-execution-allowlist) | NGINX executes PHP only for WordPress's own entry points. Any other `.php` request, a file written to `wp-content/uploads` above all, is answered with 403. | `phpExecutionAllowlist.mode: enforce` |
| Two-factor plugin | The [two-factor](https://wordpress.org/plugins/two-factor/) plugin is installed, activated and kept up to date, so every user can switch two-factor authentication on. It is available, not enforced. See [Plugins](/features/plugins). | `wordpressPreinstallPlugins` |
| `.htaccess` report | On every start the init container reports `.htaccess` files under `wp-content`: protections a plugin asked for that NGINX does not apply, and files that open a directory up. See [Denied paths and .htaccess](/security/denied-paths). | `nginx.htaccessPolicy: warn` |
| Credentials in Secrets | Database, cache and SMTP passwords reach the containers through environment variables sourced from Secrets. The cache password is never rendered into a ConfigMap, which the chart's template test checks. | |
| Cache password | The bundled Dragonfly always starts with a password. See [Cache](/features/cache). | `memcached.password` |
| Encrypted SMTP login | As soon as SMTP credentials are set, the connection uses STARTTLS unless told otherwise. See [Mail](/features/mail). | `smtpProtocol` |
| No service account token | The pod does not mount a service account token. | `automountServiceAccountToken: false` |

## Opt-in

| Measure | What it does | Setting |
|---|---|---|
| [Denied paths](/security/denied-paths) | NGINX refuses directories or URL patterns for every caller, before a location is chosen and before PHP is reached. A `honeypot` action answers 418 for paths that only a prober asks for. | `nginx.deniedPaths` |
| Strict `.htaccess` policy | The pod refuses to start while a directory that a plugin wants denied is still open. | `nginx.htaccessPolicy: fail` |
| [File-integrity monitoring](/security/file-integrity-monitoring) | A watcher reads the site's volume read-only and reports unexpected files, changed drop-ins and changed baselined files as Prometheus metrics. | `fim.enabled` |
| [REST API hardening](/security/rest-api-hardening) | NGINX answers 403 for anonymous requests that list the site's login names. The page says what this does not prevent, which is why it is off by default. | `restApiHardening.mode` |
| Restricted `wp-admin` | A second Ingress for `/wp-admin` with annotations of its own, for example a source range. See [Ingress and redirects](/features/ingress). | `secondaryIngress` |
| Network policy rules | The chart creates a NetworkPolicy, which by default admits any source to the pod's ports and allows all egress. `allowExternal: false` and `allowExternalEgress: false` narrow it; without external egress, add rules for what the site needs to reach, such as wordpress.org for plugin updates. | `networkPolicy` |

## Not covered

The pod and container security contexts are off by default, and a release
with them enabled is not part of the chart's tests; see
[Configuration](/guide/configuration#security-context) before enabling them.

## Left to other layers

- **Security response headers** belong on the ingress, next to TLS
  termination. [Security headers](/security/headers) gives the reasons and a
  policy to start from.
- **Enforcing two-factor authentication** is a decision per site; the chart
  makes it available and does not impose it.
- **Plugins and themes** are the site's own. By default the chart installs
  the two-factor plugin and nothing else; with `idx.enabled` it also installs
  the search plugin that belongs to the sidecar.

## Releases

How WordPress releases and package updates reach a chart release, and what
the daily image scan does and does not see, is described under
[Update policy](/security/update-policy). To report a vulnerability, see
[Report a vulnerability](/security/reporting).
