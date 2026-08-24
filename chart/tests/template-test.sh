#!/bin/bash
# Template test for the wordpress-nginx chart.
#
# Renders the chart across a matrix of value combinations and checks structural
# invariants that `helm lint` does not: that every ConfigMap a Deployment mounts
# is actually rendered, that every volumeMount refers to a declared volume, and
# that every subPath exists as a key in the mounted ConfigMap. A helper that
# gates the creation of a ConfigMap on the wrong values renders a Deployment
# mounting a resource that never exists, which lint accepts and the cluster does
# not — the pod stays stuck. Feature-specific cases then assert that the
# hardening modes render the configuration they claim to.
#
#   ./template-test.sh [chart-dir]

set -euo pipefail

CHART="${1:-$(dirname "$0")/..}"
FAILURES=0

# chart/charts/ is gitignored, so a fresh checkout has no dependencies and
# every render would fail with the same message. Say so once, clearly.
# The output is captured first: under `set -o pipefail` a pipeline from a
# failing helm would carry its exit status, not grep's.
preflight="$(helm template tst "$CHART" 2>&1 || true)"
if printf '%s' "$preflight" | grep -q "missing in charts/ directory"; then
    echo "ERROR: chart dependencies are missing. Run:"
    echo "         helm dependency update $CHART"
    exit 1
fi

check() {
    local desc="$1"; shift
    local out
    if ! out="$(helm template tst "$CHART" "$@" 2>&1)"; then
        echo "FAIL: $desc — helm template failed"
        printf '%s\n' "$out" | sed 's/^/      /' | tail -5
        FAILURES=$((FAILURES + 1))
        return
    fi
    if ! printf '%s' "$out" | python3 "$(dirname "$0")/check-manifests.py" "$desc"; then
        FAILURES=$((FAILURES + 1))
        return
    fi
    echo "ok:   $desc"
}

# expect <desc> <"present"|"absent"> <needle> <helm args...>
expect() {
    local desc="$1" mode="$2" needle="$3"; shift 3
    local out
    out="$(helm template tst "$CHART" "$@" 2>&1)" || {
        echo "FAIL: $desc — helm template failed"; FAILURES=$((FAILURES + 1)); return
    }
    if printf '%s' "$out" | grep -qF -- "$needle"; then
        if [ "$mode" = "present" ]; then echo "ok:   $desc"
        else echo "FAIL: $desc — found '$needle' but expected it absent"; FAILURES=$((FAILURES + 1)); fi
    else
        if [ "$mode" = "absent" ]; then echo "ok:   $desc"
        else echo "FAIL: $desc — expected '$needle', not found"; FAILURES=$((FAILURES + 1)); fi
    fi
}

echo "=== Chart version and image tag agree"
# The image tag is read from the Chart.yaml annotation, not from values. A
# release that bumps version: but not imageTag ships a chart that deploys the
# previous image - which happened in 7.1.0-4 and went unnoticed because the
# feature that needed the new image was off by default.
chart_version=$(sed -n 's/^version: *//p' "$CHART/Chart.yaml" | tr -d '"')
image_tag=$(sed -n 's/^  imageTag: *"\(.*\)"$/\1/p' "$CHART/Chart.yaml")
images_tag=$(sed -n 's|^      image: ghcr.io/ioanalytica/wordpress-nginx:||p' "$CHART/Chart.yaml")
if [ "$chart_version" = "$image_tag" ] && [ "$chart_version" = "$images_tag" ]; then
    echo "ok:   version, imageTag and images annotation all say $chart_version"
else
    echo "FAIL: version=$chart_version imageTag=$image_tag images=$images_tag - must be identical"
    FAILURES=$((FAILURES + 1))
fi
rendered=$(helm template tst "$CHART" | sed -n 's|.*image: ghcr.io/ioanalytica/wordpress-nginx:||p' | head -1)
if [ "$rendered" = "$chart_version" ]; then
    echo "ok:   rendered image tag is $rendered"
else
    echo "FAIL: rendered image tag is '$rendered', chart version is $chart_version"
    FAILURES=$((FAILURES + 1))
fi

echo "=== Structural invariants across the value matrix"
check "defaults"
check "php allowlist report"        --set phpExecutionAllowlist.mode=report
check "php allowlist off"           --set phpExecutionAllowlist.mode=off
check "php allowlist extra paths"   --set 'phpExecutionAllowlist.extraAllowedPaths={~*^/wp-content/plugins/p/c\.php$}'
check "rest hardening enforce"      --set restApiHardening.mode=enforce
check "rest hardening report"       --set restApiHardening.mode=report
check "rest hardening extra paths"  --set 'restApiHardening.extraDeniedPaths={~*^/wp-json/wp/v2/comments}'
# Regression: gating the server block ConfigMap on the wrong values rendered a
# mount for a resource that was never created, and the pod could not start.
check "server block addition only"  --set 'nginxCustomServerBlockAddition=# test'
check "nginx configuration only"    --set 'nginxConfiguration=# test'
check "persistence disabled"        --set persistence.enabled=false
check "ingress enabled"             --set ingress.enabled=true --set ingress.hostname=example.com
check "denied paths set"            --set 'nginx.deniedPaths[0].path=/wp-content/uploads/x' --set 'nginx.deniedPaths[0].action=deny'
# Several entries at once. The prefix list is interpolated into a shell
# assignment inside a YAML block scalar, so this is where a newline in the
# helper output breaks the manifest - a single entry renders fine regardless.
check "denied paths, several entries" -f "$(dirname "$0")/fixtures/denied-paths-multi.yaml"
check "everything at once"          --set phpExecutionAllowlist.mode=report \
                                    --set restApiHardening.mode=enforce \
                                    --set 'nginxCustomServerBlockAddition=# test' \
                                    --set ingress.enabled=true

echo "=== PHP execution allowlist renders what it claims"
expect "enforce creates no override"     absent  "nginx-php-allowlist"
expect "report mounts the override"      present "00-php-allowlist.conf"       --set phpExecutionAllowlist.mode=report
expect "report keeps logging"            present "php_allowlist if="           --set phpExecutionAllowlist.mode=report
expect "report does not block"           absent  'if ($wp_php_denied) { return 403; }' --set phpExecutionAllowlist.mode=report
expect "off does not block"              absent  'if ($wp_php_denied) { return 403; }' --set phpExecutionAllowlist.mode=off
expect "off does not log"                absent  "php_allowlist if="           --set phpExecutionAllowlist.mode=off

echo "=== subPath-mounted config triggers a rollout"
# A subPath mount never receives ConfigMap updates - the kubelet projects the
# file once at container start. Without a checksum annotation the Deployment
# spec stays byte-identical when only ConfigMap content changes, no rollout
# happens, and running pods keep the old configuration with nothing to show it.
expect "serverblock has a checksum"    present "checksum/nginx-serverblock" --set 'nginxCustomServerBlockAddition=# x'
expect "denied paths has a checksum"   present "checksum/nginx-denied-paths" \
        --set 'nginx.deniedPaths[0].path=/a' --set 'nginx.deniedPaths[0].action=deny'
expect "rest hardening has a checksum" present "checksum/nginx-rest-hardening" --set restApiHardening.mode=enforce
expect "php allowlist has a checksum"  present "checksum/nginx-php-allowlist" --set phpExecutionAllowlist.mode=report
expect "no checksums without config"   absent  "checksum/nginx-"

sb_x=$(helm template tst "$CHART" --set 'nginxCustomServerBlockAddition=# x' | grep 'checksum/nginx-serverblock' | head -1)
sb_y=$(helm template tst "$CHART" --set 'nginxCustomServerBlockAddition=# y' | grep 'checksum/nginx-serverblock' | head -1)
sb_x2=$(helm template tst "$CHART" --set 'nginxCustomServerBlockAddition=# x' | grep 'checksum/nginx-serverblock' | head -1)
if [ "$sb_x" != "$sb_y" ]; then echo "ok:   a changed value changes the checksum"
else echo "FAIL: checksum unchanged across different values - no rollout would happen"; FAILURES=$((FAILURES + 1)); fi
if [ "$sb_x" = "$sb_x2" ]; then echo "ok:   an unchanged value keeps the checksum stable"
else echo "FAIL: checksum unstable for identical values - every render would roll pods"; FAILURES=$((FAILURES + 1)); fi

echo "=== Denied paths render what they claim"
expect "empty list renders nothing"        absent  "nginx-denied-paths"
expect "directory becomes anchored regex"  present '"~*^/wp-content/uploads/dlm\.uploads(/|$)" 403;' \
        --set 'nginx.deniedPaths[0].path=/wp-content/uploads/dlm.uploads' --set 'nginx.deniedPaths[0].action=deny'
expect "trailing slash is normalized"      present '"~*^/wp-content/uploads/x(/|$)" 403;' \
        --set 'nginx.deniedPaths[0].path=/wp-content/uploads/x/' --set 'nginx.deniedPaths[0].action=deny'
expect "regex entry is taken verbatim"     present '"~*^/wp-content/themes/evil/" 418;' \
        --set 'nginx.deniedPaths[0].path=~* ^/wp-content/themes/evil/' --set 'nginx.deniedPaths[0].action=honeypot'
expect "action defaults to deny"           present '" 403;' \
        --set 'nginx.deniedPaths[0].path=/wp-content/uploads/x'
expect "reason becomes a comment"          present '# Download Monitor' \
        --set 'nginx.deniedPaths[0].path=/wp-content/uploads/x' --set 'nginx.deniedPaths[0].reason=Download Monitor'
expect "init gets plain prefixes"          present 'DENIED_PREFIXES="/wp-content/uploads/x"' \
        --set 'nginx.deniedPaths[0].path=/wp-content/uploads/x'
expect "init does not get regex entries"   present 'DENIED_PREFIXES=""' \
        --set 'nginx.deniedPaths[0].path=~* ^/wp-content/themes/evil/'
expect "several prefixes stay on one line" present 'DENIED_PREFIXES="/wp-content/ai1wm-backups /wp-content/backup-db /wp-content/cache/minify"' \
        -f "$(dirname "$0")/fixtures/denied-paths-multi.yaml"
expect "reason with regex-like chars renders" present '# .htaccess found (<Files ~ ".*\..*">)' \
        -f "$(dirname "$0")/fixtures/denied-paths-multi.yaml"
# The init script classifies .htaccess content. These assert the classifier's
# branches are present in the rendered script, so a template edit cannot drop
# one silently; behaviour itself is exercised in docker/tests/htaccess-test.sh.
expect "classifier: deny branch"           present 'class=deny'
expect "classifier: partial branch"        present 'class=partial'
expect "classifier: allow branch"          present 'class=allow'
expect "classifier: plugin-managed check"  present '/wordpress/nginx.conf'
expect "classifier: fail only on blanket deny" present 'htaccess-blocking'
expect "policy defaults to warn"           present 'HTACCESS_POLICY="warn"'
expect "policy fail is rendered"           present 'HTACCESS_POLICY="fail"' --set nginx.htaccessPolicy=fail

echo "=== Cache password reaches the plugin, and only through a Secret"
expect "no cache password, no env"        absent  "WORDPRESS_CACHE_PASSWORD"
expect "internal cache exposes the env"   present "name: WORDPRESS_CACHE_PASSWORD" \
                                          --set wordpressConfigureCache=true --set memcached.enabled=true
expect "internal cache reads the key"     present "key: cache-password" \
                                          --set wordpressConfigureCache=true --set memcached.enabled=true
expect "external password exposes the env" present "name: WORDPRESS_CACHE_PASSWORD" \
                                          --set externalCache.password=pw --set externalCache.host=r --set externalCache.port=6379
expect "existingSecret is referenced"     present "name: my-cache-secret" \
                                          --set externalCache.existingSecret=my-cache-secret \
                                          --set externalCache.existingSecretPasswordKey=redis-pw \
                                          --set externalCache.host=r --set externalCache.port=6379
expect "existingSecret key is used"       present "key: redis-pw" \
                                          --set externalCache.existingSecret=my-cache-secret \
                                          --set externalCache.existingSecretPasswordKey=redis-pw \
                                          --set externalCache.host=r --set externalCache.port=6379
expect "plugin reads it from the env"     present 'WORDPRESS_CACHE_PASSWORD' \
                                          --set wordpressConfigureCache=true --set memcached.enabled=true

# The password must live in a Secret and nowhere else. MANIFEST_SENTINEL makes
# the checker fail on any non-Secret document carrying the value.
MANIFEST_SENTINEL=s3ntinelpw \
  check "external password never leaves the Secret" \
        --set wordpressConfigureCache=true --set externalCache.type=redis \
        --set externalCache.host=r --set externalCache.port=6379 \
        --set externalCache.password=s3ntinelpw

echo "=== WP_CACHE follows the tri-state"
expect "unset with cache off means false"  present "define( 'WP_CACHE', false )"
expect "unset with cache on means true"    present "define( 'WP_CACHE', true )" \
                                           --set wordpressConfigureCache=true --set memcached.enabled=true
expect "explicit true wins on its own"     present "define( 'WP_CACHE', true )"  --set wordpressWpCache=true
expect "explicit false beats cache on"     present "define( 'WP_CACHE', false )" \
                                           --set wordpressConfigureCache=true --set memcached.enabled=true \
                                           --set wordpressWpCache=false

echo "=== W3 Total Cache configures every cache it claims to"
expect "db cache configured"      present "option set dbcache.enabled true"     --set wordpressConfigureCache=true --set memcached.enabled=true
expect "object cache configured"  present "option set objectcache.enabled true" --set wordpressConfigureCache=true --set memcached.enabled=true
expect "page cache configured"    present "option set pgcache.enabled true"     --set wordpressConfigureCache=true --set memcached.enabled=true

echo "=== REST hardening renders what it claims"
expect "off creates nothing"             absent  "nginx-rest-hardening"
expect "enforce blocks"                  present 'if ($wp_rest_blocked) { return 403; }' --set restApiHardening.mode=enforce
expect "report does not block"           absent  'if ($wp_rest_blocked) { return 403; }' --set restApiHardening.mode=report
expect "report freezes the decision"     present 'set $wp_rest_reported 1'     --set restApiHardening.mode=report
expect "extra deny renders a pattern"    present '" 1;'                        --set 'restApiHardening.extraDeniedPaths={~*^/wp-json/wp/v2/comments}'

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "=== $FAILURES check(s) FAILED"
    exit 1
fi
echo "=== All checks passed"
