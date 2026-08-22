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
if docker logs "$NAME" 2>&1 | grep -q '\[php-allowlist\] 200 .*shell\.php'; then
    echo "ok:   report mode logs the would-be block"
else
    echo "FAIL: report mode did not log '[php-allowlist] 200 ... shell.php'"
    FAILURES=$((FAILURES + 1))
fi

echo "=== Mode: off"
cexec 'echo "# php allowlist disabled" > /etc/nginx/custom.d/00-php-allowlist.conf'
reload_nginx
assert "uploads PHP executes in off mode" 200 /wp-content/uploads/shell.php UPLOADS-EXECUTED

echo "=== REST API hardening: enforce (image default)"
assert "REST users route is blocked"          403 /wp-json/wp/v2/users
assert "REST users subresource is blocked"    403 /wp-json/wp/v2/users/1
assert "REST users via rest_route is blocked" 403 "/?rest_route=/wp/v2/users"
assert "REST users trailing slash is blocked" 403 /wp-json/wp/v2/users/
assert "other REST routes still pass"         200 /wp-json/wp/v2/posts INDEX-EXECUTED
assert "unrelated rest_route still passes"    200 "/?rest_route=/wp/v2/posts" INDEX-EXECUTED

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
if docker logs "$NAME" 2>&1 | grep -q '\[rest-hardening\] 200 .*wp/v2/users'; then
    echo "ok:   report mode logs the would-be block"
else
    echo "FAIL: report mode did not log '[rest-hardening] 200 ... wp/v2/users'"
    FAILURES=$((FAILURES + 1))
fi

echo "=== REST API hardening: off"
cexec 'echo "# rest hardening disabled" > /etc/nginx/custom.d/00-rest-hardening.conf'
reload_nginx
assert "REST users passes in off mode" 200 /wp-json/wp/v2/users INDEX-EXECUTED

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "=== $FAILURES assertion(s) FAILED"
    exit 1
fi
echo "=== All assertions passed"
