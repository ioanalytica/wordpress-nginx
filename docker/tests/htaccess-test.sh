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

# render <helm args...>: extract the check from the chart rendered with these
# values, so policy, deniedPaths and the PHP allowlist reach it exactly as
# they would in a cluster.
render() {
    helm template tst "$CHART" "$@" > "$WORK/render.yaml"
    python3 - "$WORK" <<'PY'
import sys, yaml
work = sys.argv[1]
docs = [d for d in yaml.safe_load_all(open(f"{work}/render.yaml")) if d]
dep = next(d for d in docs if d.get("kind") == "Deployment")
script = dep["spec"]["template"]["spec"]["initContainers"][0]["args"][-1]
start = script.index('HTACCESS_POLICY=')
end = script.index('echo "Checks completed."')
open(f"{work}/check.sh", "w").write("set -e\n" + script[start:end] + 'echo "Checks completed."\n')
PY
}

# denied <path>...: sets ARGS to helm args declaring each path a deny entry.
# An array, not a word-split string: "deniedPaths[0]" is also a glob.
denied() {
    local i=0 p
    ARGS=()
    for p in "$@"; do
        ARGS+=(--set-json "nginx.deniedPaths[$i]={\"path\":\"$p\",\"action\":\"deny\"}")
        i=$((i + 1))
    done
}

# run <policy> <setup-script> [helm args...]  -> prints output, sets RC
run() {
    local policy="$1" setup="$2"; shift 2
    render --set "nginx.htaccessPolicy=$policy" "$@"
    OUT="$(docker run --rm -i \
        -v "$WORK/check.sh:/check.sh:ro" -v "$setup:/setup.sh:ro" busybox sh -c '
        mkdir -p /wordpress/wp-content; sh /setup.sh
        ash -e /check.sh; echo "RC=$?"' 2>&1)"
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
denied /wp-content/ai1wm-backups /wp-content/uploads/wpcf7_uploads
run fail "$WORK/styxnet.sh" "${ARGS[@]}"
expect_line "W3TC pub is plugin-managed, not deny"        'plugin-managed: /wp-content/plugins/w3-total-cache/pub/'
expect_line "W3TC ini is plugin-managed"                  'plugin-managed: /wp-content/plugins/w3-total-cache/ini/'
expect_line "W3TC minify is plugin-managed"               'plugin-managed: /wp-content/cache/minify/'
expect_line "allow-from-all in uploads is SUSPICIOUS"     'SUSPICIOUS: +/wp-content/uploads/2014/05/'
expect_line "captcha deny-with-exception is partial"      'partial: +/wp-content/uploads/wpcf7_captcha/'
expect_line "wpcf7_uploads blanket deny is covered"       'covered: +/wp-content/uploads/wpcf7_uploads/'
expect_line "ai1wm blanket deny is covered"               'covered: +/wp-content/ai1wm-backups/'
expect_rc   "nothing uncovered, fail mode starts"         0

echo "=== Real site, policy fail, ai1wm NOT covered"
denied /wp-content/uploads/wpcf7_uploads
run fail "$WORK/styxnet.sh" "${ARGS[@]}"
expect_line "ai1wm reported uncovered"                    'UNCOVERED: +/wp-content/ai1wm-backups/'
expect_line "proposal names the directory"                '- path: /wp-content/ai1wm-backups'
expect_rc   "blanket deny uncovered blocks start"         1

echo "=== Real site, partial directory wrongly listed"
denied /wp-content/uploads/wpcf7_captcha
run warn "$WORK/styxnet.sh" "${ARGS[@]}"
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
run fail "$WORK/edge.sh"
expect_line "Require all denied is a blanket deny"        'UNCOVERED: +/wp-content/r/'
expect_line "partial is not proposed"                     'partial: +/wp-content/a/'
expect_line "php allow in uploads is SUSPICIOUS"          'SUSPICIOUS: +/wp-content/uploads/b/'
expect_line "Options -Indexes is info"                    'info: +/wp-content/c/'
expect_rc   "only the blanket deny blocks"                1

echo "=== Edge cases, blanket deny covered, rest uncovered"
denied /wp-content/r
run fail "$WORK/edge.sh" "${ARGS[@]}"
expect_rc   "partial/allow/other never block fail mode"   0

cat > "$WORK/empty.sh" <<'SETUP'
W=/wordpress/wp-content
mkdir -p $W/empty $W/comments $W/real
: > $W/empty/.htaccess
printf '# BEGIN W3TC something\n#\n\n' > $W/comments/.htaccess
printf 'deny from all\n' > $W/real/.htaccess
SETUP
# grep exits 1 on a file with no directives. Under "set -e" - which the init
# container runs with - a failing command substitution in an assignment aborts
# the script, and the pod never starts. Any plugin leaving an empty or
# comments-only .htaccess behind would have taken the site down on next roll.
echo "=== Empty and comments-only .htaccess must not stop the init container"
run warn "$WORK/empty.sh"
expect_line "empty file reported as no access control"   'info: +/wp-content/empty/.htaccess is empty or only comments'
expect_line "comments-only reported the same way"        'info: +/wp-content/comments/.htaccess is empty or only comments'
expect_line "the real deny is still found"               'UNCOVERED: +/wp-content/real/'
expect_rc   "warn mode completes"                        0
denied /wp-content/real
run fail "$WORK/empty.sh" "${ARGS[@]}"
expect_rc   "fail mode is not tripped by empty files"    0

expect_no_line() {
    if printf '%s' "$OUT" | grep -qE -- "$2"; then
        echo "FAIL: $1 — found a line matching '$2'"; FAILURES=$((FAILURES + 1))
    else echo "ok:   $1"; fi
}

# Files found on the k3s-io fleet on 2026-10-28. The first version of the
# report flagged 21 directories there, 13 of them already closed: Wordfence's
# PHP-only guards (the PHP allowlist answers 403), backup-db under a regex
# deniedPaths entry, and uploads/.htaccess - for which it proposed denying
# /wp-content/uploads, i.e. every image on the site.
cat > "$WORK/fleet.sh" <<'SETUP'
W=/wordpress/wp-content
mkdir -p $W/plugins/wordfence/lib $W/wflogs $W/backup-db $W/uploads/wp_encryption $W/uploads/mixed
printf '<IfModule mod_rewrite.c>\n\tRewriteEngine On\n\tRewriteCond %%{REQUEST_URI} \\.php$\n\tRewriteRule .* - [F,L,NC]\n</IfModule>\n<IfModule !mod_rewrite.c>\n\t<FilesMatch "\\.php$">\n\t<IfModule mod_authz_core.c>\n\t\tRequire all denied\n\t</IfModule>\n\t<IfModule !mod_authz_core.c>\n\t\tOrder deny,allow\n\t\tDeny from all\n\t</IfModule>\n\t</FilesMatch>\n</IfModule>\n' > $W/plugins/wordfence/lib/.htaccess
: > $W/plugins/wordfence/lib/compat.php
printf '<IfModule mod_authz_core.c>\n\tRequire all denied\n</IfModule>\n<IfModule !mod_authz_core.c>\n\tOrder deny,allow\n\tDeny from all\n</IfModule>\n' > $W/wflogs/.htaccess
printf '<Files ~ ".*\\..*">\norder allow,deny\ndeny from all\n</Files>\n' > $W/backup-db/.htaccess
printf '<Files *.php>\ndeny from all\n</Files>\n' > $W/uploads/.htaccess
printf '<Files debug.log>\nOrder allow,deny\nDeny from all\n</Files>\n' > $W/uploads/wp_encryption/.htaccess
printf '<Files *.php>\ndeny from all\n</Files>\n<Files secret.txt>\ndeny from all\n</Files>\n' > $W/uploads/mixed/.htaccess
SETUP
BACKUP_RE='{"path":"~* ^/wp-content/[^/]*backup[^/]*(/|$)","action":"deny"}'

echo "=== Fleet files, PHP allowlist enforced, backup regex in deniedPaths"
run fail "$WORK/fleet.sh" --set-json "nginx.deniedPaths[0]=$BACKUP_RE"
expect_line "PHP-only guard is covered by the allowlist"  'covered: +/wp-content/plugins/wordfence/lib/.* denies PHP only; the PHP allowlist answers 403'
expect_line "uploads PHP guard is covered too"            'covered: +/wp-content/uploads/\.htaccess .* the PHP allowlist answers 403'
expect_no_line "uploads root is never proposed"           '- path: /wp-content/uploads$'
expect_line "regex deniedPaths entry covers backup-db"    'covered: +/wp-content/backup-db/'
expect_line "blanket deny still uncovered"                'UNCOVERED: +/wp-content/wflogs/'
expect_line "blanket deny proposes the directory"         '- path: /wp-content/wflogs$'
expect_line "named-file deny is reported per file"        'UNCOVERED: +/wp-content/uploads/wp_encryption/.* named files only: debug.log'
expect_line "named-file deny proposes the file"           '- path: /wp-content/uploads/wp_encryption/debug.log$'
expect_no_line "named-file deny never proposes the dir"   '- path: /wp-content/uploads/wp_encryption$'
expect_line "mixed file: named part reported"             'UNCOVERED: +/wp-content/uploads/mixed/.* named files only: secret.txt'
expect_rc   "uncovered denies block fail mode"            1

echo "=== Fleet files, every remaining deny closed"
run fail "$WORK/fleet.sh" --set-json "nginx.deniedPaths[0]=$BACKUP_RE" \
    --set-json 'nginx.deniedPaths[1]={"path":"/wp-content/wflogs","action":"deny"}' \
    --set-json 'nginx.deniedPaths[2]={"path":"/wp-content/uploads/wp_encryption/debug.log","action":"deny"}' \
    --set-json 'nginx.deniedPaths[3]={"path":"/wp-content/uploads/mixed","action":"deny"}'
expect_line "file entry covers the named file"            'covered: +/wp-content/uploads/wp_encryption/'
expect_line "directory entry covers its named files"      'covered: +/wp-content/uploads/mixed/'
expect_rc   "nothing uncovered, fail mode starts"         0

echo "=== PHP-only guard without the allowlist"
run fail "$WORK/fleet.sh" --set phpExecutionAllowlist.mode=off
expect_line "PHP-only guard uncovered with allowlist off" 'UNCOVERED: +/wp-content/plugins/wordfence/lib/.* denies PHP only'
expect_line "proposal closes PHP, not the directory"      "- path: '~\\* \\^/wp-content/plugins/wordfence/lib/\\.\\*\\\\\\.php\\$'"
expect_rc   "uncovered PHP blocks fail mode"              1

echo "=== PHP-only guard over PHP that extraAllowedPaths opens"
run warn "$WORK/fleet.sh" \
    --set-json 'phpExecutionAllowlist.extraAllowedPaths=["~*^/wp-content/plugins/wordfence/lib/compat\\.php$"]'
expect_line "allowlist exception is named"                'extraAllowedPaths lets PHP run here: /wp-content/plugins/wordfence/lib/compat.php'

echo "=== A deniedPaths regex busybox cannot compile covers nothing"
run warn "$WORK/fleet.sh" --set-json 'nginx.deniedPaths[0]={"path":"~* ^/wp-content/(?!x)wflogs/","action":"deny"}'
expect_line "PCRE-only entry leaves the directory open"   'UNCOVERED: +/wp-content/wflogs/'

echo
if [ "$FAILURES" -gt 0 ]; then echo "=== $FAILURES assertion(s) FAILED"; exit 1; fi
echo "=== All assertions passed"
