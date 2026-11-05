# Metrics

With `metrics.enabled` the pod gets a sidecar running the
[NGINX Prometheus exporter](https://github.com/nginx/nginx-prometheus-exporter).
It reads NGINX's status page over loopback and serves the result as
Prometheus metrics on port 9113, through a Service of its own.

```yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true     # needs the Prometheus Operator
```

| Parameter | Description | Default |
|---|---|---|
| `metrics.enabled` | Run the exporter sidecar | `false` |
| `metrics.image.registry`, `.repository`, `.tag` | The exporter image | `docker.io`, `nginx/nginx-prometheus-exporter`, a pinned tag |
| `metrics.port` | Port of NGINX's status page; empty is the HTTP container port | `""` |
| `metrics.extraArgs` | Further arguments for the exporter | `[]` |
| `metrics.containerPorts.metrics` | The exporter's container port | `9113` |
| `metrics.service.port` | The metrics Service's port | `9113` |
| `metrics.service.annotations` | Annotations of the metrics Service | `prometheus.io/scrape: "true"` and the port |
| `metrics.resourcesPreset`, `metrics.resources` | The sidecar's resources | `nano` |
| `metrics.serviceMonitor.enabled` | Create a ServiceMonitor for the Prometheus Operator | `false` |
| `metrics.serviceMonitor.namespace`, `.labels`, `.jobLabel`, `.interval`, `.scrapeTimeout`, `.relabelings`, `.honorLabels` | Settings of the ServiceMonitor | |

The chart's NetworkPolicy, which is on by default, does not list the
exporter's port. Where the cluster enforces network policies, admit the
scrape, and only from where Prometheus runs; here that is the namespace
`monitoring`:

```yaml
networkPolicy:
  extraIngress:
    - ports:
        - port: 9113
      from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
```

Without the Prometheus Operator, the Service's `prometheus.io/scrape`
annotations let a Prometheus that discovers targets by annotation find the
exporter.

The exporter reports on NGINX: connections and requests. Findings on the
site's files are a separate set of metrics, from the
[file-integrity watcher](/security/file-integrity-monitoring), which has a
ServiceMonitor and alert rules of its own.
