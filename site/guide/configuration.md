---
source: chart/README.md
editPage: true
---

# Configuration

The chart is configured through its values. Each one is described in
[`values.yaml`](https://github.com/ioanalytica/wordpress-nginx/blob/main/chart/values.yaml);
[Parameters](/reference/parameters) says which page covers which group. This
page covers the settings most sites change first.

## WordPress settings

<!--@include: ../../chart/README.md#wordpress-settings-->

The chart writes `wp-config.php` on every container start, so a constant that
a plugin adds to the file is gone after the next restart. The generated file
evaluates the environment variable `WORDPRESS_CONFIG_EXTRA`; set constants of
your own there, through `extraEnvVars`:

```yaml
extraEnvVars:
  - name: WORDPRESS_CONFIG_EXTRA
    value: |
      define('WP_POST_REVISIONS', 10);
```

## Persistence

The site's volume holds `wp-content`, the site's own `nginx.conf` and, with
the search sidecar, its index. By default the chart requests a 10Gi `ReadWriteOnce` volume from the cluster's
default storage class:

```yaml
persistence:
  enabled: true
  storageClass: ""        # "" = the cluster's default
  accessModes:
    - ReadWriteOnce
  size: 10Gi
  existingClaim: ""       # use a claim that already exists
```

## Resources

<!--@include: ../../chart/README.md#resources-->

The default is `resourcesPreset: "micro"`.

## Autoscaling

<!--@include: ../../chart/README.md#autoscaling-->

## Security context

Both security contexts are off by default (`enabled: false`), so the
containers run as the image defines. The values exist for clusters that
require them:

<!--@include: ../../chart/README.md#security-context-->

::: warning Test before relying on it
The chart's tests do not cover a release with the security contexts enabled.
The container security context applies to the init container as well, which
sets the owner of the files it creates on the volume, something a user other
than root is not allowed to do. Try such values on a fresh release first.
:::
