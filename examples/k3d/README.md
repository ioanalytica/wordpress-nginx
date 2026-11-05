# Try it locally

The chart in a throwaway [k3d](https://k3d.io) cluster on one machine, with
nothing outside it: WordPress on NGINX, the bundled MariaDB, the full-text
search sidecar and the file-integrity watcher. It takes about two minutes,
most of them for pulling the images (about 430 MB). Tested with k3d 5.9 and
k3s 1.36.

> **A cluster to try the chart in.** The site's files and its database live
> in the k3d node container and are gone with the cluster. The site is served
> over plain HTTP on `localhost`. Nothing here is a setup to keep.

| Part | What it does here |
| --- | --- |
| WordPress | NGINX and PHP-FPM in one container; installs itself on the first start, with a generated admin password |
| MariaDB | the chart's bundled database, with generated passwords |
| Search sidecar | wordpress-idx, a container in the WordPress pod; indexes posts and pages and serves a search API under `/idx` |
| File-integrity watcher | a pod of its own that mounts the site's volume read-only and scans it every two minutes |
| Traefik | ships with k3s; routes `http://localhost:8080` to WordPress and `/idx` to the search sidecar |

## What you need

- Docker, with about 2 GB of memory to spare
- [k3d](https://k3d.io), `kubectl` 1.35 or later, [Helm](https://helm.sh) 3.8
  or later, `curl` and `openssl`
- port 8080 free on the host

## 1. A cluster

```sh
k3d cluster create wordpress-nginx --image rancher/k3s:v1.37.1-k3s1 -p "127.0.0.1:8080:80@loadbalancer"
```

The image is the k3s this page is tested with; without it, the k3s depends on
how k3d was built. `-p` maps port 8080 of the host to port 80 of the
cluster's load balancer, where Traefik listens, and binds it to the loopback
address: the site is reachable from this machine only. k3d makes
`k3d-wordpress-nginx` the current `kubectl` context.

## 2. Install

```sh
url=https://raw.githubusercontent.com/ioanalytica/wordpress-nginx/main/examples/k3d
helm install demo oci://ghcr.io/ioanalytica/charts/wordpress-nginx \
  --namespace wordpress --create-namespace \
  -f $url/values.yaml \
  --set idx.reindexApiKey="$(openssl rand -hex 16)"
```

Without `--version`, Helm installs the latest release. The values file holds
what k3d needs and switches the two optional features on:

| Value | Why |
| --- | --- |
| `service.type: ClusterIP` | the chart's default is a LoadBalancer Service on ports 80 and 443, which on k3s belong to Traefik |
| `ingress.*` | an Ingress of class `traefik` for the host `localhost` |
| `idx.enabled` | the search sidecar |
| `fim.enabled` | the file-integrity watcher |
| `fim.allowedComponentRootFiles` | accepts `hello.php`, the Hello Dolly plugin that WordPress ships as a loose file in `wp-content/plugins/` |

The file sets no password. The chart generates the WordPress and MariaDB
passwords and keeps them in the release's Secret, and the command above
generates the key that protects the search index's reindex endpoint. The
volumes need no setting: the chart asks for `ReadWriteOnce`, which is what
k3s's `local-path` storage offers.

Wait until WordPress, the watcher and Traefik are ready:

```sh
kubectl -n wordpress rollout status deployment/demo-wordpress-nginx --timeout=10m
kubectl -n wordpress rollout status deployment/demo-wordpress-nginx-fim --timeout=10m
kubectl -n kube-system wait --for=create deployment/traefik --timeout=5m
kubectl -n kube-system rollout status deployment/traefik --timeout=5m
```

The WordPress pod is ready once WordPress is installed and the search sidecar
has built its index. k3s installs Traefik in the background after the cluster
has started; by now it is usually there, and the last two lines return at
once.

## 3. The site and the login

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/
```

```
200
```

Open `http://localhost:8080` in a browser. To sign in, go to
`http://localhost:8080/wp-login.php`; the user is `user`, and the generated
password is in the release's Secret:

```sh
kubectl -n wordpress get secret demo-wordpress-nginx -o jsonpath='{.data.wordpress-password}' | base64 -d; echo
```

The chart has installed and activated two plugins: Two Factor, which lets
each user add a second factor in their profile, and the search plugin of the
sidecar:

```sh
kubectl -n wordpress exec deployment/demo-wordpress-nginx -c wordpress -- \
  wp plugin list --status=active --field=name
```

```
two-factor
wordpress-idx-search
```

## 4. Search

The sidecar has indexed what a new WordPress comes with, one post and one
page:

```sh
curl -s 'http://localhost:8080/idx/api/stats'; echo
curl -s 'http://localhost:8080/idx/api/search?q=welc&type=post&context=true'; echo
```

```
{"total":2,"posts":1,"pages":1,"words":170,"characters":943, …}
{"total":1,"results":[{"id":1,"type":"post","author":"user","title":"Hello world!", … "content":"Welcome to WordPress. This is your first post. Edit or delete it, then start writing!", …}]}
```

The search matches word beginnings in the text of posts, pages and, when
asked, comments: `welc` finds "Welcome". The output is shortened here; dates
differ.

Write a post, rebuild the index and find the post. The reindex endpoint takes
the key that the install command generated:

```sh
kubectl -n wordpress exec deployment/demo-wordpress-nginx -c wordpress -- \
  wp post create --post_status=publish --post_author=1 --post_title="Notes from k3d" \
  --post_content="Traefik routes the requests and MariaDB keeps the posts."
key=$(kubectl -n wordpress get secret demo-wordpress-nginx-idx -o jsonpath='{.data.idx-reindex-api-key}' | base64 -d)
curl -s -X POST -H "X-Api-Key: $key" http://localhost:8080/idx/api/reindex; echo
curl -s 'http://localhost:8080/idx/api/search?q=traef&context=true'; echo
```

```
Success: Created post 4.
{"status":"ok","entries":3}
{"total":1,"results":[{"id":4,"type":"post","author":"user","title":"Notes from k3d", … "content":"Traefik routes the requests and MariaDB keeps the posts.", …}]}
```

The post's id can differ. In wp-admin, the same rebuild is a button under
Settings, once the key is entered there.

## 5. File-integrity monitoring

The watcher scans the site's volume every two minutes and reports what it
finds as Prometheus metrics. A scan by hand prints the same metrics:

```sh
kubectl -n wordpress exec deployment/demo-wordpress-nginx-fim -- \
  /usr/local/bin/php /fim/fim.php --scan-once | grep '^wp_fim_violation'
```

```
wp_fim_violations 0
```

No findings on a new installation. The watcher judges by structure, not by
known file names: an executable file where uploads go, a loose file among the
plugins, a `mu-plugins` directory, a changed `wp-config.php`.

## 6. A PHP file under uploads

`wp-content/uploads` is where WordPress stores what users upload, and where
a PHP file has no business. Put one there, next to a text file, and request
both:

```sh
kubectl -n wordpress exec deployment/demo-wordpress-nginx -c wordpress -- sh -ec '
  cd /var/www/html/wp-content/uploads
  echo "<?php echo 6 * 7;" > demo.php
  echo "a text file" > demo.txt'
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/wp-content/uploads/demo.php
curl -s http://localhost:8080/wp-content/uploads/demo.txt
```

```
403
a text file
```

NGINX serves the text file and refuses the PHP file: it runs PHP only for
WordPress's own entry points (`phpExecutionAllowlist`), and logs each request
it refuses:

```sh
kubectl -n wordpress logs deployment/demo-wordpress-nginx -c wordpress | grep -F '[php-allowlist]'
```

```
[php-allowlist] 403 10.42.0.1 "GET /wp-content/uploads/demo.php HTTP/1.1" ref="-" ua="curl/8.7.1"
```

The address and the curl version differ. The file was not run, but it should
not be there either, and the watcher says so:

```sh
kubectl -n wordpress exec deployment/demo-wordpress-nginx-fim -- \
  /usr/local/bin/php /fim/fim.php --scan-once | grep '^wp_fim_violation'
```

```
wp_fim_violation{path="wp-content/uploads/demo.php",rule="php-in-writable-dir"} 1
wp_fim_violations 1
```

In a cluster with Prometheus, `fim.serviceMonitor` scrapes these metrics and
`fim.prometheusRule` raises an alert on a finding. Remove the files, and the
next scan is clean again:

```sh
kubectl -n wordpress exec deployment/demo-wordpress-nginx -c wordpress -- \
  rm /var/www/html/wp-content/uploads/demo.php /var/www/html/wp-content/uploads/demo.txt
kubectl -n wordpress exec deployment/demo-wordpress-nginx-fim -- \
  /usr/local/bin/php /fim/fim.php --scan-once | grep '^wp_fim_violation'
```

```
wp_fim_violations 0
```

## Clean up

```sh
k3d cluster delete wordpress-nginx
```

This deletes the node container with everything in it, the site, its database
and the pulled images included, and the `kubectl` context.

## When it hangs

| What you see | Why, and what to do |
| --- | --- |
| `k3d cluster create` fails with `port is already allocated` | another program listens on port 8080. Take another port in `-p`, `127.0.0.1:8081:80@loadbalancer` say, and use it in the URLs of this page |
| `curl` prints `404` right after the install | Traefik is up, but has not read the Ingress yet. Try again after a few seconds |
| The WordPress pod stays at `1/2` ready for a minute | nothing is wrong: the search sidecar waits 30 seconds before it reads the database, and reports ready once its index is built |
| The WordPress pod is not ready, and `kubectl -n wordpress logs deployment/demo-wordpress-nginx -c wordpress` says `Waiting for the database` | nothing is wrong: MariaDB initializes its data directory on the first start, and WordPress installs itself once it answers |
| The WordPress pod's log has a warning about a plugin download | the pod installs the Two Factor plugin from wordpress.org on its first start and needs to reach it; without it the pod starts all the same |

## From here to a real cluster

- **A version.** `--version` pins the chart, and with it the image: the chart
  version is the image tag.
- **A hostname and TLS.** `ingress.hostname` with your domain, `ingress.tls`
  and `wordpressScheme: https`; the Ingress classes `nginx`, `nginx-traefik`
  and `traefik` are supported.
- **Secrets.** `existingSecret`, `mariadb.auth.existingSecret` and
  `idx.existingReindexApiKeySecret` instead of generated passwords and a key
  on the command line.
- **The database.** The bundled MariaDB is a single instance without
  backups. `externalDatabase.*` with `mariadb.enabled: false` uses one you
  run yourself.
- **Storage.** More than one WordPress replica needs a `ReadWriteMany`
  volume (`persistence.accessModes`).
- **Monitoring.** `fim.serviceMonitor` and `fim.prometheusRule` for the
  watcher, `metrics.enabled` for NGINX.
- **Hardening beyond the defaults.** `restApiHardening`, `nginx.deniedPaths`
  and a `fim.baseline` for files that must not change.
