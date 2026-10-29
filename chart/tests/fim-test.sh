#!/bin/bash
# Behavioural test of the file-integrity watcher (chart/files/fim.php).
#
# Builds a WordPress volume per case, renders the watcher configuration from
# the chart, runs one scan (fim.php --scan-once) in a PHP container as
# www-data (33) with the volume mounted read-only, and checks the findings.
#
#   ./fim-test.sh [image]
#
# The default image is the official PHP CLI image, which is enough for a
# scan. Pass the chart's own image to test exactly what runs in the cluster.

set -euo pipefail

CHART="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-php:8.4-cli-alpine}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

mkdir -p "$WORK/fim"
cp "$CHART/files/fim.php" "$WORK/fim/fim.php"
# wp-config.php is left out: its computed digest has its own lockstep test
# (check-fim.py). Everything else is the configuration the chart renders.
helm template tst "$CHART" --set fim.enabled=true \
    --set-json 'fim.baseline={"wp-config.php":[],"salts.php":["2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"]}' \
    --set-json 'fim.nameMarkers=["requestentry"]' \
    --set-json 'extraVolumeMounts=[{"name":"wordpress-data","mountPath":"/var/www/html/alt","subPath":"site-alt"}]' \
    --show-only templates/fim.yaml \
  | python3 -c 'import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d["kind"] == "ConfigMap":
        sys.stdout.write(d["data"]["config.json"])' > "$WORK/fim/config.json"

SILENCE='<?php
// Silence is golden.
'
# nginx.conf as W3 Total Cache writes it, plus the constructs the parser must
# read correctly: escaped braces, ${var}, a quoted "#", access_log off.
W3TC_NGINX='# BEGIN W3TC Browser Cache
gzip on;
gzip_types text/css application/javascript;
location ~ \.(css|js)$ {
    expires 31536000s;
    add_header Cache-Control "public, max-age=31536000" always;
    add_header X-Note "a # is no comment here";
    access_log off;
    log_not_found off;
    try_files $uri $uri/ /index.php?$args;
}
# END W3TC Browser Cache
set $w3tc_rewrite 1;
if ($request_method = POST) {
    set $w3tc_rewrite 0;
}
rewrite ^/.*-sitemap(\d\{1,4\})?\.xml$ "/index.php?xml_sitemap=params=$2" last;
location /wp-content/uploads/dlm_uploads { deny all; return 403; }
add_header X-Host ${host}-site;
'

# A clean site: placeholders, one plugin and theme each, W3TC with its
# drop-ins in place, and a static mount.
base() {
    rm -rf "$WORK/vol"
    local wc="$WORK/vol/wordpress/wp-content" w3="$WORK/vol/wordpress/wp-content/plugins/w3-total-cache"
    mkdir -p "$wc/plugins/akismet" "$wc/themes/t" "$wc/uploads/2026" "$w3/wp-content" "$WORK/vol/site-alt"
    printf 'foo' > "$WORK/vol/wordpress/salts.php"
    printf '%s' "$W3TC_NGINX" > "$WORK/vol/wordpress/nginx.conf"
    printf '%s' "$SILENCE" | tee "$wc/index.php" "$wc/plugins/index.php" > "$wc/themes/index.php"
    echo '<?php /* Plugin Name: Akismet */' > "$wc/plugins/akismet/akismet.php"
    echo '/* Theme Name: t */' > "$wc/themes/t/style.css"
    echo 'jpg' > "$wc/uploads/2026/photo.jpg"
    for d in advanced-cache.php db.php object-cache.php; do
        echo "<?php /* W3 Total Cache $d */" > "$w3/wp-content/$d"
        cp "$w3/wp-content/$d" "$wc/$d"
    done
    echo '<p>static</p>' > "$WORK/vol/site-alt/page.html"
    printf '%s' "$SILENCE" > "$WORK/vol/site-alt/index.php"
    LOCKED=""
}

# The tree goes into a Docker volume per scan rather than a bind mount:
# Docker Desktop does not enforce file modes on bind mounts, and the
# unreadable-directory rule depends on them. LOCKED lists paths (relative to
# the volume) that are made unreadable there.
LOCKED=""
scan() {
    local vol
    vol="$(docker volume create)"
    COPYFILE_DISABLE=1 tar -C "$WORK/vol" -cf - . \
      | docker run --rm -i --user 0 --network none --entrypoint sh -e LOCKED="$LOCKED" \
            -v "$vol:/watch" "$IMAGE" -c \
            'tar -xf - -C /watch && chmod -R a+rX /watch && for p in $LOCKED; do chmod 000 "/watch/$p"; done'
    docker run --rm --user 33:33 --network none --entrypoint /usr/local/bin/php \
        -v "$vol:/watch:ro" -v "$WORK/fim:/fim:ro" -e FIM_CONFIG=/fim/config.json \
        "$IMAGE" /fim/fim.php --scan-once 2>&1
    docker volume rm "$vol" >/dev/null
}

# expect <desc> <present|absent> <needle>: one scan of the current tree.
OUT=""
expect() {
    local desc="$1" mode="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$OUT"; then
        if [ "$mode" = present ]; then echo "ok:   $desc"
        else echo "FAIL: $desc — found '$needle'"; printf '%s\n' "$OUT" | grep '^wp_fim_violation' | sed 's/^/      /'; FAILURES=$((FAILURES + 1)); fi
    else
        if [ "$mode" = absent ]; then echo "ok:   $desc"
        else echo "FAIL: $desc — expected '$needle'"; printf '%s\n' "$OUT" | grep '^wp_fim_violation' | sed 's/^/      /'; FAILURES=$((FAILURES + 1)); fi
    fi
}

echo "=== A clean site with W3 Total Cache has no findings"
base; OUT="$(scan)"
expect "nothing found"                        present 'wp_fim_violations 0'
expect "the scan ran"                         present 'wp_fim_last_scan_timestamp_seconds'

echo "=== Drop-ins are judged against the copy their plugin ships"
base; echo '<?php eval($_POST[x]);' > "$WORK/vol/wordpress/wp-content/object-cache.php"; OUT="$(scan)"
expect "a replaced drop-in is found"          present 'path="wp-content/object-cache.php",rule="dropin-modified",sha256="'
expect "the intact drop-ins are not"          absent  'path="wp-content/db.php"'
base; echo '<?php /* W3 Total Cache 2.12 */' | tee "$WORK/vol/wordpress/wp-content/plugins/w3-total-cache/wp-content/db.php" > "$WORK/vol/wordpress/wp-content/db.php"; OUT="$(scan)"
expect "an updated plugin with its drop-in is fine" present 'wp_fim_violations 0'
base; rm -rf "$WORK/vol/wordpress/wp-content/plugins/w3-total-cache"; OUT="$(scan)"
expect "a drop-in without its plugin is found" present 'path="wp-content/advanced-cache.php",rule="dropin-modified"'

echo "=== nginx.conf is judged by its directives"
base; printf 'location ~ \\.jpg$ {\n    include fastcgi_params;\n    fastcgi_pass 127.0.0.1:9000;\n}\n' >> "$WORK/vol/wordpress/nginx.conf"; OUT="$(scan)"
expect "a backend handoff is found"           present 'path="nginx.conf",rule="nginx-conf-directive",directive="fastcgi_pass,include"'
base; printf 'location /x { alias /etc/; }\n' >> "$WORK/vol/wordpress/nginx.conf"; OUT="$(scan)"
expect "a file mapping is found"              present 'directive="alias"'
base; printf 'access_log /var/www/html/wp-content/uploads/x.php;\n' >> "$WORK/vol/wordpress/nginx.conf"; OUT="$(scan)"
expect "a log path is found"                  present 'directive="access_log"'
base; printf 'location /x {\n' >> "$WORK/vol/wordpress/nginx.conf"; OUT="$(scan)"
expect "an unparsable file is found"          present 'directive="<unparsable>"'
base; printf '# include /etc/passwd;\nadd_header X-A "include x; alias y";\n' >> "$WORK/vol/wordpress/nginx.conf"; OUT="$(scan)"
expect "comments and quoted words are not directives" present 'wp_fim_violations 0'

echo "=== A placeholder index.php is accepted wherever it is one"
base; up="$WORK/vol/wordpress/wp-content/uploads"; mkdir -p "$up/a" "$up/b" "$up/c" "$up/d"
: > "$up/a/index.php"; printf '<?php\n// Silence is golden.' > "$up/b/index.php"
printf '<?php // Silence is golden ?>\n' > "$up/c/index.php"; printf '<?php\n/* Silence is golden. */\n' > "$up/d/index.php"
OUT="$(scan)"
expect "empty, line comment, closing tag, block comment" present 'wp_fim_violations 0'
base; printf '<?php // ?><?php system($_GET["c"]);' > "$WORK/vol/wordpress/wp-content/uploads/index.php"; OUT="$(scan)"
expect "code behind a comment is not a placeholder" present 'path="wp-content/uploads/index.php",rule="php-in-writable-dir"'
base; echo '<?php include "x";' > "$WORK/vol/wordpress/wp-content/index.php"; OUT="$(scan)"
expect "wp-content/index.php with code is found" present 'path="wp-content/index.php",rule="root-php"'
base; echo '<?php include "x";' > "$WORK/vol/wordpress/wp-content/plugins/index.php"; OUT="$(scan)"
expect "plugins/index.php with code is found" present 'path="wp-content/plugins/index.php",rule="loose-file-in-component-dir"'
base; echo '<?php include "x";' > "$WORK/vol/site-alt/index.php"; OUT="$(scan)"
expect "a static index.php with code is found" present 'path="alt/index.php",rule="executable-in-static-path"'

echo "=== The other rules still hold"
base; wc="$WORK/vol/wordpress/wp-content"
echo x > "$wc/plugins/hello.php"; echo x > "$wc/uploads/fm-x.php.b64"; echo x > "$wc/themes/RequestEntry.css"
echo x > "$wc/uploads/2026/shell.php"; echo x > "$WORK/vol/site-alt/b.php"; mkdir -p "$wc/mu-plugins"
printf 'bar' > "$WORK/vol/wordpress/salts.php"; mkdir -p "$wc/uploads/locked"; echo x > "$wc/uploads/locked/hidden.php"
LOCKED="wordpress/wp-content/uploads/locked"
OUT="$(scan)"
expect "loose file in plugins/"               present 'path="wp-content/plugins/hello.php",rule="loose-file-in-component-dir"'
expect "encoded carrier"                      present 'path="wp-content/uploads/fm-x.php.b64",rule="encoded-carrier"'
expect "name marker beats the loose-file rule" present 'path="wp-content/themes/RequestEntry.css",rule="incident-marker"'
expect "PHP in uploads"                       present 'path="wp-content/uploads/2026/shell.php",rule="php-in-writable-dir"'
expect "executable in a static mount"         present 'path="alt/b.php",rule="executable-in-static-path"'
expect "mu-plugins directory"                 present 'path="wp-content/mu-plugins",rule="mu-plugins-dir"'
expect "changed baseline with its digest"     present 'path="salts.php",rule="baseline-modified",sha256="fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9"'
expect "unreadable directory"                 present 'path="wp-content/uploads/locked",rule="unreadable"'

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "=== $FAILURES check(s) FAILED"
    exit 1
fi
echo "=== All checks passed"
