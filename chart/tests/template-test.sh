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
    # Herestring, NOT a pipe: grep -q exits on the first match, and a
    # printf still writing into the closed pipe then fails with EPIPE.
    # Under `pipefail` that makes a FOUND needle report as not found -
    # GitHub's runner ignores SIGPIPE, so this fired in CI only.
    if grep -qF -- "$needle" <<<"$out"; then
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
# Same class of drift for the sidecar: idxImageTag and the images annotation
# are two separate spots, and only the annotation feeds provenance tooling -
# in 7.1.0-16 the annotation kept the previous sidecar tag unnoticed.
idx_tag=$(sed -n 's/^  idxImageTag: *"\(.*\)"$/\1/p' "$CHART/Chart.yaml")
idx_images=$(sed -n 's|^      image: ghcr.io/ioanalytica/wordpress-idx:||p' "$CHART/Chart.yaml")
idx_rendered=$(helm template tst "$CHART" --set idx.enabled=true | sed -n 's|.*image: "*ghcr.io/ioanalytica/wordpress-idx:||p' | tr -d '"' | head -1)
if [ "$idx_tag" = "$idx_images" ] && [ "$idx_tag" = "$idx_rendered" ]; then
    echo "ok:   idxImageTag, images annotation and rendered sidecar all say $idx_tag"
else
    echo "FAIL: idxImageTag=$idx_tag images=$idx_images rendered=$idx_rendered - must be identical"
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
check "gone hosts set"              --set ingress.enabled=true \
                                    --set ingress.ingressClassName=traefik \
                                    --set redirect.enabled=true \
                                    --set redirect.targetUrl=https://example.com \
                                    --set 'redirect.hosts={www.example.com}' \
                                    --set 'redirect.goneHosts={forum.example.com}'
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
# The init container's .htaccess report tests coverage with the very regexes
# NGINX gets, one per line - plain paths as their anchored form, regex entries
# verbatim - so a directory only a regex entry closes counts as covered.
# The needles carry the init script's indentation: the same regexes also
# appear in the NGINX ConfigMaps and would match there.
expect "init gets plain paths as regex"    present '              ^/wp-content/uploads/x(/|$)' \
        --set 'nginx.deniedPaths[0].path=/wp-content/uploads/x'
expect "init gets regex entries too"       present '              ^/wp-content/themes/evil/' \
        --set 'nginx.deniedPaths[0].path=~* ^/wp-content/themes/evil/'
check  "several entries keep the manifest valid" -f "$(dirname "$0")/fixtures/denied-paths-multi.yaml"
expect "init gets the PHP allowlist mode"  present 'PHP_ALLOWLIST_MODE="enforce"'
expect "init gets extra allowed PHP"       present '              ^/wp-content/plugins/p/cb\.php$' \
        --set-json 'phpExecutionAllowlist.extraAllowedPaths=["~*^/wp-content/plugins/p/cb\\.php$"]'
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

echo "=== Gone hosts render what they claim"
# Shared argument sets. GONE declares one retired host next to one alias
# host; GONE_ONLY has no alias host at all, which must also be valid.
# redirect.enabled requires a valid ingressClassName, hence traefik here.
GONE=(--set ingress.ingressClassName=traefik
      --set redirect.enabled=true --set redirect.targetUrl=https://example.com
      --set 'redirect.hosts={www.example.com}'
      --set 'redirect.goneHosts={forum.example.com}')
GONE_ONLY=(--set ingress.ingressClassName=traefik
           --set redirect.enabled=true --set redirect.targetUrl=https://example.com
           --set 'redirect.goneHosts={forum.example.com}')
expect "no goneHosts renders no configmap"   absent  "nginx-gone-hosts"
expect "goneHosts without redirect is inert" absent  "nginx-gone-hosts" \
        --set 'redirect.goneHosts={forum.example.com}'
expect "gone host becomes a map entry"       present '"forum.example.com" "https://example.com/";' "${GONE[@]}"
expect "target is normalized to one slash"   present '"forum.example.com" "https://example.com/";' \
        "${GONE_ONLY[@]}" --set redirect.targetUrl=https://example.com/
expect "gone hosts have a checksum"          present "checksum/nginx-gone-hosts" "${GONE[@]}"
expect "gone host rides the primary ingress" present 'host: "forum.example.com"' \
        --set ingress.enabled=true "${GONE[@]}"
expect "gone host gets a shim TLS entry"     present "gone-tls" \
        --set ingress.enabled=true \
        --set-string 'ingress.annotations.cert-manager\.io/cluster-issuer=letsencrypt-prod' \
        "${GONE[@]}"
# The controller-level redirect must never see a gone host: a redirect
# answered at the ingress would keep NGINX from ever making the 410 call.
expect "gone host not in the IngressRoute"   absent  'Host(`forum.example.com`)' "${GONE[@]}"
expect "alias host still in the IngressRoute" present 'Host(`www.example.com`)' "${GONE[@]}"
expect "goneHosts alone emit no redirect"    absent  "redirectRegex" "${GONE_ONLY[@]}"
expect "goneHosts alone still map"           present '"forum.example.com" "https://example.com/";' "${GONE_ONLY[@]}"

echo "=== Post-init scripts reach the application hook"
# The image's hook runner executes plain executable files in
# /etc/hooks/application via run-parts: no subdirectories, no
# non-executable files. These pin the mount shape that makes the scripts
# actually run - the previous directory mount at /etc/hook/ (singular)
# silently executed nothing.
expect "preinstall renders by default"      present 'wp plugin install "two-factor"'
expect "preinstall mounts as a single file" present 'mountPath: /etc/hooks/application/zz-00-preinstall-plugins.sh'
expect "scripts are mounted executable"     present 'defaultMode: 0750'
expect "postinit has a checksum"            present 'checksum/postinit'
expect "the dead singular path is gone"     absent  '/etc/hook/application'
expect "no preinstall when emptied"         absent  'preinstall-plugins' \
        --set-json 'wordpressPreinstallPlugins=[]'
expect "cache config guards on active W3TC" present 'if ! wp plugin is-active w3-total-cache' \
        --set wordpressConfigureCache=true --set memcached.enabled=true
expect "cache config never activates W3TC"  absent  'wp plugin activate w3-total-cache' \
        --set wordpressConfigureCache=true --set memcached.enabled=true
expect "cache config declares the server"   present 'export SERVER_SOFTWARE=nginx' \
        --set wordpressConfigureCache=true --set memcached.enabled=true
expect "custom script mounts with zz prefix" present 'mountPath: /etc/hooks/application/zz-my-task.sh' \
        --set 'customPostInitScripts.my-task\.sh=echo hi'
check "postinit set" --set wordpressConfigureCache=true --set memcached.enabled=true \
        --set 'customPostInitScripts.my-task\.sh=echo hi'

echo "=== idx plugin follows the sidecar on every start"
# The plugin comes from the sidecar's own package over loopback, so plugin
# and sidecar stay one release. Installing alone must not need any other
# post-init feature: with preinstall emptied, idx alone still renders the
# ConfigMap the mount points at.
IDX=(--set idx.enabled=true)
expect "no idx script without idx"         absent  '05-idx-plugin.sh'
expect "idx script mounts as a single file" present 'mountPath: /etc/hooks/application/zz-05-idx-plugin.sh' "${IDX[@]}"
expect "package comes from the sidecar"    present 'base="http://127.0.0.1:3000/idx/plugin"' "${IDX[@]}"
expect "port and base path follow values"  present 'base="http://127.0.0.1:3100/search/plugin"' \
        "${IDX[@]}" --set idx.port=3100 --set idx.basePath=/search
expect "missing plugin is installed active" present 'wp plugin install "$package" --activate' "${IDX[@]}"
expect "older plugin is updated in place"  present 'wp plugin install "$package" --force' "${IDX[@]}"
expect "web user can read the package"     present 'chmod 0755 "$tmpdir"' "${IDX[@]}"
expect "no start update without autoUpdate" absent 'version_compare' \
        "${IDX[@]}" --set idx.pluginAutoUpdate=false
expect "still installs without autoUpdate" present 'wp plugin install "$package" --activate' \
        "${IDX[@]}" --set idx.pluginAutoUpdate=false
check "idx alone renders the postinit ConfigMap" "${IDX[@]}" --set-json 'wordpressPreinstallPlugins=[]'

echo "=== wp-config site URL falls back sanely without a request"
expect "requests keep using HTTP_HOST"       present "isset(\$_SERVER['HTTP_HOST'])"
expect "CLI falls back to the canonical host" present "getenv_docker('WORDPRESS_HOSTNAME', '')"
expect "last resort is plain-http loopback"  present "'http://localhost:' . getenv_docker('NGINX_HTTP_PORT_NUMBER', '80')"
expect "hostname env comes from the ingress" present 'name: WORDPRESS_HOSTNAME' \
        --set ingress.hostname=example.com
expect "no hostname value, no env"           absent  'name: WORDPRESS_HOSTNAME' \
        --set ingress.hostname=""

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

echo "=== SMTP values render what they claim"
# The values configure the image's msmtp sendmail wrapper through environment
# variables; PHP mail()/wp_mail() relay through it without any mail plugin.
# smtpProtocol/smtpFromEmail existed before 7.1.0-13 but rendered variables
# nothing consumed - these pin the mapping onto the names the wrapper reads.
expect "no SMTP values, no SMTP env"          absent  'name: SMTP_'
expect "host renders"                         present 'name: SMTP_HOST'     --set smtpHost=mail.example.com
expect "protocol tls switches TLS on"         present 'name: SMTP_TLS'      --set smtpHost=m --set smtpProtocol=tls
expect "protocol tls keeps STARTTLS default"  absent  'name: SMTP_STARTTLS' --set smtpHost=m --set smtpProtocol=tls
expect "protocol ssl disables STARTTLS"       present 'name: SMTP_STARTTLS' --set smtpHost=m --set smtpProtocol=ssl
expect "protocol ssl still switches TLS on"   present 'name: SMTP_TLS'      --set smtpHost=m --set smtpProtocol=ssl
expect "the dead SMTP_PROTOCOL env is gone"   absent  'SMTP_PROTOCOL'       --set smtpHost=m --set smtpProtocol=tls
expect "from email sets the envelope sender"  present 'name: SMTP_FROM'     --set smtpFromEmail=news@example.com
expect "from name renders with an email"      present 'name: SMTP_FROM_NAME' \
        --set smtpFromEmail=news@example.com --set smtpFromName=Blog
expect "the dead WORDPRESS_SMTP_ envs are gone" absent 'WORDPRESS_SMTP_'    --set smtpFromEmail=news@example.com
expect "password comes from a Secret key"     present 'key: smtp-password'  --set smtpPassword=pw
expect "existing secret is referenced"        present 'name: my-smtp'       --set smtpExistingSecret=my-smtp
check  "smtp fully configured" --set smtpHost=m --set smtpPort=587 --set smtpUser=u \
        --set smtpPassword=pw --set smtpProtocol=tls \
        --set smtpFromEmail=news@example.com --set smtpFromName=Blog
# An unknown protocol must fail the render, not silently send unencrypted.
if helm template tst "$CHART" --set smtpProtocol=starttls >/dev/null 2>&1; then
    echo "FAIL: smtpProtocol=starttls rendered - unknown protocols must fail the render"
    FAILURES=$((FAILURES + 1))
else
    echo "ok:   unknown smtpProtocol fails the render"
fi
# The display name is part of the rewritten From header; without an address
# it configures nothing, and a value that silently does nothing is how the
# SMTP block was broken before - it must refuse to render instead.
if helm template tst "$CHART" --set smtpFromName=Blog >/dev/null 2>&1; then
    echo "FAIL: smtpFromName without smtpFromEmail rendered - must fail loudly"
    FAILURES=$((FAILURES + 1))
else
    echo "ok:   smtpFromName without smtpFromEmail fails the render"
fi
MANIFEST_SENTINEL=s3ntinelsmtppw \
  check "smtp password never leaves the Secret" --set smtpPassword=s3ntinelsmtppw

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

echo "=== File-integrity watcher renders what it claims"
# fim_check <desc> <deployment|sidecar> <helm args...>: the structural checks
# plus check-fim.py - the pinned wp-config.php digest must equal the bytes
# the init container writes, and the watcher must never sit behind the
# WordPress Service.
fim_check() {
    local desc="$1" mode="$2"; shift 2
    local out
    if ! out="$(helm template tst "$CHART" --set fim.enabled=true --set fim.mode="$mode" "$@" 2>&1)"; then
        echo "FAIL: $desc — helm template failed"
        printf '%s\n' "$out" | sed 's/^/      /' | tail -5
        FAILURES=$((FAILURES + 1))
        return
    fi
    if ! printf '%s' "$out" | python3 "$(dirname "$0")/check-manifests.py" "$desc" \
       || ! printf '%s' "$out" | python3 "$(dirname "$0")/check-fim.py" "$desc" "$mode"; then
        FAILURES=$((FAILURES + 1))
        return
    fi
    echo "ok:   $desc"
}
FIM=(--set fim.enabled=true)
FIM_ONLY=(--show-only templates/fim.yaml)
fim_check "own pod"                              deployment
fim_check "own pod, digest follows idx"          deployment --set idx.enabled=true --set idx.port=3100
fim_check "own pod, digest follows the cache"    deployment --set wordpressConfigureCache=true --set memcached.enabled=true
fim_check "own pod, digest follows WP_CACHE"     deployment --set wordpressWpCache=true
fim_check "own pod with monitoring"              deployment --set fim.serviceMonitor.enabled=true --set fim.prometheusRule.enabled=true
fim_check "sidecar"                              sidecar
fim_check "sidecar without persistence"          sidecar --set persistence.enabled=false
fim_check "sidecar with monitoring"              sidecar --set fim.serviceMonitor.enabled=true --set fim.prometheusRule.enabled=true
expect "off by default"                          absent  "app.kubernetes.io/component: fim"
expect "own pod has its own name label"          present "app.kubernetes.io/name: wordpress-nginx-fim" "${FIM[@]}"
expect "samples get the per-site app label"      present "app: tst-fim" "${FIM[@]}"
expect "the volume is mounted read-only"         present "readOnly: true" "${FIM[@]}" "${FIM_ONLY[@]}"
expect "script runs from the chart's image"      present "image: ghcr.io/ioanalytica/wordpress-nginx:" "${FIM[@]}" "${FIM_ONLY[@]}"
expect "the watcher may open no connection"      present "egress: []" "${FIM[@]}" "${FIM_ONLY[@]}"
expect "RWO volume pins it next to WordPress"    present "topologyKey: kubernetes.io/hostname" "${FIM[@]}" "${FIM_ONLY[@]}"
expect "RWX volume needs no affinity"            absent  "topologyKey: kubernetes.io/hostname" "${FIM[@]}" "${FIM_ONLY[@]}" \
        --set persistence.accessMode=ReadWriteMany
expect "RWX in accessModes counts too"           absent  "topologyKey: kubernetes.io/hostname" "${FIM[@]}" "${FIM_ONLY[@]}" \
        --set 'persistence.accessModes={ReadWriteMany}'
expect "sidecar opens its port in the policy"    present "- port: 9114" "${FIM[@]}" --set fim.mode=sidecar \
        --show-only templates/networkpolicy.yaml
expect "sidecar renders no own pod"              absent  "kind: Deployment" "${FIM[@]}" --set fim.mode=sidecar "${FIM_ONLY[@]}"
expect "web-root mounts become static paths"     present '"subPath": "site-alt"' "${FIM[@]}" "${FIM_ONLY[@]}" \
        --set-json 'extraVolumeMounts=[{"name":"wordpress-data","mountPath":"/var/www/html/alt","subPath":"site-alt"}]'
expect "other volumes are not followed"          absent  '"subPath": "site-alt"' "${FIM[@]}" "${FIM_ONLY[@]}" \
        --set-json 'extraVolumeMounts=[{"name":"other","mountPath":"/var/www/html/alt","subPath":"site-alt"}]'
expect "W3TC drop-ins are accepted with cache"   present '"object-cache.php"' "${FIM[@]}" "${FIM_ONLY[@]}" \
        --set wordpressConfigureCache=true --set memcached.enabled=true
expect "allowMuPlugins drops the writable dir"   absent  '"wp-content/mu-plugins/"' "${FIM[@]}" "${FIM_ONLY[@]}" \
        --set fim.allowMuPlugins=true
computed_digest=$(helm template tst "$CHART" "${FIM[@]}" "${FIM_ONLY[@]}" \
    | grep -A1 '"wp-config.php": \[' | sed -n 's/.*"\([0-9a-f]\{64\}\)".*/\1/p')
expect "a baseline entry replaces the computed"  absent  "${computed_digest:-no digest computed}" "${FIM[@]}" "${FIM_ONLY[@]}" \
        --set-json 'fim.baseline={"wp-config.php":["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]}'
expect "digests are lowercased"                  present '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "${FIM[@]}" "${FIM_ONLY[@]}" \
        --set-json 'fim.baseline={"wp-config.php":["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]}'
expect "an empty list drops the entry"           absent  '"wp-config.php"' "${FIM[@]}" "${FIM_ONLY[@]}" \
        --set-json 'fim.baseline={"wp-config.php":[]}'
expect "rules are scoped to this watcher"        present 'service="tst-wordpress-nginx-fim"' "${FIM[@]}" "${FIM_ONLY[@]}" \
        --set fim.prometheusRule.enabled=true
# Each of these must refuse to render: a value the watcher would silently
# ignore, or a digest YAML has already turned into a number.
fim_refuses() {
    local desc="$1"; shift
    if helm template tst "$CHART" --set fim.enabled=true "$@" >/dev/null 2>&1; then
        echo "FAIL: $desc rendered - must fail the render"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok:   $desc fails the render"
    fi
}
fim_refuses "an unknown fim.mode"                --set fim.mode=daemonset
fim_refuses "an own pod without persistence"     --set persistence.enabled=false
fim_refuses "a digest YAML read as a number"     --set-json 'fim.baseline={"salts.php":[1e5]}'
fim_refuses "a digest of the wrong length"       --set-json 'fim.baseline={"salts.php":["abc"]}'

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "=== $FAILURES check(s) FAILED"
    exit 1
fi
echo "=== All checks passed"
