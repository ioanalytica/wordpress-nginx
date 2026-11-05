# Troubleshooting

Where to look when a release does not behave as configured. The deployment is
named `<release>-wordpress-nginx`; the examples use `my-wordpress`.

## A request for a PHP file is answered with 403

The [PHP execution allowlist](/security/php-execution-allowlist) executes PHP
only for WordPress's own entry points. A plugin that has callers request one
of its `.php` files directly needs an entry in
`phpExecutionAllowlist.extraAllowedPaths`. To see which requests are
concerned without blocking them, set `mode: report` and read the log:

```bash
kubectl logs deploy/my-wordpress-wordpress-nginx | grep '\[php-allowlist\]'
```

A 403 on `/healthz.php` is intended as well: NGINX answers the endpoint only
for requests that carry the kubelet probe's User-Agent, which keeps crawlers
and scanners off it. That is a filter on a request header, not access control.

## A change to the NGINX configuration has no effect

Changed values roll the pods on their own since 7.1.0-7. On an older version
the running pods keep the previous configuration until they are restarted;
see [Applying NGINX configuration changes](/operations/nginx-changes).

```bash
kubectl rollout restart deploy/my-wordpress-wordpress-nginx
```

## Mail is not sent

Without `smtpHost` every send fails and the container log says
`[mail error] SMTP_HOST is not defined`. With a relay that authenticates but
offers no TLS, sending fails unless `smtpProtocol: none` is set, because
credentials are otherwise sent with STARTTLS only. See [Mail](/features/mail).

## The page cache stops working after a restart

WordPress loads a page cache only while the constant `WP_CACHE` is true, and
the chart writes `wp-config.php` on every start, so a constant that a cache
plugin wrote there is gone. Set `wordpressWpCache: true`; see
[Cache](/features/cache#page-cache-and-wp-cache).

## W3 Total Cache is not configured

`wordpressConfigureCache` configures W3 Total Cache only where it is the
active caching plugin, and installs nothing. List the plugin in
`wordpressPreinstallPlugins` to have it installed and activated; see
[Plugins](/features/plugins).

## A preinstalled plugin is missing

The install downloads from wordpress.org. Without egress to
`downloads.wordpress.org` and `api.wordpress.org` the step logs a warning and
the pod starts without the plugin. Check the network policy and the log:

```bash
kubectl logs deploy/my-wordpress-wordpress-nginx | grep '\[preinstall-plugins\]'
```

## A directory a plugin protects with .htaccess is reachable

NGINX reads no `.htaccess`. The init container reports such files on every
start, with the `nginx.deniedPaths` entry that closes the directory:

```bash
kubectl logs deploy/my-wordpress-wordpress-nginx -c prepare-base-dir
```

[Denied paths and .htaccess](/security/denied-paths) explains the report's
classes.

## The pod does not start with `htaccessPolicy: fail`

That is the policy at work: a `.htaccess` that denies a directory is not
covered by `nginx.deniedPaths`. The init container's log (above) names the
file and proposes the entry.

## The search plugin stops offering updates

The plugin's server-side calls go to the sidecar over loopback. Where the
constant `WORDPRESS_IDX_BASE` was overridden to the public address and the pod
cannot reach that address, the calls fail without a message while the search
itself keeps working. See [Search index](/features/search-index).

## The file-integrity watcher reports a finding

Each finding names its rule in the `rule` label. To run one scan by hand and
read its metrics:

```bash
kubectl exec deploy/my-wordpress-wordpress-nginx-fim -- /usr/local/bin/php /fim/fim.php --scan-once
```

[File-integrity monitoring](/security/file-integrity-monitoring) lists what is
reported and how a legitimate change is baselined.

## Helm finds no version, or an upgrade stops arriving

Versions up to `7.1.4-7` were SemVer pre-releases, which Helm skips without
`--devel`, and a version range bounded to one WordPress patch release does not
match the versions of the current scheme. See
[Upgrading](/operations/upgrading#to-7-1-408).
