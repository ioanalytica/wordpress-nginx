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

The chart writes `wp-config.php` every time a pod starts, so a constant that
a plugin adds to the file is gone with the next pod. Set constants of your
own in `wordpressExtraConfigContent`, as PHP statements without an opening
tag; the generated file evaluates them before it loads WordPress:

```yaml
wordpressExtraConfigContent: |
  define('WP_POST_REVISIONS', 10);
```

The content reaches the container as the environment variable
`WORDPRESS_CONFIG_EXTRA`. Released chart versions up to 7.1.408 do not read
`wordpressExtraConfigContent`; there, set that variable yourself:

```yaml
extraEnvVars:
  - name: WORDPRESS_CONFIG_EXTRA
    value: |
      define('WP_POST_REVISIONS', 10);
```

An `extraEnvVars` entry of that name still takes precedence over the value.

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
containers run as the image defines. Switched on, they add what the image can
run with:

<!--@include: ../../chart/README.md#security-context-->

::: warning Released chart versions up to 7.1.408
There the defaults of `containerSecurityContext` were those of the Bitnami
chart (user 1001, `runAsNonRoot`, a read-only root filesystem, all
capabilities dropped), and a pod with `enabled: true` did not start. On such
a version, set `runAsUser: 0`, `runAsGroup: 0`, `runAsNonRoot: false`,
`readOnlyRootFilesystem: false` and `capabilities.drop: []` next to
`enabled: true`.
:::
