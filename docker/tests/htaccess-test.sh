#!/bin/bash
# Tests the init container's .htaccess classifier against real-world files.
#
# Renders the chart, extracts the check from the init script and runs it in
# busybox - the image the init container uses - on a wp-content tree rebuilt
# from files found on a live site on 2026-08-23. Every one of those had been
# mis-handled by the first version of the check, which proposed "deny" for all
# of them; three of seven would have broken the site or hidden a forensic lead.
#
#   ./htaccess-test.sh [chart-dir]

set -euo pipefail
CHART="${1:-$(dirname "$0")/../../chart}"
FAILURES=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

helm template tst "$CHART" > "$WORK/render.yaml"
python3 - "$WORK" <<'PY'
import sys, yaml
work = sys.argv[1]
docs = [d for d in yaml.safe_load_all(open(f"{work}/render.yaml")) if d]
dep = next(d for d in docs if d.get("kind") == "Deployment")
script = dep["spec"]["template"]["spec"]["initContainers"][0]["args"][-1]
start = script.index('echo "Checking wp-content for .htaccess')
end = script.index('echo "Checks completed."')
open(f"{work}/check.sh", "w").write("set -e\n" + script[start:end] + 'echo "Checks completed."\n')
PY

# run <policy> <prefixes> <setup-script>  -> prints output, sets RC
run() {
    local policy="$1" prefixes="$2" setup="$3"
    OUT="$(docker run --rm -i -e POLICY="$policy" -e PREFIXES="$prefixes" \
        -v "$WORK/check.sh:/check.sh:ro" -v "$setup:/setup.sh:ro" busybox sh -c '
        mkdir -p /wordpress/wp-content; sh /setup.sh
        sed -e "s|^ *HTACCESS_POLICY=.*|HTACCESS_POLICY=\"$POLICY\"|" \
            -e "s|^ *DENIED_PREFIXES=.*|DENIED_PREFIXES=\"$PREFIXES\"|" /check.sh > /run.sh
        ash -e /run.sh; echo "RC=$?"' 2>&1)"
    RC="$(printf '%s' "$OUT" | sed -n 's/^RC=//p' | tail -1)"
}

# expect_line <desc> <grep-pattern>
expect_line() {
    if printf '%s' "$OUT" | grep -qE -- "$2"; then echo "ok:   $1"
    else echo "FAIL: $1 — no line matching '$2'"; FAILURES=$((FAILURES + 1)); fi
}
expect_rc() {
    if [ "$RC" = "$2" ]; then echo "ok:   $1 (exit $RC)"
    else echo "FAIL: $1 — exit $RC, expected $2"; FAILURES=$((FAILURES + 1)); fi
}

cat > "$WORK/styxnet.sh" <<'SETUP'
W=/wordpress/wp-content
mkdir -p $W/plugins/w3-total-cache/ini $W/plugins/w3-total-cache/pub $W/uploads/2014/05 $W/uploads/wpcf7_captcha $W/uploads/wpcf7_uploads $W/cache/minify $W/ai1wm-backups
printf '<IfModule mod_authz_core.c>\n\tRequire all denied\n</IfModule>\n<FilesMatch "^\\.">\nRequire all denied\n</FilesMatch>\n' > $W/plugins/w3-total-cache/ini/.htaccess
printf '# pub/.htaccess\n<IfModule mod_rewrite.c>\nRewriteEngine On\nRewriteRule \\.php$ - [F]\n</IfModule>\n' > $W/plugins/w3-total-cache/pub/.htaccess
printf '<Files .*>\r\nRewriteEngine off\r\nallow from all\r\n</Files>\r\n<Files ~ "\\.(php|phtml|PHP)$">\r\nRewriteEngine off\r\nallow from all\r\n</Files>\r\n' > $W/uploads/2014/05/.htaccess
printf 'Order deny,allow\nDeny from all\n<Files ~ "^[0-9A-Za-z]+\\.(jpeg|gif|png)$">\n    Allow from all\n</Files>\n' > $W/uploads/wpcf7_captcha/.htaccess
printf '<IfModule authz_core_module>\n    Require all denied\n</IfModule>\n' > $W/uploads/wpcf7_uploads/.htaccess
printf '# BEGIN W3TC Minify core\n<IfModule mod_rewrite.c>\nRewriteRule .* index.php [L]\n</IfModule>\n' > $W/cache/minify/.htaccess
printf 'deny from all\n' > $W/ai1wm-backups/.htaccess
printf '%s\n' 'location ~* /w3-total-cache/ini/ { deny all; }' 'location ~* /w3-total-cache/pub/(?!sns\.php$)[^/]+\.php$ { deny all; }' 'rewrite ^/wp-content/cache/minify/ /index.php last;' > /wordpress/nginx.conf
SETUP

echo "=== Real site, policy fail, corrected deniedPaths"
run fail "/wp-content/ai1wm-backups /wp-content/uploads/wpcf7_uploads" "$WORK/styxnet.sh"
expect_line "W3TC pub is plugin-managed, not deny"        'plugin-managed: /wp-content/plugins/w3-total-cache/pub/'
expect_line "W3TC ini is plugin-managed"                  'plugin-managed: /wp-content/plugins/w3-total-cache/ini/'
expect_line "W3TC minify is plugin-managed"               'plugin-managed: /wp-content/cache/minify/'
expect_line "allow-from-all in uploads is SUSPICIOUS"     'SUSPICIOUS: +/wp-content/uploads/2014/05/'
expect_line "captcha deny-with-exception is partial"      'partial: +/wp-content/uploads/wpcf7_captcha/'
expect_line "wpcf7_uploads blanket deny is covered"       'covered: +/wp-content/uploads/wpcf7_uploads/'
expect_line "ai1wm blanket deny is covered"               'covered: +/wp-content/ai1wm-backups/'
expect_rc   "nothing uncovered, fail mode starts"         0

echo "=== Real site, policy fail, ai1wm NOT covered"
run fail "/wp-content/uploads/wpcf7_uploads" "$WORK/styxnet.sh"
expect_line "ai1wm reported uncovered"                    'UNCOVERED: +/wp-content/ai1wm-backups/'
expect_line "proposal names the directory"                '- path: /wp-content/ai1wm-backups'
expect_rc   "blanket deny uncovered blocks start"         1

echo "=== Real site, partial directory wrongly listed"
run warn "/wp-content/uploads/wpcf7_captcha" "$WORK/styxnet.sh"
expect_line "warns that a deny breaks the exception"      'WARNING: +/wp-content/uploads/wpcf7_captcha is in nginx.deniedPaths'

cat > "$WORK/edge.sh" <<'SETUP'
W=/wordpress/wp-content
mkdir -p $W/a $W/uploads/b $W/c $W/r
printf 'Deny from all\n<Files ~ "\\.png$">\nAllow from all\n</Files>\n' > $W/a/.htaccess
printf '<Files ~ "\\.php$">\nallow from all\n</Files>\n' > $W/uploads/b/.htaccess
printf 'Options -Indexes\n' > $W/c/.htaccess
printf 'Require all denied\n' > $W/r/.htaccess
SETUP
echo "=== Edge cases, policy fail, nothing covered"
run fail "" "$WORK/edge.sh"
expect_line "Require all denied is a blanket deny"        'UNCOVERED: +/wp-content/r/'
expect_line "partial is not proposed"                     'partial: +/wp-content/a/'
expect_line "php allow in uploads is SUSPICIOUS"          'SUSPICIOUS: +/wp-content/uploads/b/'
expect_line "Options -Indexes is info"                    'info: +/wp-content/c/'
expect_rc   "only the blanket deny blocks"                1

echo "=== Edge cases, blanket deny covered, rest uncovered"
run fail "/wp-content/r" "$WORK/edge.sh"
expect_rc   "partial/allow/other never block fail mode"   0

echo
if [ "$FAILURES" -gt 0 ]; then echo "=== $FAILURES assertion(s) FAILED"; exit 1; fi
echo "=== All assertions passed"
