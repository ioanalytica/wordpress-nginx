#!/bin/bash
# Smoke test for the NGINX hardening in the wordpress-nginx image: the PHP
# execution allowlist and the REST API hardening.
#
# Verifies that PHP files are only executed from allowlisted entry points, that
# denied REST routes are refused through both of their spellings, that the
# report and off modes behave as documented for both features, and that the
# extra pattern directories take effect. It also checks that the container
# listens for HTTP on port 80 only and has no private key in its filesystem.
# Run against a locally built image:
#
#   ./smoke-test.sh ghcr.io/ioanalytica/wordpress-nginx:test

set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh <image-ref>}"
NAME="wpnginx-smoke-$$"
FAILURES=0

cleanup() {
    docker rm -f "$NAME" "$NAME-dbwait" "$NAME-dbstall" >/dev/null 2>&1 || true
    rm -f "${DBWAIT_CONFIG:-}"
}
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

echo "=== HTTP on port 80 only, no key material"
# TLS ends at the Ingress, so the image has no listener on 443 and no
# private key in its filesystem. The base image brings both; the Dockerfile
# removes them.
# check <description> <command run in the container>: the command succeeds.
check() {
    if cexec "$2" >/dev/null 2>&1; then
        echo "ok:   $1"
    else
        echo "FAIL: $1"
        FAILURES=$((FAILURES + 1))
    fi
}
# Every listening socket as "protocol/port", TCP and UDP (HTTP/3 is UDP).
# Port 2020 is the health server the base image's start hook sets up; a
# third port is a listener nobody decided on.
listeners="$(cexec "netstat -tuln | awk '\$1 ~ /^(tcp|udp)/ { n = split(\$4, a, \":\"); print \$1 \"/\" a[n] }' | sort -u | tr '\n' ' '")"
if [ "$listeners" = "tcp/2020 tcp/80 " ]; then
    echo "ok:   the container listens on port 80 and the health port only ($listeners)"
else
    echo "FAIL: the container listens on '$listeners', expected 'tcp/2020 tcp/80 '"
    FAILURES=$((FAILURES + 1))
fi
# favicon.ico and a static file: a request that reached PHP here would put
# the image's index.php into opcache, see above.
check "nothing answers on port 443"                   '! curl -sk -o /dev/null --max-time 5 https://localhost/favicon.ico'
# The dump has to succeed first: no output is no TLS directive either.
check "the NGINX configuration has no TLS directive"  'nginx -T >/tmp/smoke-nginx-T 2>/dev/null && grep -q "^[[:space:]]*listen" /tmp/smoke-nginx-T && ! grep -E "^[[:space:]]*(ssl_|http3|listen[^;]*(443|ssl|quic))" /tmp/smoke-nginx-T'
# The header rides on answers with a status like 200 only, so ask for a file
# that exists.
check "no response announces HTTP/3"                  'echo x >/var/www/html/smoke-static.txt && curl -sI http://localhost/smoke-static.txt | grep -q "^HTTP/1.1 200" && ! curl -sI http://localhost/smoke-static.txt | grep -i "^alt-svc:"'
check "/etc/ssl/site is gone"                         '[ ! -e /etc/ssl/site ]'
check "no private key under /etc/ssl and /etc/nginx"  '! grep -rlE -e "-----BEGIN [A-Z ]*PRIVATE KEY-----" /etc/ssl /etc/nginx'

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
mkdir -p /var/www/html/wp-content/uploads/dlm_uploads /var/www/html/wp-content/plugins/retired-plugin/assets
echo "ZIP-CONTENT" > /var/www/html/wp-content/uploads/dlm_uploads/report.zip
echo "<?php echo \"HONEYPOT-EXECUTED\";" > /var/www/html/wp-content/plugins/retired-plugin/assets/callback.php
'
assert "dlm_uploads served by default"   200 /wp-content/uploads/dlm_uploads/report.zip ZIP-CONTENT

echo "=== Denied paths: as the chart renders them"
cexec 'cat > /etc/nginx/denied-paths.d/10-chart.conf <<EOF
"~*^/wp-content/uploads/dlm_uploads(/|\$)" 403;
"~*^/wp-content/plugins/retired-plugin/" 418;
EOF'
reload_nginx
# The directory rule must hold for extensions the static-file location matches.
# A plain prefix location would lose to that regex location and serve the zip.
assert "denied dir: zip is refused"       403 /wp-content/uploads/dlm_uploads/report.zip
assert "denied dir: directory itself"     403 /wp-content/uploads/dlm_uploads/
assert "denied dir: no prefix overreach"  404 /wp-content/uploads/dlm_uploads_other/x.zip
# The honeypot status must survive the PHP allowlist, which would answer 403
# for this .php path if it ran first.
assert "honeypot answers 418, not 403"    418 /wp-content/plugins/retired-plugin/assets/callback.php
assert "unrelated uploads unaffected"     404 /wp-content/uploads/other.zip
assert_not_executed "honeypot never reaches PHP" /wp-content/plugins/retired-plugin/assets/callback.php HONEYPOT-EXECUTED
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
# The honeypot must keep answering 418 on a retired host: probers ban
# themselves whatever hostname they use.
cexec 'cat > /etc/nginx/denied-paths.d/10-chart.conf <<EOF
"~*^/wp-content/plugins/retired-plugin/" 418;
EOF'
reload_nginx
assert_gone "honeypot outranks gone on a retired host" 418 forum.example.com /wp-content/plugins/retired-plugin/assets/callback.php "$CRAWLER"
cexec 'rm /etc/nginx/denied-paths.d/10-chart.conf /etc/nginx/gone-hosts.d/10-chart.conf'
cexec 'echo "# php allowlist disabled" > /etc/nginx/custom.d/00-php-allowlist.conf'
reload_nginx
assert_gone "cleanup: retired host serves again"   200 forum.example.com / "$CRAWLER"

echo "=== Application hook: single files in /etc/hooks/application execute"
# The chart mounts post-init scripts as single executable files into this
# directory. Pin the image-side contract the chart depends on: run-parts
# executes plain executable files there, in lexical order after the
# image's init-wordpress. (A directory mount is NOT traversed - that is
# why the pre-7.1.0-9 chart executed nothing.)
cexec 'printf "#!/bin/sh\necho POSTINIT-MARKER-RAN\n" > /etc/hooks/application/zz-99-smoke-marker.sh && chmod 0755 /etc/hooks/application/zz-99-smoke-marker.sh'
hook_out="$(cexec 'hook application 2>&1' || true)"
if printf '%s' "$hook_out" | grep -q POSTINIT-MARKER-RAN; then
    echo "ok:   application hook executes a mounted single file"
else
    echo "FAIL: application hook did not execute zz-99-smoke-marker.sh"
    FAILURES=$((FAILURES + 1))
fi
cexec 'rm /etc/hooks/application/zz-99-smoke-marker.sh'

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

echo "=== NGINX closes its connection to PHP-FPM after every request"
# With fastcgi_keep_conn on, which the base image sets, a PHP-FPM worker
# stays bound to the connection for a minute after the response, and five
# requests exhaust the pool. The Dockerfile switches it off. The PHP request
# goes to index.php, which the fixtures above replaced; the sockets of the
# earlier requests are closed by now.
# The dump has to succeed first, as above. The negative grep reads the dump
# with its comments stripped and matches the directives wherever they stand
# on a line.
check "the NGINX configuration has fastcgi_keep_conn off" 'nginx -T >/tmp/smoke-nginx-T 2>/dev/null && grep -qE "^[[:space:]]*fastcgi_keep_conn[[:space:]]+off;" /tmp/smoke-nginx-T && ! sed -E "s/#.*//" /tmp/smoke-nginx-T | grep -E "(^|[[:space:];{])(fastcgi_keep_conn[[:space:]]+on([[:space:];]|$)|keepalive[[:space:]]+[0-9])"'
# /proc/net/unix lists the listening socket once and every open connection
# to it once more; two seconds after a PHP request only the listener is left.
# curl -f: a request that PHP did not answer proves nothing about the socket.
check "no connection to PHP-FPM stays open after a request" 'curl -fs -o /dev/null http://localhost/index.php && sleep 2 && [ "$(grep -c /run/php-fpm.sock /proc/net/unix)" = 1 ]'

echo "=== SMTP sendmail wrapper composes msmtp options from the env"
# The chart's SMTP values become environment variables; the wrapper turns them
# into an msmtp command line. Hermetic: a stub msmtp earlier in PATH captures
# that command line - no network, no real msmtp. docker exec does not inherit
# the entrypoint's .env exports, so SMTP_* is unset here unless an assertion
# sets it - exactly like a pod deployed without the chart's SMTP values.
cexec 'mkdir -p /tmp/stub \
  && printf "%s\n" "#!/bin/sh" "echo \"\$@\" > /tmp/msmtp-args" "cat > /tmp/msmtp-msg" > /tmp/stub/msmtp \
  && chmod 0755 /tmp/stub/msmtp'

# assert_args <description> <"present"|"absent"> <needle> <env-prefix>
# Sends a minimal message through the wrapper with the given SMTP_* variables
# and asserts on the msmtp arguments the wrapper composed.
assert_args() {
    local desc="$1" mode="$2" needle="$3" env="$4" args
    cexec 'rm -f /tmp/msmtp-args'
    args="$(docker exec "$NAME" sh -c "printf 'From: a@example.com\nTo: b@example.com\nSubject: t\n\nx\n' | PATH=/tmp/stub:\$PATH $env /usr/local/utils/sendmail -t >/dev/null 2>&1; cat /tmp/msmtp-args 2>/dev/null")"
    if printf '%s' "$args" | grep -qF -- "$needle"; then
        if [ "$mode" = present ]; then echo "ok:   $desc"
        else echo "FAIL: $desc — found '$needle' in: $args"; FAILURES=$((FAILURES + 1)); fi
    else
        if [ "$mode" = absent ]; then echo "ok:   $desc"
        else echo "FAIL: $desc — expected '$needle', wrapper composed: $args"; FAILURES=$((FAILURES + 1)); fi
    fi
}

assert_args "host reaches msmtp"                    present "--host=relay"       'SMTP_HOST=relay'
assert_args "port reaches msmtp"                    present "--port=587"         'SMTP_HOST=relay SMTP_PORT=587'
assert_args "TLS on requests STARTTLS"              present "--tls=on"           'SMTP_HOST=relay SMTP_TLS=on'
assert_args "TLS on leaves the STARTTLS default"    absent  "--tls-starttls"     'SMTP_HOST=relay SMTP_TLS=on'
assert_args "implicit TLS disables STARTTLS"        present "--tls-starttls=off" 'SMTP_HOST=relay SMTP_TLS=on SMTP_STARTTLS=off'
assert_args "user switches auth on"                 present "--auth=on"          'SMTP_HOST=relay SMTP_USER=u'
# The chart documents smtpProtocol="" against these: no TLS without
# credentials, TLS by default with them, and SMTP_TLS=off (smtpProtocol
# "none") as the only way to authenticate unencrypted.
assert_args "no credentials, no TLS by default"     absent  "--tls="             'SMTP_HOST=relay'
assert_args "credentials switch TLS on by default"  present "--tls=on"           'SMTP_HOST=relay SMTP_USER=u'
assert_args "TLS off survives credentials"          present "--tls=off"          'SMTP_HOST=relay SMTP_USER=u SMTP_TLS=off'
assert_args "from email sets the envelope sender"   present "--from=news@example.com" 'SMTP_HOST=relay SMTP_FROM=news@example.com'
assert_args "no from falls back to the message"     present "--read-envelope-from" 'SMTP_HOST=relay'
assert_args "password goes through passwordeval"    present "--passwordeval="    'SMTP_HOST=relay SMTP_PASSWORD=s3cretpw'
assert_args "password itself never lands in argv"   absent  "s3cretpw"           'SMTP_HOST=relay SMTP_PASSWORD=s3cretpw'

# Without SMTP_HOST the wrapper must refuse loudly (pinned since 7.1.0-12),
# not resolve a nonexistent default host and fail silently.
nohost_out="$(docker exec "$NAME" sh -c "printf 'x\n' | PATH=/tmp/stub:\$PATH /usr/local/utils/sendmail -t 2>&1; echo rc=\$?")"
if printf '%s' "$nohost_out" | grep -q 'SMTP_HOST is not defined' \
        && printf '%s' "$nohost_out" | grep -q 'rc=1'; then
    echo "ok:   missing SMTP_HOST refuses loudly"
else
    echo "FAIL: missing SMTP_HOST did not refuse loudly: $nohost_out"
    FAILURES=$((FAILURES + 1))
fi

echo "=== SMTP wrapper rewrites the From header when SMTP_FROM is set"
# With SMTP_FROM set, the message's From header must leave the pod matching
# the envelope (Office 365 rejects a mismatch with SendAsDenied); the body
# must never be touched. Same stub msmtp - assertions run on the message it
# captured.

# assert_msg <description> <"present"|"absent"> <needle> <env-prefix> <message-file>
assert_msg() {
    local desc="$1" mode="$2" needle="$3" env="$4" msgfile="$5" msg
    cexec 'rm -f /tmp/msmtp-msg'
    msg="$(docker exec "$NAME" sh -c "PATH=/tmp/stub:\$PATH $env /usr/local/utils/sendmail -t < $msgfile >/dev/null 2>&1; cat /tmp/msmtp-msg 2>/dev/null")"
    if printf '%s' "$msg" | grep -qF -- "$needle"; then
        if [ "$mode" = present ]; then echo "ok:   $desc"
        else echo "FAIL: $desc — found '$needle' in message:"; printf '%s\n' "$msg" | sed 's/^/      /'; FAILURES=$((FAILURES + 1)); fi
    else
        if [ "$mode" = absent ]; then echo "ok:   $desc"
        else echo "FAIL: $desc — expected '$needle' in message:"; printf '%s\n' "$msg" | sed 's/^/      /'; FAILURES=$((FAILURES + 1)); fi
    fi
}

cexec 'printf "From: WordPress <wordpress@pod.local>\nTo: b@example.com\nSubject: t\n\nbody keeps From: wordpress@pod.local intact\n" > /tmp/msg-plain'
cexec 'printf "From: WordPress\n <wordpress@pod.local>\nTo: b@example.com\nSubject: t\n\nx\n" > /tmp/msg-folded'
cexec 'printf "To: b@example.com\nSubject: t\n\nx\n" > /tmp/msg-nofrom'

FROMENV='SMTP_HOST=relay SMTP_FROM=news@example.com'
assert_msg "header From is replaced"            present 'From: news@example.com'    "$FROMENV" /tmp/msg-plain
assert_msg "the old From does not survive"      absent  'wordpress@pod.local>'      "$FROMENV" /tmp/msg-plain
assert_msg "body From-text is never touched"    present 'body keeps From: wordpress@pod.local intact' "$FROMENV" /tmp/msg-plain
assert_msg "display name wraps the address"     present 'From: "IO Analytica" <news@example.com>' \
        "$FROMENV SMTP_FROM_NAME='IO Analytica'" /tmp/msg-plain
assert_msg "non-ASCII name is RFC 2047 encoded" present 'From: =?UTF-8?B?'          "$FROMENV SMTP_FROM_NAME='Müller'" /tmp/msg-plain
assert_msg "folded From is replaced entirely"   absent  '<wordpress@pod.local>'     "$FROMENV" /tmp/msg-folded
assert_msg "folded From leaves one From only"   present 'From: news@example.com'    "$FROMENV" /tmp/msg-folded
assert_msg "missing From gets one inserted"     present 'From: news@example.com'    "$FROMENV" /tmp/msg-nofrom
assert_msg "without SMTP_FROM nothing changes"  present 'From: WordPress <wordpress@pod.local>' 'SMTP_HOST=relay' /tmp/msg-plain
# Unmodified means byte-identical, not just header-equal.
if docker exec "$NAME" sh -c 'cmp -s /tmp/msg-plain /tmp/msmtp-msg'; then
    echo "ok:   without SMTP_FROM the message passes through byte-identical"
else
    echo "FAIL: without SMTP_FROM the message was altered"
    FAILURES=$((FAILURES + 1))
fi
cexec 'rm -rf /tmp/stub /tmp/msmtp-args /tmp/msmtp-msg /tmp/msg-plain /tmp/msg-folded /tmp/msg-nofrom'

echo "=== The start hands the upload directories that belong to root to the web user"
# An installation made while the installer still ran as root has its upload
# directory, and the year and month below it, with root as the owner. The
# application hook hands exactly these to the web user; here it is run once
# more in the running container, on a tree made for it. Files, other
# directories and what a symbolic link points to stay as they are: the hook
# runs as root on a tree the web user can write. A limit with a leading
# zero, which the shell would take for an octal number, must not stop the
# hook either.
cexec '
u=/var/www/html/wp-content/uploads
mkdir -p $u/2026/11 $u/2026/11/deeper $u/plugin-data /tmp/outside/11
echo x > $u/2026/11/root-owned.txt && echo x > $u/2026/11/other-owned.txt
ln -s /tmp/outside $u/2027
chown -R root:root $u /tmp/outside && chown 12345:12345 $u/2026/11/other-owned.txt
WORDPRESS_DB_WAIT_TIMEOUT=08 DISABLE_GREETING=1 /etc/hooks/application/init-wordpress >/tmp/hook.log 2>&1 || true'
# assert_owner <description> <expected user:group, numeric> <path>
assert_owner() {
    local got
    got="$(cexec "stat -c '%u:%g' '$3'")"
    if [ "$got" = "$2" ]; then echo "ok:   $1"
    else echo "FAIL: $1 — owner is $got, expected $2"; FAILURES=$((FAILURES + 1)); fi
}
web_ids="$(cexec 'echo "$(id -u www-data):$(id -g www-data)"')"
U=/var/www/html/wp-content/uploads
assert_owner "the upload directory belongs to the web user"       "$web_ids"     "$U"
assert_owner "so does the directory of the year"                  "$web_ids"     "$U/2026"
assert_owner "and the directory of the month"                     "$web_ids"     "$U/2026/11"
assert_owner "a file root owns stays root's"                      "0:0"          "$U/2026/11/root-owned.txt"
assert_owner "a file of a third user keeps its owner"             "12345:12345"  "$U/2026/11/other-owned.txt"
assert_owner "a directory below the month is not walked into"     "0:0"          "$U/2026/11/deeper"
assert_owner "a directory that is no year stays root's"           "0:0"          "$U/plugin-data"
assert_owner "a year that is a link leaves its target alone"      "0:0"          /tmp/outside
assert_owner "and what lies behind the link"                      "0:0"          /tmp/outside/11
if cexec 'grep -q "arithmetic\|octal\|syntax error" /tmp/hook.log'; then
    echo "FAIL: the hook stumbles over a limit with a leading zero: $(cexec 'cat /tmp/hook.log')"; FAILURES=$((FAILURES + 1))
else echo "ok:   a limit with a leading zero is read as a decimal number"; fi
if cexec 'grep -q "Handed /var/www/html/wp-content/uploads over" /tmp/hook.log'; then echo "ok:   the hook says what it hands over"
else echo "FAIL: the hook does not say that it hands the directory over: $(cexec 'cat /tmp/hook.log')"; FAILURES=$((FAILURES + 1)); fi
cexec 'rm -rf /var/www/html/wp-content/uploads/2026 /var/www/html/wp-content/uploads/2027 /var/www/html/wp-content/uploads/plugin-data /tmp/outside /tmp/hook.log'

echo "=== The start waits for a database that does not answer, up to its limit"
# WordPress is installed by the application hook, once per container start.
# With a wp-config.php that names a database that does not answer, the hook
# must ask again instead of running the installer against nothing, say that
# it waits, and after WORDPRESS_DB_WAIT_TIMEOUT let the container start.
# Containers of their own: the first one has no wp-config.php, and its start
# is over.
DBWAIT_CONFIG="$(mktemp)"
dbwait_log=""
# dbwait_start <container> <db-host> - start a container whose wp-config.php
# names <db-host>, with a wait of 8 seconds; its log goes to $dbwait_log once
# nginx is up, which is after the application hook.
dbwait_start() {
    local name="$1" host="$2" i
    cat > "$DBWAIT_CONFIG" <<PHP
<?php
define( 'DB_NAME', 'wordpress' );
define( 'DB_USER', 'wordpress' );
define( 'DB_PASSWORD', 'not-a-real-password' );
define( 'DB_HOST', '$host' );
\$table_prefix = 'wp_';
if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
PHP
    chmod 0644 "$DBWAIT_CONFIG"
    docker create --name "$name" -e WORDPRESS_DB_WAIT_TIMEOUT=8 "$IMAGE" >/dev/null
    docker cp "$DBWAIT_CONFIG" "$name:/var/www/html/wp-config.php" >/dev/null
    docker start "$name" >/dev/null
    for i in $(seq 1 90); do
        if docker exec "$name" sh -c 'curl -s -o /dev/null http://localhost/favicon.ico' 2>/dev/null; then break; fi
        [ "$i" = 90 ] && { echo "FAIL: nginx of $name did not come up after the database wait"; FAILURES=$((FAILURES + 1)); }
        sleep 1
    done
    dbwait_log="$(docker logs "$name" 2>&1)"
}
# assert_log <description> <"present"|"absent"> <needle>
assert_log() {
    if grep -qF -- "$3" <<<"$dbwait_log"; then
        if [ "$2" = present ]; then echo "ok:   $1"
        else echo "FAIL: $1 — the log has '$3'"; FAILURES=$((FAILURES + 1)); fi
    else
        if [ "$2" = absent ]; then echo "ok:   $1"
        else echo "FAIL: $1 — the log lacks '$3'"; FAILURES=$((FAILURES + 1)); fi
    fi
}

# A port nobody listens at: the connection is refused at once.
dbwait_start "$NAME-dbwait" 127.0.0.1:3306
# Not the seconds waited so far: the first try may cross a second's boundary.
assert_log "refused: the hook says that it waits for the database" present "Waiting for the database ("
assert_log "refused: the wait names its limit"                     present " s of at most 8 s)"
assert_log "refused: the wait ends at its limit"                   present "The database did not answer within 8 s"
assert_log "refused: the log names what WordPress could not reach" present "Error establishing a database connection"
assert_log "refused: the installer is not run against no database" absent  "Running Wordpress installer"
assert_log "refused: the container starts after the wait"          present "ready to handle connections"

# A server that takes the connection and then says nothing, as a database
# proxy without its database does. The first container's nginx is one: it
# waits for a request, a MySQL client waits for the server's greeting. The
# connect timeout does not end such a try; the limit on the process does,
# and with a wait of 8 seconds the first try already uses it up.
stall_host="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME")"
stall_started=$(date +%s)
dbwait_start "$NAME-dbstall" "$stall_host:80"
stall_took=$(( $(date +%s) - stall_started ))
assert_log "silent server: a try is cut off"                       present "No answer within"
assert_log "silent server: the wait ends at its limit"             present "The database did not answer within 8 s"
assert_log "silent server: the installer is not run"               absent  "Running Wordpress installer"
# nginx would hold the connection for a minute; one try of eight seconds and
# the container's own start fit into forty.
if [ "$stall_took" -le 40 ]; then echo "ok:   silent server: the container starts after ${stall_took} s"
else echo "FAIL: silent server: the container needed ${stall_took} s to start"; FAILURES=$((FAILURES + 1)); fi

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "=== $FAILURES assertion(s) FAILED"
    exit 1
fi
echo "=== All assertions passed"
