#!/bin/bash
# Smoke test for the NGINX hardening in the wordpress-nginx image: the PHP
# execution allowlist and the REST API hardening.
#
# Verifies that PHP files are only executed from allowlisted entry points, that
# denied REST routes are refused through both of their spellings, that the
# report and off modes behave as documented for both features, and that the
# extra pattern directories take effect. Run against a locally built image:
#
#   ./smoke-test.sh ghcr.io/ioanalytica/wordpress-nginx:test

set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh <image-ref>}"
NAME="wpnginx-smoke-$$"
FAILURES=0

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

cexec() { docker exec "$NAME" sh -c "$1"; }

# assert <description> <expected-status> <url> [expected-body-substring] [user-agent]
assert() {
    local desc="$1" want_status="$2" url="$3" want_body="${4:-}" ua="${5:-smoke-test}"
    local status body
    status="$(cexec "curl -s -o /tmp/smoke-body -w '%{http_code}' -A '$ua' 'http://localhost$url'")"
    body="$(cexec "cat /tmp/smoke-body")"
    if [ "$status" != "$want_status" ]; then
        echo "FAIL: $desc — expected HTTP $want_status, got $status ($url)"
        FAILURES=$((FAILURES + 1))
    elif [ -n "$want_body" ] && ! printf '%s' "$body" | grep -q "$want_body"; then
        echo "FAIL: $desc — HTTP $status but body lacks '$want_body' ($url)"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok:   $desc ($url -> $status)"
    fi
}

# assert_auth <description> <expected-status> <url> [expected-body-substring]
# Same as assert, but sends a WordPress session cookie.
assert_auth() {
    local desc="$1" want_status="$2" url="$3" want_body="${4:-}"
    local status body
    status="$(cexec "curl -s -o /tmp/smoke-body -w '%{http_code}' -A 'smoke-test' -b 'wordpress_logged_in_deadbeef=someuser%7C123%7Cabc' 'http://localhost$url'")"
    body="$(cexec "cat /tmp/smoke-body")"
    if [ "$status" != "$want_status" ]; then
        echo "FAIL: $desc — expected HTTP $want_status, got $status ($url)"
        FAILURES=$((FAILURES + 1))
    elif [ -n "$want_body" ] && ! printf '%s' "$body" | grep -q "$want_body"; then
        echo "FAIL: $desc — HTTP $status but body lacks '$want_body' ($url)"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok:   $desc ($url -> $status)"
    fi
}

# assert_not_executed <description> <url> <forbidden-body-substring>
# Asserts that a request never reaches PHP, whatever status it ends up with.
# Used for normalization variants, where pinning an exact status code would
# cement today's behavior instead of the property that matters.
assert_not_executed() {
    local desc="$1" url="$2" forbidden="$3"
    local body
    cexec "curl -s -o /tmp/smoke-body -A 'smoke-test' 'http://localhost$url'" >/dev/null
    body="$(cexec "cat /tmp/smoke-body")"
    if printf '%s' "$body" | grep -q "$forbidden"; then
        echo "FAIL: $desc — PHP was executed ($url)"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok:   $desc ($url)"
    fi
}

# await_log <description> <grep-pattern>
# Asserts that a line matching the pattern reaches the container log. The
# line travels nginx -> s6 -> docker log driver, and on a loaded runner it
# can arrive a moment after curl has returned - a single-shot grep loses
# that race (observed in CI: the same commit passed in one workflow and
# failed in the parallel one on exactly this check). Poll briefly instead.
await_log() {
    local desc="$1" pattern="$2" i
    for i in $(seq 1 10); do
        if docker logs "$NAME" 2>&1 | grep -q "$pattern"; then
            echo "ok:   $desc"
            return
        fi
        sleep 0.5
    done
    echo "FAIL: $desc — no log line matching '$pattern'"
    FAILURES=$((FAILURES + 1))
}

# assert_gone <description> <expected-status> <host> <url> <user-agent> [expected-location]
# Sends the request with an explicit Host header; verifies the status and,
# when given, the Location target of a redirect. An empty user-agent argument
# sends no User-Agent header at all.
assert_gone() {
    local desc="$1" want_status="$2" host="$3" url="$4" ua="$5" want_loc="${6:-}"
    local out status loc
    out="$(cexec "curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -A '$ua' -H 'Host: $host' 'http://localhost$url'")"
    status="${out%% *}"
    loc="${out#* }"
    if [ "$status" != "$want_status" ]; then
        echo "FAIL: $desc — expected HTTP $want_status, got $status ($host$url)"
        FAILURES=$((FAILURES + 1))
    elif [ -n "$want_loc" ] && [ "$loc" != "$want_loc" ]; then
        echo "FAIL: $desc — HTTP $status but Location is '$loc', expected '$want_loc' ($host$url)"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok:   $desc ($host$url -> $status)"
    fi
}

reload_nginx() {
    cexec 'kill -HUP "$(ps -o pid,args | grep "nginx: master" | grep -v grep | awk "{print \$1}")"'
    sleep 1
}

echo "=== Starting $IMAGE as $NAME"
docker run -d --name "$NAME" "$IMAGE" >/dev/null

echo "=== Waiting for nginx"
# Probe a URL that never reaches PHP: executing index.php here would put the
# image's real WordPress index.php into opcache before the fixtures below
# replace it, and the stale cached version would then be served.
for i in $(seq 1 60); do
    if cexec 'curl -s -o /dev/null http://localhost/favicon.ico' 2>/dev/null; then break; fi
    [ "$i" = 60 ] && { echo "FAIL: nginx did not come up"; exit 1; }
    sleep 1
done

echo "=== Creating test fixtures"
cexec '
mkdir -p /var/www/html/wp-content/uploads /var/www/html/wp-content/plugins/testplugin /var/www/html/wp-admin
echo "<?php echo \"UPLOADS-EXECUTED\";"   > /var/www/html/wp-content/uploads/shell.php
echo "<?php echo \"PLUGIN-EXECUTED\";"    > /var/www/html/wp-content/plugins/testplugin/direct.php
echo "<?php echo \"INDEX-EXECUTED\";"     > /var/www/html/index.php
echo "<?php echo \"AJAX-EXECUTED\";"      > /var/www/html/wp-admin/admin-ajax.php
echo "<?php echo \"LOGIN-EXECUTED\";"     > /var/www/html/wp-login.php
echo "<?php echo \"EXEC\" . \"UTED-HEALTHZ\";" > /var/www/html/healthz.php
'

echo "=== Mode: enforce (image default)"
assert "uploads PHP is blocked"           403 /wp-content/uploads/shell.php
assert "uploads PHP PATH_INFO is blocked" 403 /wp-content/uploads/shell.php/x.png
assert "plugin direct PHP is blocked"     403 /wp-content/plugins/testplugin/direct.php
assert "wp-config.php is blocked"         403 /wp-config.php
assert "xmlrpc.php is blocked"            403 /xmlrpc.php
assert "index.php executes"               200 /index.php INDEX-EXECUTED
assert "front page executes"              200 / INDEX-EXECUTED
assert "admin-ajax.php executes"          200 /wp-admin/admin-ajax.php AJAX-EXECUTED
assert "wp-login.php executes"            200 /wp-login.php LOGIN-EXECUTED
assert "sitemap rewrite executes"         200 /sitemap.xml INDEX-EXECUTED
assert "healthz executes for kube-probe"  200 /healthz.php EXECUTED-HEALTHZ kube-probe/1.0
assert "healthz rejects other agents"     403 /healthz.php

echo "=== PHP allowlist: normalization variants"
# The guard matches on the normalized $uri. Every one of these resolves to the
# same uploads path, so none of them may reach PHP.
assert_not_executed "percent-encoded extension"   "/wp-content/uploads/shell.ph%70"     UPLOADS-EXECUTED
assert_not_executed "percent-encoded dot"         "/wp-content/uploads/shell%2ephp"     UPLOADS-EXECUTED
assert_not_executed "duplicate slash"             "/wp-content/uploads//shell.php"      UPLOADS-EXECUTED
assert_not_executed "dot segment"                 "/wp-content/uploads/./shell.php"     UPLOADS-EXECUTED
assert_not_executed "parent segment"              "/wp-content/uploads/x/../shell.php"  UPLOADS-EXECUTED
assert_not_executed "dot segment in parent dir"   "/wp-content/./uploads/shell.php"     UPLOADS-EXECUTED
assert_not_executed "uppercase extension"         "/wp-content/uploads/SHELL.PHP"       UPLOADS-EXECUTED
assert_not_executed "trailing dot"                "/wp-content/uploads/shell.php."      UPLOADS-EXECUTED

echo "=== Extra allow pattern"
cexec 'echo "\"~*^/wp-content/plugins/testplugin/direct\\.php$\" 0;" > /etc/nginx/php-allowlist.d/50-extra-allow.conf'
reload_nginx
assert "extra-allowed plugin PHP executes" 200 /wp-content/plugins/testplugin/direct.php PLUGIN-EXECUTED
assert "uploads PHP still blocked"         403 /wp-content/uploads/shell.php
cexec 'rm /etc/nginx/php-allowlist.d/50-extra-allow.conf'

echo "=== Mode: report"
cexec 'echo "access_log /proc/1/fd/2 php_allowlist if=\$wp_php_denied;" > /etc/nginx/custom.d/00-php-allowlist.conf'
reload_nginx
assert "uploads PHP executes in report mode" 200 /wp-content/uploads/shell.php UPLOADS-EXECUTED
await_log "report mode logs the would-be block" '\[php-allowlist\] 200 .*shell\.php'

echo "=== Mode: off"
cexec 'echo "# php allowlist disabled" > /etc/nginx/custom.d/00-php-allowlist.conf'
reload_nginx
assert "uploads PHP executes in off mode" 200 /wp-content/uploads/shell.php UPLOADS-EXECUTED

echo "=== Denied paths: image default is inert"
cexec '
mkdir -p /var/www/html/wp-content/uploads/dlm_uploads /var/www/html/wp-content/themes/config-1785900943/assets
echo "ZIP-CONTENT" > /var/www/html/wp-content/uploads/dlm_uploads/report.zip
echo "<?php echo \"BACKDOOR\";" > /var/www/html/wp-content/themes/config-1785900943/assets/custom-file-4-1785900944.php
'
assert "dlm_uploads served by default"   200 /wp-content/uploads/dlm_uploads/report.zip ZIP-CONTENT

echo "=== Denied paths: as the chart renders them"
cexec 'cat > /etc/nginx/denied-paths.d/10-chart.conf <<EOF
"~*^/wp-content/uploads/dlm_uploads(/|\$)" 403;
"~*^/wp-content/themes/config-1785900943/" 418;
EOF'
reload_nginx
# The directory rule must hold for extensions the static-file location matches.
# A plain prefix location would lose to that regex location and serve the zip.
assert "denied dir: zip is refused"       403 /wp-content/uploads/dlm_uploads/report.zip
assert "denied dir: directory itself"     403 /wp-content/uploads/dlm_uploads/
assert "denied dir: no prefix overreach"  404 /wp-content/uploads/dlm_uploads_other/x.zip
# The honeypot status must survive the PHP allowlist, which would answer 403
# for this .php path if it ran first.
assert "honeypot answers 418, not 403"    418 /wp-content/themes/config-1785900943/assets/custom-file-4-1785900944.php
assert "unrelated uploads unaffected"     404 /wp-content/uploads/other.zip
assert_not_executed "honeypot never reaches PHP" /wp-content/themes/config-1785900943/assets/custom-file-4-1785900944.php BACKDOOR
assert_not_executed "denied dir: dot segment"      "/wp-content/uploads/dlm_uploads/../dlm_uploads/report.zip" ZIP-CONTENT
assert_not_executed "denied dir: double slash"     "/wp-content//uploads/dlm_uploads/report.zip" ZIP-CONTENT
assert_not_executed "denied dir: uppercase"        "/wp-content/uploads/DLM_UPLOADS/report.zip" ZIP-CONTENT
assert_not_executed "denied dir: encoded underscore" "/wp-content/uploads/dlm%5fuploads/report.zip" ZIP-CONTENT
cexec 'rm /etc/nginx/denied-paths.d/10-chart.conf'
reload_nginx

echo "=== Gone hosts: image default is inert"
assert_gone "unknown host serves normally" 200 forum.example.com / 'Mozilla/5.0 (compatible; PetalBot;+https://webmaster.petalsearch.com/site/petalbot)'

echo "=== Gone hosts: as the chart renders them"
# Restore the allowlist to its enforcing image default first: the point of
# the custom.d file ordering is that a crawler's 410 wins over the
# allowlist's 403 for .php paths.
cexec 'printf "%s\n%s\n" "if (\$wp_php_denied) { return 403; }" "access_log /proc/1/fd/2 php_allowlist if=\$wp_php_denied;" > /etc/nginx/custom.d/00-php-allowlist.conf'
cexec 'cat > /etc/nginx/gone-hosts.d/10-chart.conf <<EOF
"forum.example.com" "https://example.com/";
".old.example.net" "https://example.com/";
EOF'
reload_nginx
CRAWLER='Mozilla/5.0 (compatible; PetalBot;+https://webmaster.petalsearch.com/site/petalbot)'
BROWSER='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
assert_gone "crawler: front page is gone"          410 forum.example.com / "$CRAWLER"
assert_gone "crawler: robots.txt is gone"          410 forum.example.com /robots.txt "$CRAWLER"
assert_gone "crawler: 410 beats the allowlist 403" 410 forum.example.com /viewtopic.php "$CRAWLER"
assert_gone "crawler: deep path is gone"           410 forum.example.com /some/old/page "$CRAWLER"
assert_gone "no user agent counts as crawler"      410 forum.example.com / ""
assert_gone "hostnames suffix covers subdomains"   410 www.old.example.net / "$CRAWLER"
assert_gone "browser: 301 to the target root"      301 forum.example.com / "$BROWSER" https://example.com/
assert_gone "browser: path is not preserved"       301 forum.example.com /viewtopic.php "$BROWSER" https://example.com/
assert_gone "canonical host: crawler unaffected"   200 localhost / "$CRAWLER"
assert "canonical host: allowlist still enforces"  403 /wp-content/uploads/shell.php
# The honeypot must keep answering 418 on a retired host: probers of a
# removed backdoor ban themselves whatever hostname they use.
cexec 'cat > /etc/nginx/denied-paths.d/10-chart.conf <<EOF
"~*^/wp-content/themes/config-1785900943/" 418;
EOF'
reload_nginx
assert_gone "honeypot outranks gone on a retired host" 418 forum.example.com /wp-content/themes/config-1785900943/assets/custom-file-4-1785900944.php "$CRAWLER"
cexec 'rm /etc/nginx/denied-paths.d/10-chart.conf /etc/nginx/gone-hosts.d/10-chart.conf'
cexec 'echo "# php allowlist disabled" > /etc/nginx/custom.d/00-php-allowlist.conf'
reload_nginx
assert_gone "cleanup: retired host serves again"   200 forum.example.com / "$CRAWLER"

echo "=== REST API hardening: image default is inert"
assert "REST users passes by default"   200 /wp-json/wp/v2/users INDEX-EXECUTED
assert "author id passes by default"    200 "/?author=1" INDEX-EXECUTED

echo "=== REST API hardening: enforce (opt-in, as the chart renders it)"
cexec 'printf "%s\\n%s\\n" "if (\$wp_rest_blocked) { return 403; }" "access_log /proc/1/fd/2 rest_hardening if=\$wp_rest_blocked;" > /etc/nginx/custom.d/00-rest-hardening.conf'
reload_nginx
assert "REST users route is blocked"          403 /wp-json/wp/v2/users
assert "REST users subresource is blocked"    403 /wp-json/wp/v2/users/1
assert "REST users via rest_route is blocked" 403 "/?rest_route=/wp/v2/users"
assert "REST users trailing slash is blocked" 403 /wp-json/wp/v2/users/
assert "other REST routes still pass"         200 /wp-json/wp/v2/posts INDEX-EXECUTED
assert "unrelated rest_route still passes"    200 "/?rest_route=/wp/v2/posts" INDEX-EXECUTED
assert "author id enumeration is blocked"     403 "/?author=1"
assert "author id with extra args is blocked" 403 "/?author=12&foo=bar"
assert "author feed by id is blocked"         403 "/?feed=rss2&author=1"
assert "pretty author archive still passes"   200 /author/jane/ INDEX-EXECUTED
assert "non-numeric author arg passes"        200 "/?author=jane" INDEX-EXECUTED
# "author" is also an ordinary REST filter parameter. Denying it there would
# break anonymous REST consumers, so these must stay reachable.
assert "REST author filter passes"           200 "/wp-json/wp/v2/posts?author=1" INDEX-EXECUTED
assert "REST media author filter passes"     200 "/wp-json/wp/v2/media?author=2" INDEX-EXECUTED
assert "rest_route author filter passes"     200 "/?rest_route=/wp/v2/posts&author=1" INDEX-EXECUTED

echo "=== REST API hardening: session cookie gate"
assert_auth "REST users passes with session cookie"    200 /wp-json/wp/v2/users INDEX-EXECUTED
assert_auth "rest_route users passes with cookie"      200 "/?rest_route=/wp/v2/users" INDEX-EXECUTED
assert_auth "wp-admin author filter passes with cookie" 200 "/wp-admin/admin-ajax.php?author=5" AJAX-EXECUTED
assert      "wp-admin author filter blocked anonymous"  403 "/wp-admin/admin-ajax.php?author=5"

echo "=== REST API hardening: extra deny pattern"
cexec 'echo "\"~*^/wp-json/wp/v2/comments(/|\\?|\$)\" 1;" > /etc/nginx/rest-hardening.d/50-extra-deny.conf'
reload_nginx
assert "extra-denied REST route is blocked" 403 /wp-json/wp/v2/comments
assert "posts route still passes"           200 /wp-json/wp/v2/posts INDEX-EXECUTED
cexec 'rm /etc/nginx/rest-hardening.d/50-extra-deny.conf'

echo "=== REST API hardening: report"
cexec 'printf "%s\\n%s\\n" "if (\$wp_rest_denied) { set \$wp_rest_reported 1; }" "access_log /proc/1/fd/2 rest_hardening if=\$wp_rest_reported;" > /etc/nginx/custom.d/00-rest-hardening.conf'
reload_nginx
assert "REST users passes in report mode" 200 /wp-json/wp/v2/users INDEX-EXECUTED
await_log "report mode logs the would-be block" '\[rest-hardening\] 200 .*wp/v2/users'

echo "=== REST API hardening: off (chart mounts nothing, image file stands)"
cexec 'echo "# rest hardening inert" > /etc/nginx/custom.d/00-rest-hardening.conf'
reload_nginx
assert "REST users passes in off mode" 200 /wp-json/wp/v2/users INDEX-EXECUTED

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "=== $FAILURES assertion(s) FAILED"
    exit 1
fi
echo "=== All assertions passed"
