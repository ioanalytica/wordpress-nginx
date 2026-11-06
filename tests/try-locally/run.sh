#!/bin/bash
# The page "Try it locally" (examples/k3d/README.md) end to end: a k3d
# cluster and every shell block of the page, in the page's order, with the
# values file of this checkout in place of its raw URL. Where the page shows
# the output of a block, the run compares it; where the page sends the reader
# to a browser, the run signs in with curl and uploads a file. Before the
# clean-up it installs a second release whose database is away at the first
# start, and expects WordPress to wait for it and to install itself then.
#
#   tests/try-locally/run.sh                      # the latest release, as the page installs it
#   tests/try-locally/run.sh ./chart              # the chart of this checkout
#   tests/try-locally/run.sh --import IMAGE DIR   # ... with an image built locally
#
# A chart directory is installed with the images it names, which must be in
# the registry. --import takes an image of this project from the local
# Docker daemon instead, the WordPress image or the search sidecar's, and
# can be given for both: the image is loaded into the cluster's node, and
# the release must not pull it (image.pullPolicy=Never, or
# idx.image.pullPolicy=Never for the sidecar), so the run cannot fall back
# to the registry's image of the same name. That is how a pull request tests
# an image that is not published yet, or one it changes.
#
# Creates the page's k3d cluster and deletes it with the page's own clean-up
# command; KEEP_CLUSTER=1 keeps it. Refuses to start when a cluster of that
# name exists. kubectl and helm use a kubeconfig of the run's own, so no
# other cluster is reachable from here. Needs docker, k3d, kubectl, helm,
# curl and openssl, and the page's port free on the host.

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fail MESSAGE - end the run with MESSAGE; the exit trap reports and cleans up.
fail() { echo "FAIL: $*" >&2; exit 1; }

# block HEADING N - the page's Nth shell block under HEADING, localized.
block() {
  local code
  code="$(page_block "$1" sh "$2" | localize "$CHART" "$HELM_EXTRA")"
  [ -n "$code" ] || { echo "FAIL: the page has no shell block $2 under '$1'" >&2; return 1; }
  if grep -qF "$PAGE_URL" <<<"$code" || { [ -n "$CHART" ] && grep -qF "$PAGE_CHART" <<<"$code"; }; then
    echo "FAIL: block $2 under '$1' still names the page's URL or chart:" >&2
    echo "$code" >&2
    return 1
  fi
  printf '%s\n' "$code"
}

# show HEADING N CODE - the block as the log shows it, after how many
# seconds of the run.
show() {
  echo "=== ${SECONDS}s, the page, '$1' block $2"
  sed 's/^/  $ /' <<<"$3"
}

# page HEADING N - run the block as a reader would paste it: in a shell of
# its own, which stops at the first failing command.
page() {
  local code
  code="$(block "$1" "$2")"
  show "$1" "$2" "$code"
  PATH="$BLOCK_PATH" bash -euo pipefail -c "$code"
}

# page_out HEADING N - the same, with the block's output on stdout and the
# log on stderr.
page_out() {
  local code
  code="$(block "$1" "$2")" || return 1
  show "$1" "$2" "$code" >&2
  PATH="$BLOCK_PATH" bash -euo pipefail -c "$code"
}

# same_as_page WHAT HEADING N TEXT - fail unless TEXT is the page's Nth
# output block under HEADING.
same_as_page() {
  local want
  want="$(page_block "$2" "" "$3")"
  [ -n "$want" ] || fail "the page shows no output block $3 under '$2'"
  if [ "$4" != "$want" ]; then
    echo "FAIL: $1" >&2
    echo "  the page shows:" >&2; sed 's/^/    /' <<<"$want" >&2
    echo "  the command printed:" >&2; sed 's/^/    /' <<<"$4" >&2
    exit 1
  fi
  echo "ok:   $1"
}

# expect WHAT REGEX TEXT - fail unless a line of TEXT matches REGEX.
expect() {
  grep -qE -- "$2" <<<"$3" || fail "$1: no line matches $2"
  echo "ok:   $1"
}

# import_image IMAGE - load IMAGE from the local Docker daemon into the
# cluster's node. Saved for the daemon's platform alone: a daemon with the
# containerd image store keeps a pulled image as its multi-platform index,
# and the node's import fails on the platforms that are not there. k3d
# reports success either way, so the node is asked whether it has the image.
import_image() {
  local image="$1" node="k3d-$CLUSTER-server-0" tar="$WORK/image.tar" platform
  platform="$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')"
  echo "=== ${SECONDS}s, loading $image ($platform) into the cluster"
  # A Docker without `save --platform` has no multi-platform store either.
  docker save --platform "$platform" "$image" -o "$tar" 2>/dev/null \
    || docker save "$image" -o "$tar"
  k3d image import "$tar" -c "$CLUSTER"
  rm -f "$tar"
  docker exec "$node" crictl inspecti "$image" >/dev/null 2>&1 \
    || fail "the node $node has no image $image after the import"
  echo "ok:   the node has $image"
}

# late_database - a first start whose database is not there yet, with a
# second release in the same cluster. WordPress installs itself when its
# container first starts; the image's start hook asks again until the
# database answers. The release is installed without a WordPress pod, so
# that MariaDB can finish its own initialization undisturbed; then MariaDB is
# taken away, WordPress is started, has to wait, and has to end up installed
# once MariaDB is back.
late_database() {
  local ns=late release=late chart="${CHART:-$PAGE_CHART}" deadline log restarts
  local db="deployment/late-wordpress-nginx-mariadb" wp="deployment/late-wordpress-nginx"
  echo "=== ${SECONDS}s, a first start with the database away"
  # shellcheck disable=SC2086 # the extra flags are words of their own
  helm install "$release" "$chart" --namespace "$ns" --create-namespace \
    --set replicaCount=0 --set service.type=ClusterIP $HELM_EXTRA >/dev/null
  deadline=$((SECONDS + 300))
  until log="$(kubectl -n "$ns" logs "$db" 2>/dev/null)" && grep -q 'port: 3306' <<<"$log"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "MariaDB of the second release did not finish its initialization"
    sleep 3
  done
  kubectl -n "$ns" scale "$db" --replicas=0 >/dev/null
  kubectl -n "$ns" wait --for=delete pod \
    -l "app.kubernetes.io/name=wordpress-nginx-mariadb,app.kubernetes.io/instance=late" --timeout=3m >/dev/null
  kubectl -n "$ns" scale "$wp" --replicas=1 >/dev/null
  deadline=$((SECONDS + 180))
  until log="$(kubectl -n "$ns" logs "$wp" -c wordpress 2>/dev/null)" && grep -qF "Waiting for the database" <<<"$log"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "the WordPress container does not say that it waits for the database"
    sleep 3
  done
  # Long enough for a start that did not wait to reach the installer.
  sleep 20
  log="$(kubectl -n "$ns" logs "$wp" -c wordpress)"
  if grep -qF "Running Wordpress installer" <<<"$log"; then
    fail "the installer ran although the database is away"
  fi
  echo "ok:   without its database, WordPress waits and says so"
  kubectl -n "$ns" scale "$db" --replicas=1 >/dev/null
  kubectl -n "$ns" rollout status "$wp" --timeout=10m
  log="$(kubectl -n "$ns" logs "$wp" -c wordpress)"
  grep -qF "Running Wordpress installer" <<<"$log" \
    || fail "the installer did not run once the database was back"
  kubectl -n "$ns" exec "$wp" -c wordpress -- wp core is-installed \
    || fail "WordPress is not installed after its database came back"
  # The container that waited is the one that installed: a wait that hung
  # until the kubelet started the container again would pass the checks
  # above as well.
  restarts="$(kubectl -n "$ns" get pods -l "app.kubernetes.io/name=wordpress-nginx,app.kubernetes.io/instance=late" \
    -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="wordpress")].restartCount}')"
  [ "$restarts" = 0 ] || fail "the WordPress container was started ${restarts:-?} more time(s) while it waited"
  echo "ok:   once the database is back, WordPress installs itself and the pod gets ready"
}

# diagnose - what the cluster shows, for a run that failed.
diagnose() {
  local pod
  echo "=== the cluster after the failure"
  kubectl get pods -A -o wide || true
  kubectl get pvc,ingress,svc -A || true
  kubectl get events -A --sort-by=.lastTimestamp | tail -n 60 || true
  local ns
  for ns in "$PAGE_NAMESPACE" late; do
    for pod in $(kubectl -n "$ns" get pods -o name 2>/dev/null); do
      echo "--- $ns $pod"
      kubectl -n "$ns" logs "$pod" --all-containers --prefix --tail=150 || true
    done
  done
  kubectl -n kube-system logs deployment/traefik --tail=40 || true
}

# cleanup - the exit trap: after a failure, show what the cluster holds; then
# delete the cluster this run created, unless KEEP_CLUSTER is set, and the
# run's working directory. Keeps the run's exit status, and fails a run that
# passed if its cluster could not be deleted.
cleanup() {
  local rc=$?
  if [ -n "$CREATED" ]; then
    [ "$rc" -eq 0 ] || diagnose
    if [ -n "${KEEP_CLUSTER:-}" ]; then
      echo "kept: k3d cluster $CLUSTER, KUBECONFIG=$KUBECONFIG"
      exit "$rc"
    fi
    # A cluster left behind would stop the next run, which refuses to start
    # next to one of its name.
    if ! k3d cluster delete "$CLUSTER" >/dev/null 2>&1; then
      echo "FAIL: k3d cluster $CLUSTER is left: k3d cluster delete $CLUSTER" >&2
      [ "$rc" -ne 0 ] || rc=1
    fi
  fi
  [ -z "$WORK" ] || rm -rf "$WORK"
  exit "$rc"
}

# --- before the cluster ------------------------------------------------------

CHART=""
# The images to take from the local Docker daemon, one per line.
IMPORT=""
HELM_EXTRA=""
WORK=""
CREATED=""
# usage - say how the script is called and exit with 2.
usage() { echo "usage: $0 [--import IMAGE]... [CHART_DIR]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --import) [ $# -ge 2 ] || usage; IMPORT="${IMPORT:+$IMPORT$'\n'}$2"; shift ;;
    -*) usage ;;
    *) [ -z "$CHART" ] || usage
       [ -f "$1/Chart.yaml" ] || { echo "ERROR: $1 is no chart directory" >&2; exit 2; }
       CHART="$(cd "$1" && pwd)" ;;
  esac
  shift
done
[ -z "$IMPORT" ] || [ -n "$CHART" ] || { echo "ERROR: --import takes a chart directory" >&2; exit 2; }

# The page's commands take $url unquoted, as a reader's raw URL can be, and
# the paths go into them as they are: a space would split them.
for path in "$EXAMPLES" ${CHART:+"$CHART"}; do
  case "$path" in
    *[!A-Za-z0-9._/+@-]*)
      echo "ERROR: $path: the page's commands take paths of letters, digits and ._/+@- alone" >&2
      exit 2 ;;
  esac
done

for tool in docker k3d kubectl helm curl openssl; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required" >&2; exit 1; }
done

# A block the page lost fails here, in a second, rather than after the install.
for b in "${PAGE_BLOCKS[@]}"; do
  block "${b%|*}" "${b#*|}" >/dev/null
done

create="$(block "## 1. " 1)"
CLUSTER="$(sed -n 's/^k3d cluster create \([^ ]*\).*/\1/p' <<<"$create")"
PORT="$(sed -n 's/.* -p "127\.0\.0\.1:\([0-9][0-9]*\):80@loadbalancer".*/\1/p' <<<"$create")"
[ -n "$CLUSTER" ] && [ -n "$PORT" ] \
  || fail "the page's step 1 creates no k3d cluster with a loopback port for its load balancer"
SITE="http://localhost:$PORT"
if k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
  fail "a k3d cluster $CLUSTER exists: this run creates its own and deletes it"
fi

if [ -n "$CHART" ]; then
  if ! images="$(chart_images "$CHART" 2>&1)"; then
    echo "$images" >&2
    case "$images" in
      *"missing in charts/ directory"*) echo "ERROR: run: helm dependency update $CHART" >&2 ;;
    esac
    exit 1
  fi
  [ -n "$images" ] || fail "the chart names no image of ghcr.io/ioanalytica"
  while IFS= read -r image; do
    [ -n "$image" ] || continue
    grep -qxF "$image" <<<"$images" \
      || fail "the chart does not run $image, but: $(tr '\n' ' ' <<<"$images")"
    docker image inspect "$image" >/dev/null 2>&1 \
      || fail "the local Docker daemon has no image $image"
    # The value that keeps the release from pulling this image.
    case "$image" in
      */wordpress-idx:*) HELM_EXTRA="${HELM_EXTRA:+$HELM_EXTRA }--set idx.image.pullPolicy=Never" ;;
      *)                 HELM_EXTRA="${HELM_EXTRA:+$HELM_EXTRA }--set image.pullPolicy=Never" ;;
    esac
  done <<<"$IMPORT"
  # shellcheck disable=SC2046 # one image per word
  missing="$(unpublished $(grep -vxFf <(printf '%s\n' "$IMPORT") <<<"$images" || true))"
  [ -z "$missing" ] \
    || fail "the registry does not have $(tr '\n' ' ' <<<"$missing"); build the image and pass it with --import"
  echo "=== the chart in $CHART, with $(tr '\n' ' ' <<<"$images")${IMPORT:+($(tr '\n' ' ' <<<"$IMPORT")from the local Docker daemon)}"
else
  echo "=== the latest release of $PAGE_CHART"
fi

WORK="$(mktemp -d)"
export KUBECONFIG="$WORK/kubeconfig"
trap cleanup EXIT
cd "$WORK"

# The page's curl commands have no time limit, and a reader can interrupt
# them. Here a port that takes the connection and never answers would hold
# the run past its own deadlines, so the blocks get a curl that gives up.
CURL="$(command -v curl)"
mkdir "$WORK/bin"
printf '#!/bin/sh\nexec "%s" --max-time 60 "$@"\n' "$CURL" >"$WORK/bin/curl"
chmod +x "$WORK/bin/curl"
BLOCK_PATH="$WORK/bin:$PATH"

# --- the page ----------------------------------------------------------------

# 1. A cluster. Ours once k3d made it: a create that fails, for a cluster of
# the name that another run made in the meantime, must not delete that one.
page "## 1. " 1
CREATED=1
while IFS= read -r image; do
  [ -z "$image" ] || import_image "$image"
done <<<"$IMPORT"

# 2. Install, and wait
page "## 2. " 1
page "## 2. " 2

# 3. The site and the login. Traefik reads the Ingress a moment after it is
# up (the page's "When it hangs" says so): the first request may take a few
# tries, every later one must answer at once.
deadline=$((SECONDS + 60))
until out="$(page_out "## 3. " 1)" && [ "$out" = "$(page_block "## 3. " "" 1)" ]; do
  [ "$SECONDS" -lt "$deadline" ] || break
  sleep 3
done
same_as_page "the site answers at $SITE" "## 3. " 1 "$out"
title="$(sed -n 's/^wordpressBlogName: *//p' "$EXAMPLES/values.yaml")"
[ -n "$title" ] || fail "examples/k3d/values.yaml sets no wordpressBlogName"
# Into a variable first: grep -q ends at the first match, and curl, still
# writing into the closed pipe, would fail the pipeline.
html="$(curl -fsS --max-time 30 "$SITE/")"
# The start of the title: WordPress appends the tagline when the site has one.
grep -qF "<title>$title" <<<"$html" || fail "the front page is not titled '$title'"
echo "ok:   the front page is titled '$title'"

# The page sends the reader to wp-login.php with the user it names and the
# password its command prints; curl signs in the same way.
user="$(sed -n 's/.*the user is `\([^`]*\)`.*/\1/p' "$PAGE")"
[ -n "$user" ] || fail "the page names no user to sign in as"
password="$(page_out "## 3. " 2)"
[ -n "$password" ] || fail "the page's command printed no password"
jar="$WORK/cookies"
curl -fsS --max-time 30 -c "$jar" -o /dev/null "$SITE/wp-login.php"
curl -sS --max-time 30 -b "$jar" -c "$jar" -o /dev/null \
  --data-urlencode "log=$user" --data-urlencode "pwd=$password" \
  --data-urlencode "wp-submit=Log In" --data-urlencode "testcookie=1" \
  --data-urlencode "redirect_to=$SITE/wp-admin/" "$SITE/wp-login.php"
html="$(curl -fsS --max-time 30 -b "$jar" "$SITE/wp-admin/")"
grep -q '<title>Dashboard ' <<<"$html" \
  || fail "signing in as $user with the generated password does not lead to the dashboard"
echo "ok:   $user signs in with the generated password"
# An upload, as wp-admin's uploader sends it: a new installation has to be
# able to store a file, and to serve it. The page does not show this; the
# reader would use the Media screen.
html="$(curl -fsS --max-time 30 -b "$jar" "$SITE/wp-admin/media-new.php")"
nonce="$(sed -n 's/.*"_wpnonce":"\([a-f0-9]*\)".*/\1/p' <<<"$html" | sed -n 1p)"
[ -n "$nonce" ] || fail "wp-admin's upload page holds no nonce"
echo "A file for the upload check." >"$WORK/upload-check.txt"
answer="$(curl -sS --max-time 60 -b "$jar" -F "async-upload=@$WORK/upload-check.txt;type=text/plain" \
  -F "name=upload-check.txt" -F "action=upload-attachment" -F "_wpnonce=$nonce" "$SITE/wp-admin/async-upload.php")"
grep -q '"success":true' <<<"$answer" || fail "wp-admin refuses an upload: $answer"
stored="$(sed -n 's/.*"url":"\([^"]*upload-check[^"]*\.txt\)".*/\1/p' <<<"$answer" | sed -n 1p | sed 's|\\/|/|g')"
[ -n "$stored" ] || fail "the upload's answer names no file: $answer"
[ "$(curl -fsS --max-time 30 "$stored")" = "A file for the upload check." ] \
  || fail "the uploaded file is not served at $stored"
echo "ok:   $user uploads a file, and the site serves it"
out="$(page_out "## 3. " 3)"
same_as_page "the two plugins are installed and active" "## 3. " 2 "$out"

# 4. Search
out="$(page_out "## 4. " 1)"
echo "$out"
expect "the index holds the first post and the sample page" '^\{"total":2,"posts":1,"pages":1,' "$out"
expect "the search finds the first post, with its text" \
  '^\{"total":1,"results":\[\{"id":1,"type":"post",.*"title":"Hello world!",.*"content":"Welcome to WordPress\. ' "$out"
out="$(page_out "## 4. " 2)"
echo "$out"
expect "WP-CLI creates the post" '^Success: Created post [0-9]+\.$' "$out"
expect "the reindex takes the generated key" '^\{"status":"ok","entries":3\}$' "$out"
expect "the search finds the new post, with its text" \
  '^\{"total":1,"results":\[\{.*"title":"Notes from k3d",.*"content":"Traefik routes the requests and MariaDB keeps the posts\."' "$out"
# The endpoint is reachable through the Ingress: the key the chart hands the
# sidecar must be what opens it, and nothing else.
code="$("$CURL" -sS --max-time 30 -o /dev/null -w '%{http_code}' -X POST "$SITE/idx/api/reindex")"
[ "$code" = 401 ] || fail "a reindex without a key is answered with $code, not 401"
code="$("$CURL" -sS --max-time 30 -o /dev/null -w '%{http_code}' -X POST -H "X-Api-Key: not-the-key" "$SITE/idx/api/reindex")"
[ "$code" = 401 ] || fail "a reindex with a wrong key is answered with $code, not 401"
echo "ok:   the reindex endpoint refuses a missing and a wrong key"
# "Rebuild index" in wp-admin, as the settings page's script sends it: the
# plugin posts to the sidecar with the key the chart handed it when the
# container started. The page does not show this; the reader would press the
# button under Settings > IDX Search. A release from before the chart handed
# the key over has no such script, and the button asks for the key there;
# the run may be given any published version, so that is no failure. That
# the chart of the checkout renders the script is the template test's to say.
# Asked on a line of its own: a request that fails ends the run, where it
# would otherwise pass for a release without the script.
handover="$(kubectl -n "$PAGE_NAMESPACE" get configmap "$PAGE_RELEASE-wordpress-nginx-postinit" \
  -o jsonpath='{.data.06-idx-reindex-key\.sh}')"
if [ -n "$handover" ]; then
  html="$(curl -fsS --max-time 30 -b "$jar" "$SITE/wp-admin/options-general.php?page=idx-search")"
  nonce="$(sed -n 's/.*var idxAdmin = {[^}]*"nonce":"\([a-f0-9]*\)".*/\1/p' <<<"$html" | sed -n 1p)"
  [ -n "$nonce" ] || fail "the search plugin's settings page holds no nonce for the rebuild"
  answer="$(curl -sS --max-time 150 -b "$jar" --data-urlencode "action=idx_reindex" \
    --data-urlencode "_ajax_nonce=$nonce" "$SITE/wp-admin/admin-ajax.php")"
  expect "wp-admin's \"Rebuild index\" works with the key from the chart" \
    '^\{"success":true,"data":\{"status":"ok","entries":3\}\}$' "$answer"
else
  echo "skip: the installed release does not hand the reindex key to the search plugin yet"
fi

# 5. File-integrity monitoring
out="$(page_out "## 5. " 1)"
same_as_page "a scan of the new installation has no findings" "## 5. " 1 "$out"

# 6. A PHP file under uploads
out="$(page_out "## 6. " 1)"
same_as_page "NGINX refuses the PHP file and serves the text file" "## 6. " 1 "$out"
# The line reaches the container's log a moment after the request.
deadline=$((SECONDS + 30))
until out="$(page_out "## 6. " 2)"; do
  [ "$SECONDS" -lt "$deadline" ] || fail "the WordPress container logged no [php-allowlist] line"
  sleep 2
done
echo "$out"
expect "the refused request is logged" '^\[php-allowlist\] 403 [^ ]+ "GET /wp-content/uploads/demo\.php HTTP/1\.1" ' "$out"
out="$(page_out "## 6. " 3)"
same_as_page "the watcher reports the PHP file" "## 6. " 3 "$out"
# The page scans by hand, which leaves the running watcher's metrics as they
# are. What a Prometheus would read comes from the watcher's own loop: its
# next scan, at most one interval away, must report the file as well. Asked
# here and not earlier: a scan from before WordPress was installed says
# nothing about the installation.
finding="$(page_block "## 6. " "" 3 | head -n 1)"
watcher="/api/v1/namespaces/$PAGE_NAMESPACE/services/$PAGE_RELEASE-wordpress-nginx-fim:fim-metrics/proxy/metrics"
echo "=== ${SECONDS}s, waiting for the running watcher's next scan"
deadline=$((SECONDS + 180))
until metrics="$(kubectl get --raw "$watcher" --request-timeout=20s 2>&1)" && grep -qxF -- "$finding" <<<"$metrics"; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "$metrics" >&2
    fail "the running watcher did not report the PHP file within 3 minutes"
  fi
  sleep 5
done
echo "ok:   the running watcher reports the PHP file on its own"
out="$(page_out "## 6. " 4)"
same_as_page "without the files the scan is clean again" "## 6. " 4 "$out"

# Beyond the page: the same chart, started while its database is away.
late_database

# Clean up, with the page's command
if [ -z "${KEEP_CLUSTER:-}" ]; then
  page "## Clean up" 1
  if k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
    fail "the page's clean-up leaves the k3d cluster $CLUSTER"
  fi
  CREATED=""
  left="$(docker ps -a --format '{{.Names}}')"
  if grep -q "^k3d-$CLUSTER-" <<<"$left"; then
    fail "the page's clean-up leaves containers of the cluster $CLUSTER"
  fi
  echo "ok:   the clean-up leaves no cluster and no container"
fi

echo "=== the page end to end in ${SECONDS}s"
