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

echo "=== Chart version and image tags agree"
# The chart version is the tag of both images of this project: the templates
# take it from .Chart.Version, and a release builds, signs and tags the two
# images and the chart together. A chart that named another tag would deploy
# an image its release did not build - which happened in 7.1.0-4, when the
# tag was a value of its own, and went unnoticed because the feature that
# needed the new image was off by default.
chart_version=$(sed -n 's/^version: *//p' "$CHART/Chart.yaml" | tr -d '"')
rendered_images=$(helm template tst "$CHART" --set idx.enabled=true | sed -n 's/^ *image: *//p' | tr -d '"')
for name in wordpress-nginx wordpress-idx; do
    rendered=$(sed -n "s|^ghcr.io/ioanalytica/$name:||p" <<<"$rendered_images" | sort -u)
    if [ "$rendered" = "$chart_version" ]; then
        echo "ok:   the rendered tag of $name is the chart version, $chart_version"
    else
        echo "FAIL: the rendered tag of $name is '$rendered', the chart version is $chart_version"
        FAILURES=$((FAILURES + 1))
    fi
done
# appVersion is the WordPress release in the image. The tracker raises both
# together; a bump by hand that forgets one would ship a chart that names
# another WordPress than its image holds.
wp_version=$(sed -n 's/^ENV WP_VERSION=//p' "$(dirname "$0")/../../docker/Dockerfile")
chart_app_version=$(sed -n 's/^appVersion: *//p' "$CHART/Chart.yaml" | tr -d '"')
if [ -n "$wp_version" ] && [ "$wp_version" = "$chart_app_version" ]; then
    echo "ok:   appVersion is the WordPress version of the image, $wp_version"
else
    echo "FAIL: appVersion is '$chart_app_version', the Dockerfile's WP_VERSION is '$wp_version'"
    FAILURES=$((FAILURES + 1))
fi
# An override of the sidecar's image keeps working: registry and repository
# are taken from the values, a digest wins over the tag.
expect "an idx.image override names the registry and repository" present \
    "image: registry.example/mirror/idx:$chart_version" \
    --set idx.enabled=true --set idx.image.registry=registry.example --set idx.image.repository=mirror/idx
expect "an idx.image digest wins over the tag" present \
    "image: ghcr.io/ioanalytica/wordpress-idx@sha256:0123" \
    --set idx.enabled=true --set idx.image.digest=sha256:0123

# What is left to drift is the list Artifact Hub reads and scans,
# artifacthub.io/images in Chart.yaml: it names every image the chart can
# run, the two of this project at the chart version, every other one at the
# tag the chart runs it with. scripts/cve-scan-images.sh finds those images
# in the values and the templates; in 7.1.0-16 the list kept the previous
# sidecar tag unnoticed.
listed=$(sed -n 's/^      image: *//p' "$CHART/Chart.yaml" | sort)
expected=$("$(dirname "$0")/../../scripts/cve-scan-images.sh" "$CHART" \
    | jq -r --arg v "$chart_version" '.[].ref | if startswith("ghcr.io/ioanalytica/") then sub(":latest$"; ":" + $v) else . end' | sort)
if [ -n "$expected" ] && [ "$listed" = "$expected" ]; then
    echo "ok:   artifacthub.io/images names the $(wc -l <<<"$listed" | tr -d ' ') images the chart can run, at their tags"
else
    echo "FAIL: artifacthub.io/images differs from the images the chart can run:"
    diff <(echo "$expected") <(echo "$listed") | sed 's/^</      missing:/; s/^>/      not run by the chart:/' | grep '^ ' || true
    FAILURES=$((FAILURES + 1))
fi
# The two annotations of a release are written when it packages the chart
# (scripts/artifacthub-annotations.sh), never here.
for key in artifacthub.io/changes artifacthub.io/prerelease; do
    if grep -q "^  $key:" "$CHART/Chart.yaml"; then
        echo "FAIL: Chart.yaml carries $key; a release writes it"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok:   Chart.yaml leaves $key to the release"
    fi
done

echo "=== Chart version scheme"
# The chart version is x.y.P with P = z * 100 + N for WordPress x.y.z and
# build N (scripts/chart-version.sh). A version with a suffix, or a build
# number that runs past 99 into the next WordPress release's range, would
# still package and install - nothing but this check refuses it.
VERSION_SCRIPT="$(dirname "$0")/../../scripts/chart-version.sh"

# version_prints <desc> <expected> <args...>
version_prints() {
    local desc="$1" expected="$2" out; shift 2
    if out="$("$VERSION_SCRIPT" "$@" 2>&1)" && [ "$out" = "$expected" ]; then
        echo "ok:   $desc"
    else
        echo "FAIL: $desc — expected '$expected', got '$out'"
        FAILURES=$((FAILURES + 1))
    fi
}

# version_refuses <desc> <args...>
version_refuses() {
    local desc="$1" out; shift
    if out="$("$VERSION_SCRIPT" "$@" 2>&1)"; then
        echo "FAIL: $desc — accepted, printed '$out'"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok:   $desc"
    fi
}

app_version=$(sed -n 's/^appVersion: *//p' "$CHART/Chart.yaml" | tr -d '"')
if out="$("$VERSION_SCRIPT" check "$chart_version" "$app_version" 2>&1)"; then
    echo "ok:   $out"
else
    echo "FAIL: $out"
    FAILURES=$((FAILURES + 1))
fi

version_prints  "first version of a patch release"            7.1.500   first 7.1.5
version_prints  "first version of a two-component release"    7.2.0     first 7.2
version_prints  "first version of a .0 release"               7.2.0     first 7.2.0
version_prints  "first version of the release after a .0"     7.2.100   first 7.2.1
version_prints  "first version of a two-digit patch release"  7.10.1200 first 7.10.12
version_refuses "a WordPress version of one component"        first 7
version_prints  "next build"                                  7.1.408   next 7.1.407
version_prints  "next build on a .0 release"                  7.2.1     next 7.2.0
version_refuses "a build after 99"                            next 7.1.499
version_refuses "a build after 99 on a .0 release"            next 7.2.99
version_prints  "a build on a patch release" \
    "chart version 7.1.408: WordPress 7.1.4, build 8"         check 7.1.408 7.1.4
version_prints  "a build on a two-component appVersion" \
    "chart version 7.2.1: WordPress 7.2.0, build 1"           check 7.2.1 7.2
version_prints  "the last build of a .0 release" \
    "chart version 7.2.99: WordPress 7.2.0, build 99"         check 7.2.99 7.2.0
version_refuses "the -N suffix of the earlier scheme"         check 7.1.4-8 7.1.4
version_refuses "a build number past 99"                      check 7.1.500 7.1.4
version_refuses "a build number past 99 on a .0 release"      check 7.2.100 7.2
version_refuses "a patch component with a leading zero"       check 7.1.08 7.1.0
version_refuses "a minor that differs from appVersion"        check 7.2.408 7.1.4
version_refuses "a version with a v prefix"                   check v7.1.408 7.1.4
version_refuses "a version with build metadata"               check 7.1.408+1 7.1.4
version_refuses "a version of two components"                 check 7.1 7.1

echo "=== Changelog and releases"
# A pull request that changes the chart or the image adds its lines under
# "## Unreleased" and leaves the version alone; the release pull request sets
# the version and turns that section into the version's
# (scripts/changelog-release.sh). So the newest version in the changelog is
# always the one Chart.yaml names: a bumped version without an entry, or an
# entry for a version the chart does not have yet, fails here.
CHANGELOG="$CHART/CHANGELOG.md"
RELEASE_SCRIPT="$(dirname "$0")/../../scripts/changelog-release.sh"
newest_heading=$(awk '/^## / && $0 != "## Unreleased" { print; exit }' "$CHANGELOG")
if [ "$newest_heading" = "## $chart_version" ]; then
    echo "ok:   the newest version in the changelog is $chart_version, the chart's"
else
    echo "FAIL: the newest version in the changelog is '${newest_heading#\#\# }', Chart.yaml says $chart_version"
    FAILURES=$((FAILURES + 1))
fi
first_heading=$(awk '/^## / { print; exit }' "$CHANGELOG")
case "$(grep -cxF '## Unreleased' "$CHANGELOG" || true)" in
    0) echo "ok:   no Unreleased section" ;;
    1) if [ "$first_heading" = "## Unreleased" ]; then
           echo "ok:   Unreleased is the first section"
       else
           echo "FAIL: '## Unreleased' must be the first section, which is '$first_heading'"
           FAILURES=$((FAILURES + 1))
       fi ;;
    *) echo "FAIL: more than one Unreleased section"; FAILURES=$((FAILURES + 1)) ;;
esac

CL_TMP="$(mktemp -d)"
trap 'rm -rf "$CL_TMP"' EXIT

# release_gives <desc> <changelog> <expected> <version> [line]: the script
# turns <changelog> into <expected>. Both are given with \n for line ends.
release_gives() {
    local desc="$1" before="$2" expected="$3" out; shift 3
    printf '%b' "$before" > "$CL_TMP/CHANGELOG.md"
    if out="$("$RELEASE_SCRIPT" "$1" "${2:-}" "$CL_TMP/CHANGELOG.md" 2>&1)" \
       && [ "$(cat "$CL_TMP/CHANGELOG.md")" = "$(printf '%b' "$expected")" ]; then
        echo "ok:   $desc"
    else
        echo "FAIL: $desc — got: $out"
        sed 's/^/      /' "$CL_TMP/CHANGELOG.md"
        FAILURES=$((FAILURES + 1))
    fi
}

# release_refuses <desc> <changelog> <version> [line]: the script fails and
# leaves the file as it was.
release_refuses() {
    local desc="$1" before="$2" out; shift 2
    printf '%b' "$before" > "$CL_TMP/CHANGELOG.md"
    if out="$("$RELEASE_SCRIPT" "$1" "${2:-}" "$CL_TMP/CHANGELOG.md" 2>&1)"; then
        echo "FAIL: $desc — accepted"
        FAILURES=$((FAILURES + 1))
    elif [ "$(cat "$CL_TMP/CHANGELOG.md")" != "$(printf '%b' "$before")" ]; then
        echo "FAIL: $desc — refused, but the file changed"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok:   $desc"
    fi
}

WP_LINE='* Update to WordPress 7.1.5.'
release_gives "a release takes the Unreleased lines over, below its own" \
    '# Changelog\n\n## Unreleased\n\n* A fix.\n* Another one.\n\n## 7.1.408\n\n* Old.\n' \
    '# Changelog\n\n## 7.1.500\n\n* Update to WordPress 7.1.5.\n* A fix.\n* Another one.\n\n## 7.1.408\n\n* Old.\n' \
    7.1.500 "$WP_LINE"
release_gives "a release without a line of its own keeps the Unreleased lines as they are" \
    '# Changelog\n\n## Unreleased\n\n* A fix.\n\n## 7.1.408\n\n* Old.\n' \
    '# Changelog\n\n## 7.1.409\n\n* A fix.\n\n## 7.1.408\n\n* Old.\n' \
    7.1.409
release_gives "without an Unreleased section the version gets a new one" \
    '# Changelog\n\n## 7.1.408\n\n* Old.\n' \
    '# Changelog\n\n## 7.1.500\n\n* Update to WordPress 7.1.5.\n\n## 7.1.408\n\n* Old.\n' \
    7.1.500 "$WP_LINE"
release_gives "an empty Unreleased section becomes the version's" \
    '# Changelog\n\n## Unreleased\n\n## 7.1.408\n\n* Old.\n' \
    '# Changelog\n\n## 7.1.500\n\n* Update to WordPress 7.1.5.\n\n## 7.1.408\n\n* Old.\n' \
    7.1.500 "$WP_LINE"
release_gives "a subheading under Unreleased keeps its blank line" \
    '# Changelog\n\n## Unreleased\n\n### Chart\n\n* A fix.\n\n## 7.1.408\n\n* Old.\n' \
    '# Changelog\n\n## 7.1.500\n\n* Update to WordPress 7.1.5.\n\n### Chart\n\n* A fix.\n\n## 7.1.408\n\n* Old.\n' \
    7.1.500 "$WP_LINE"
release_refuses "a version that has its section already" \
    '# Changelog\n\n## Unreleased\n\n* A fix.\n\n## 7.1.408\n\n* Old.\n' \
    7.1.408 "$WP_LINE"
release_refuses "an entry that would say nothing" \
    '# Changelog\n\n## 7.1.408\n\n* Old.\n' \
    7.1.409
release_refuses "an empty Unreleased section without a line" \
    '# Changelog\n\n## Unreleased\n\n## 7.1.408\n\n* Old.\n' \
    7.1.409
release_refuses "an Unreleased section with a subheading and no line below it" \
    '# Changelog\n\n## Unreleased\n\n### Chart\n\n## 7.1.408\n\n* Old.\n' \
    7.1.409
release_refuses "an Unreleased section below a version" \
    '# Changelog\n\n## 7.1.408\n\n* Old.\n\n## Unreleased\n\n* A fix.\n' \
    7.1.409
# The tracker's pull request is built from the repository's own files: the
# workflow must call the script, and the script must take this changelog.
if grep -qF 'scripts/changelog-release.sh "${CHART_VERSION}"' \
        "$(dirname "$0")/../../.github/workflows/wp-version-check.yml"; then
    echo "ok:   the WordPress release tracker writes its entry with the script"
else
    echo "FAIL: .github/workflows/wp-version-check.yml does not call scripts/changelog-release.sh"
    FAILURES=$((FAILURES + 1))
fi
cp "$CHANGELOG" "$CL_TMP/real.md"
# Any version the changelog does not have will do; the script does not ask
# whether it follows the chart's scheme.
next_version=9999.0.0
if "$RELEASE_SCRIPT" "$next_version" "$WP_LINE" "$CL_TMP/real.md" 2>/dev/null \
   && [ "$(awk '/^## / { print; exit }' "$CL_TMP/real.md")" = "## $next_version" ] \
   && ! grep -qxF '## Unreleased' "$CL_TMP/real.md" \
   && [ "$(grep -c '' "$CL_TMP/real.md")" -ge "$(grep -c '' "$CHANGELOG")" ]; then
    echo "ok:   this changelog can be released: its first section becomes the version's, every line kept"
else
    echo "FAIL: scripts/changelog-release.sh cannot release this changelog as $next_version"
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
# The instance id prefixes every W3TC cache key. Derived from
# "<namespace>/<release>" it must be stable across renders and differ per
# release; "default/tst" hashes to this value. The namespace is passed
# explicitly: without -n, helm takes the one of the current kube context.
W3TC=(--set wordpressConfigureCache=true --set memcached.enabled=true)
expect "instance id derives from the release" present 'option set common.instance_id 223805861 --type=integer' \
        "${W3TC[@]}" -n default
expect "instance id can be set explicitly"    present 'option set common.instance_id 1512969306 --type=integer' \
        "${W3TC[@]}" --set wordpressCacheInstanceId=1512969306
iid_of() { helm template "$1" "$CHART" -n "$2" "${W3TC[@]}" 2>&1 | sed -n 's/.*option set common\.instance_id \([0-9]*\) .*/\1/p'; }
a="$(iid_of tst default)"; b="$(iid_of tst other)"; c="$(iid_of copy default)"
if [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" != "$b" ] && [ "$a" != "$c" ]; then
    echo "ok:   instance id differs per namespace and release"
else
    echo "FAIL: instance ids tst/default=$a tst/other=$b copy/default=$c - must all differ"
    FAILURES=$((FAILURES + 1))
fi
# Set before the first flush, so the flushes reach the keys in use from now on.
order="$(helm template tst "$CHART" "${W3TC[@]}" 2>&1 | grep -nE 'common\.instance_id|total-cache flush all' | head -1)"
if [[ "$order" == *common.instance_id* ]]; then
    echo "ok:   instance id is set before any flush"
else
    echo "FAIL: first match is '$order' - the instance id must be set before the first flush"
    FAILURES=$((FAILURES + 1))
fi
for bad in 0 -1 1.5 abc true 2147483648; do
    if helm template tst "$CHART" "${W3TC[@]}" --set wordpressCacheInstanceId="$bad" >/dev/null 2>&1; then
        echo "FAIL: wordpressCacheInstanceId=$bad rendered - must fail the render"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok:   wordpressCacheInstanceId=$bad fails the render"
    fi
done
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

echo "=== Init script creates only what is missing"
# Every "if [ ! -f|-d /wordpress/PATH ]" guard on the volume must test the
# path its block creates. A misspelled guard (ngingx.conf until 7.1.4-3) is
# always true: the block then runs on every start against a file that
# exists, and nothing says so.
guards=$(helm template tst "$CHART" | python3 -c '
import re, sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if not d or d.get("kind") != "Deployment":
        continue
    for c in d["spec"]["template"]["spec"].get("initContainers") or []:
        if c["name"] != "prepare-base-dir":
            continue
        script = c["args"][-1]
        blocks = re.findall(r"if \[ ! -[fd] (/wordpress/\S+) \]; then\n(.*?)\n\s*fi\n", script, re.S)
        bad = [p for p, body in blocks if p not in body]
        print(len(blocks), " ".join(bad))
')
read -r n_guards bad_guards <<<"$guards"
if [ "${n_guards:-0}" -ge 3 ] && [ -z "$bad_guards" ]; then
    echo "ok:   all $n_guards create-if-missing guards test the path they create"
else
    echo "FAIL: create-if-missing guards (found ${n_guards:-0}) test a path their block never creates: ${bad_guards:-none found}"
    FAILURES=$((FAILURES + 1))
fi

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
expect "empty protocol leaves TLS to the image" absent 'name: SMTP_TLS'    --set smtpHost=m --set smtpUser=u
expect "protocol none keeps STARTTLS unset"   absent  'name: SMTP_STARTTLS' --set smtpHost=m --set smtpProtocol=none
# The value matters, not just the name: "none" must switch TLS off, since
# the image's wrapper turns it on by itself once credentials are set.
smtp_tls_value() {
    helm template tst "$CHART" --set smtpHost=m --set smtpUser=u "$@" 2>/dev/null \
        | grep -A1 -- '- name: SMTP_TLS$' | sed -n 's/^ *value: "\(.*\)"$/\1/p'
}
for case in "tls on" "ssl on" "none off"; do
    set -- $case
    got="$(smtp_tls_value --set smtpProtocol="$1")"
    if [ "$got" = "$2" ]; then
        echo "ok:   protocol $1 renders SMTP_TLS=$2"
    else
        echo "FAIL: protocol $1 should render SMTP_TLS=$2, got '${got}'"
        FAILURES=$((FAILURES + 1))
    fi
done
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

echo "=== Metrics reach Prometheus"
# The exporter sidecar listens on a port of its own. The chart's
# NetworkPolicy is on by default and lists the pod's ports one by one, so a
# port missing there is a scrape that times out wherever policies are
# enforced, with the exporter itself running fine.
METRICS=(--set metrics.enabled=true)
NETPOL=(--show-only templates/networkpolicy.yaml)
expect "the policy admits the exporter's port"  present "- port: 9113" "${METRICS[@]}" "${NETPOL[@]}"
expect "the admitted port follows the values"   present "- port: 9200" "${METRICS[@]}" "${NETPOL[@]}" \
        --set metrics.containerPorts.metrics=9200
expect "no exporter, no port in the policy"     absent  "- port: 9113" "${NETPOL[@]}"
check  "metrics with a ServiceMonitor"          "${METRICS[@]}" --set metrics.serviceMonitor.enabled=true

# endpoint_field <field> <helm args...>: one field of the ServiceMonitor's
# endpoint, as compact JSON ("null" when the endpoint does not have it).
endpoint_field() {
    local field="$1"; shift
    helm template tst "$CHART" "${METRICS[@]}" --set metrics.serviceMonitor.enabled=true \
        --show-only templates/servicemonitor.yaml "$@" 2>&1 \
        | python3 -c '
import json, sys, yaml
doc = yaml.safe_load(sys.stdin)
print(json.dumps(doc["spec"]["endpoints"][0].get(sys.argv[1]), separators=(",", ":"), sort_keys=True))
' "$field" 2>/dev/null || echo "render failed"
}

# endpoint_has <desc> <field> <expected JSON> <helm args...>
endpoint_has() {
    local desc="$1" field="$2" expected="$3" got; shift 3
    got="$(endpoint_field "$field" "$@")"
    if [ "$got" = "$expected" ]; then
        echo "ok:   $desc"
    else
        echo "FAIL: $desc — $field is $got, expected $expected"
        FAILURES=$((FAILURES + 1))
    fi
}

DROP='[{"action":"drop","regex":"nginx_up","sourceLabels":["__name__"]}]'
SITE='[{"replacement":"blog","targetLabel":"site"}]'
# metricRelabelings and relabelings are two settings of an endpoint: one
# rewrites the samples, the other the target. Each value must reach the
# field of its own name and no other.
endpoint_has "metricRelabelings reaches the endpoint"     metricRelabelings "$DROP" \
        --set-json "metrics.serviceMonitor.metricRelabelings=$DROP"
endpoint_has "metricRelabelings sets no relabelings"      relabelings null \
        --set-json "metrics.serviceMonitor.metricRelabelings=$DROP"
endpoint_has "relabelings reaches the endpoint"           relabelings "$SITE" \
        --set-json "metrics.serviceMonitor.relabelings=$SITE"
endpoint_has "relabelings sets no metricRelabelings"      metricRelabelings null \
        --set-json "metrics.serviceMonitor.relabelings=$SITE"
endpoint_has "both can be set side by side"               metricRelabelings "$DROP" \
        --set-json "metrics.serviceMonitor.metricRelabelings=$DROP" \
        --set-json "metrics.serviceMonitor.relabelings=$SITE"
endpoint_has "no rules, no field"                         metricRelabelings null
# The key the template read up to 7.1.408. A release that set it keeps its
# rules; the documented key wins where both are set.
endpoint_has "the earlier spelling still applies"         metricRelabelings "$DROP" \
        --set-json "metrics.serviceMonitor.relabellings=$DROP"
endpoint_has "the documented key wins over it"            metricRelabelings "$DROP" \
        --set-json "metrics.serviceMonitor.metricRelabelings=$DROP" \
        --set-json "metrics.serviceMonitor.relabellings=$SITE"

# selector and labels both end up as labels of the ServiceMonitor, which is
# what a Prometheus selects it by. A key named in both must render once: a
# second one makes the manifest invalid for a strict YAML parser.
SM=("${METRICS[@]}" --set metrics.serviceMonitor.enabled=true --show-only templates/servicemonitor.yaml)
expect "selector labels the ServiceMonitor"      present "prometheus: main" "${SM[@]}" \
        --set metrics.serviceMonitor.selector.prometheus=main
expect "labels wins over selector"               present "release: mine" "${SM[@]}" \
        --set metrics.serviceMonitor.selector.release=theirs --set metrics.serviceMonitor.labels.release=mine
expect "the overruled selector label is gone"    absent  "release: theirs" "${SM[@]}" \
        --set metrics.serviceMonitor.selector.release=theirs --set metrics.serviceMonitor.labels.release=mine
check  "selector and labels naming one key"      "${METRICS[@]}" --set metrics.serviceMonitor.enabled=true \
        --set metrics.serviceMonitor.selector.release=theirs --set metrics.serviceMonitor.labels.release=mine
# The ServiceMonitor's own component label is one of these labels: a value
# that names the key must not put it into the manifest a second time.
expect "the component label stays metrics"       present "app.kubernetes.io/component: metrics" "${SM[@]}" \
        --set-json 'metrics.serviceMonitor.selector={"app.kubernetes.io/component":"other"}'
expect "a value cannot rename the component"     absent  "app.kubernetes.io/component: other" "${SM[@]}" \
        --set-json 'metrics.serviceMonitor.selector={"app.kubernetes.io/component":"other"}' \
        --set-json 'metrics.serviceMonitor.labels={"app.kubernetes.io/component":"other"}'
check  "selector naming the component label"     "${METRICS[@]}" --set metrics.serviceMonitor.enabled=true \
        --set-json 'metrics.serviceMonitor.selector={"app.kubernetes.io/component":"metrics"}'
check  "labels naming the component label"       "${METRICS[@]}" --set metrics.serviceMonitor.enabled=true \
        --set-json 'metrics.serviceMonitor.labels={"app.kubernetes.io/component":"metrics"}'

echo "=== NetworkPolicy admits the ports the pod declares"
# extraContainerPorts entries are container ports (name, containerPort); the
# policy needs the number. Rendering the entry itself gave a port the API
# server refuses, so the release could not be installed.
EXTRA_PORT=(--set-json 'extraContainerPorts=[{"name":"status","containerPort":9090},{"name":"dns","containerPort":5353,"protocol":"UDP"}]')
# policy_ports <helm args...>: the ports of the policy's first ingress rule
# as "port/protocol", in one line; a port without a protocol is TCP to the
# API server and shows as "port/-".
policy_ports() {
    helm template tst "$CHART" "${NETPOL[@]}" "$@" 2>/dev/null | python3 -c '
import sys, yaml
doc = yaml.safe_load(sys.stdin)
print(" ".join("%s/%s" % (p["port"], p.get("protocol", "-")) for p in doc["spec"]["ingress"][0]["ports"]))
' 2>/dev/null || echo "render failed"
}
# policy_admits <desc> <expected ports> <helm args...>
policy_admits() {
    local desc="$1" expected="$2" got; shift 2
    got="$(policy_ports "$@")"
    if [ "$got" = "$expected" ]; then
        echo "ok:   $desc"
    else
        echo "FAIL: $desc — the policy admits '$got', expected '$expected'"
        FAILURES=$((FAILURES + 1))
    fi
}
policy_admits "extra container ports are admitted, with their protocol" "80/- 9090/- 5353/UDP" "${EXTRA_PORT[@]}"
# The Deployment renders the value through the template engine, so text is a
# form of it; the policy has to read the same entries.
policy_admits "extra container ports given as template text"            "80/- 9091/-" \
        --set-string $'extraContainerPorts=- name: status\n  containerPort: {{ add 9000 91 }}'
policy_admits "no extra container ports"                                "80/-"
check  "extra container ports"                   "${EXTRA_PORT[@]}"
check  "extra container ports as template text"  --set-string $'extraContainerPorts=- name: status\n  containerPort: {{ add 9000 91 }}'

echo "=== Extra wp-config.php content reaches the generated file"
# The generated wp-config.php evaluates WORDPRESS_CONFIG_EXTRA and nothing
# else. wordpressExtraConfigContent used to be passed under a name nothing
# reads.
EXTRA_CONFIG=(--set-json 'wordpressExtraConfigContent="define( \"WP_POST_REVISIONS\", 10 );"')
expect "no content, no variable"                 absent  'name: WORDPRESS_CONFIG_EXTRA'
expect "content becomes WORDPRESS_CONFIG_EXTRA"  present 'name: WORDPRESS_CONFIG_EXTRA' "${EXTRA_CONFIG[@]}"
expect "the content is the variable's value"     present 'value: "define( \"WP_POST_REVISIONS\", 10 );"' "${EXTRA_CONFIG[@]}"
expect "the unread variable is gone"             absent  'WORDPRESS_EXTRA_WP_CONFIG_CONTENT' "${EXTRA_CONFIG[@]}"
expect "wp-config.php evaluates the variable"    present "getenv_docker('WORDPRESS_CONFIG_EXTRA', '')"
# A release may set the variable itself through extraEnvVars. That entry
# stays the only one: two variables of one name in a container are refused
# by a server-side apply.
# config_extra_values <helm args...>: the value of every WORDPRESS_CONFIG_EXTRA
# entry of the WordPress container, one per line.
config_extra_values() {
    helm template tst "$CHART" "${EXTRA_CONFIG[@]}" "$@" 2>/dev/null | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "Deployment" and d["metadata"]["name"] == "tst-wordpress-nginx":
        for c in d["spec"]["template"]["spec"]["containers"]:
            if c["name"] == "wordpress":
                for e in c.get("env") or []:
                    if e["name"] == "WORDPRESS_CONFIG_EXTRA":
                        print(e.get("value"))
' 2>/dev/null || true
}
# The entries are read as the Deployment renders them: a list, text for the
# template engine, a name with a comment behind it, a templated name.
for form in "a list" "text" "text with a comment" "a templated name"; do
    case "$form" in
        "a list")              OWN=(--set-json 'extraEnvVars=[{"name":"WORDPRESS_CONFIG_EXTRA","value":"own_statement();"}]') ;;
        "text")                OWN=(--set-string $'extraEnvVars=- name: WORDPRESS_CONFIG_EXTRA\n  value: own_statement();') ;;
        "text with a comment") OWN=(--set-string $'extraEnvVars=- name: WORDPRESS_CONFIG_EXTRA # ours\n  value: own_statement();') ;;
        "a templated name")    OWN=(--set-string $'extraEnvVars=- name: {{ printf "WORDPRESS_%s" "CONFIG_EXTRA" }}\n  value: own_statement();') ;;
    esac
    got="$(config_extra_values "${OWN[@]}")"
    if [ "$got" = "own_statement();" ]; then
        echo "ok:   an extraEnvVars entry of that name stays the only one, as $form"
    else
        echo "FAIL: with extraEnvVars as $form, WORDPRESS_CONFIG_EXTRA renders as: ${got:-nothing}"
        FAILURES=$((FAILURES + 1))
    fi
done
got="$(config_extra_values)"
if [ "$got" = 'define( "WP_POST_REVISIONS", 10 );' ]; then
    echo "ok:   without such an entry the value is the only one"
else
    echo "FAIL: WORDPRESS_CONFIG_EXTRA renders as: ${got:-nothing}"
    FAILURES=$((FAILURES + 1))
fi
expect "another extraEnvVars entry changes nothing" present 'name: WORDPRESS_CONFIG_EXTRA' "${EXTRA_CONFIG[@]}" \
        --set-json 'extraEnvVars=[{"name":"OTHER","value":"x"}]'
check  "extra config content"                    "${EXTRA_CONFIG[@]}"
# Variables the image never read are not passed any more.
expect "no variable for wordpressSkipInstall"    absent  'WORDPRESS_SKIP_BOOTSTRAP' --set wordpressSkipInstall=true
# The init container has no environment to check; the block that claimed to
# check it printed a check mark for every name.
expect "init script checks no environment"       absent  'Checking environment for required settings'

echo "=== Security contexts render what the image starts with"
# The image has to start as root, with a writable root filesystem and the
# runtime's default capabilities; the init container sets file owners. The
# defaults of containerSecurityContext must therefore be a context the pod
# starts with, so that enabled=true alone is usable. What starts was tried on
# a cluster; this pins the defaults to it.
security_contexts=$(helm template tst "$CHART" --set containerSecurityContext.enabled=true \
        --set podSecurityContext.enabled=true 2>&1 | python3 -c '
import json, sys, yaml
want = {"seLinuxOptions": {}, "runAsUser": 0, "runAsGroup": 0, "runAsNonRoot": False, "privileged": False,
        "readOnlyRootFilesystem": False, "allowPrivilegeEscalation": False,
        "capabilities": {"drop": []}, "seccompProfile": {"type": "RuntimeDefault"}}
problems = []
for d in yaml.safe_load_all(sys.stdin):
    if not d or d.get("kind") != "Deployment" or d["metadata"]["name"] != "tst-wordpress-nginx":
        continue
    spec = d["spec"]["template"]["spec"]
    if (spec.get("securityContext") or {}).get("fsGroup") != 1001:
        problems.append("pod securityContext has no fsGroup 1001")
    containers = {c["name"]: c for c in spec["initContainers"] + spec["containers"]}
    for name in ("prepare-base-dir", "wordpress"):
        got = containers[name].get("securityContext")
        if got != want:
            problems.append(name + ": " + json.dumps(got, sort_keys=True))
    break
else:
    problems.append("no WordPress Deployment rendered")
print("; ".join(problems))
' 2>&1) || security_contexts="render failed"
if [ -z "$security_contexts" ]; then
    echo "ok:   enabled contexts keep root, a writable root filesystem and the default capabilities"
else
    echo "FAIL: security contexts differ from what the image starts with — $security_contexts"
    FAILURES=$((FAILURES + 1))
fi
expect "off by default"                          absent  "securityContext:" --show-only templates/deployment.yaml
check  "security contexts enabled"               --set containerSecurityContext.enabled=true --set podSecurityContext.enabled=true

echo "=== The notes after an install fit any cluster"
# `helm template` does not print NOTES.txt; a client-side dry run of the
# install does, and with no kubeconfig it asks no cluster.
# notes_say <desc> <"present"|"absent"> <needle> <helm args...>
notes_say() {
    local desc="$1" mode="$2" needle="$3" out; shift 3
    out="$(KUBECONFIG=/dev/null helm install tst "$CHART" --dry-run=client -n default "$@" 2>&1)" || {
        echo "FAIL: $desc — the dry run of the install failed"; FAILURES=$((FAILURES + 1)); return
    }
    out="${out#*NOTES:}"
    if grep -qF -- "$needle" <<<"$out"; then
        if [ "$mode" = "present" ]; then echo "ok:   $desc"
        else echo "FAIL: $desc — the notes say '$needle'"; FAILURES=$((FAILURES + 1)); fi
    else
        if [ "$mode" = "absent" ]; then echo "ok:   $desc"
        else echo "FAIL: $desc — the notes do not say '$needle'"; FAILURES=$((FAILURES + 1)); fi
    fi
}
WITH_INGRESS=(--set ingress.enabled=true --set ingress.hostname=blog.example.com)
notes_say "with an Ingress the notes give the site's URL"  present "WordPress URL: http://blog.example.com/" "${WITH_INGRESS[@]}"
notes_say "with TLS the URL is https"                      present "WordPress URL: https://blog.example.com/" "${WITH_INGRESS[@]}" --set ingress.tls=true
notes_say "a templated hostname is rendered"               present "WordPress URL: http://tst.example.com/" \
        --set ingress.enabled=true --set-json 'ingress.hostname="{{ .Release.Name }}.example.com"'
notes_say "they name the Ingress to look at"               present "kubectl get ingress --namespace default tst-wordpress-nginx" "${WITH_INGRESS[@]}"
notes_say "they assume no particular cluster"              absent  "minikube" "${WITH_INGRESS[@]}"
notes_say "they ask for no change to /etc/hosts"           absent  "/etc/hosts" "${WITH_INGRESS[@]}"
notes_say "without an Ingress they follow the Service"     present "kubectl get svc --namespace default" 

echo "=== No HTTPS port: the image serves HTTP only"
# The image listens on port 80 and carries no certificate, TLS ends at the
# Ingress. So no object may name an HTTPS port: a container port, a Service
# port, a port of the NetworkPolicy, a probe, or a variable that hands one
# to the container.
# no_https_port <desc> <helm args...>
no_https_port() {
    local desc="$1" out found; shift
    out="$(helm template tst "$CHART" "$@" 2>&1)" || {
        echo "FAIL: $desc — helm template failed"; FAILURES=$((FAILURES + 1)); return
    }
    found="$(python3 -c '
import sys, yaml

PORT_KEYS = ("port", "containerPort", "targetPort", "nodePort", "hostPort")

def walk(node, kind, path):
    if isinstance(node, dict):
        if str(node.get("name")) == "https" and any(k in node for k in PORT_KEYS):
            print("%s: a port named https at %s" % (kind, path))
        if "HTTPS_PORT" in str(node.get("name", "")) and ("value" in node or "valueFrom" in node):
            print("%s: the variable %s" % (kind, node["name"]))
        for key, value in node.items():
            if key in PORT_KEYS and str(value) in ("443", "https"):
                print("%s: %s %s at %s" % (kind, key, value, path))
            walk(value, kind, "%s.%s" % (path, key))
    elif isinstance(node, list):
        for i, value in enumerate(node):
            walk(value, kind, "%s[%d]" % (path, i))

for doc in yaml.safe_load_all(sys.stdin):
    if isinstance(doc, dict):
        walk(doc, doc.get("kind", "?"), "")
' <<<"$out")" || { echo "FAIL: $desc — the manifests could not be read"; FAILURES=$((FAILURES + 1)); return; }
    if [ -z "$found" ]; then
        echo "ok:   $desc"
    else
        echo "FAIL: $desc — an object names an HTTPS port"
        printf '%s\n' "$found" | sed 's/^/      /'
        FAILURES=$((FAILURES + 1))
    fi
}
no_https_port "defaults"
no_https_port "wordpressScheme https"            --set wordpressScheme=https
no_https_port "wordpressScheme https, startup probe" --set wordpressScheme=https --set startupProbe.enabled=true
no_https_port "Service of type NodePort"         --set service.type=NodePort
no_https_port "Service of type ClusterIP"        --set service.type=ClusterIP
no_https_port "NetworkPolicy with selected sources" --set networkPolicy.allowExternal=false
no_https_port "multisite.enable"                 --set multisite.enable=true
no_https_port "Ingress with TLS"                 --set ingress.enabled=true --set ingress.hostname=blog.example.com --set ingress.tls=true
no_https_port "search sidecar and exporter"      --set idx.enabled=true --set metrics.enabled=true
expect "the Service has its HTTP port"           present "targetPort: http" --show-only templates/svc.yaml
# The probes ask over HTTP whatever the scheme of the site's URLs is. Up to
# 7.1.410 they followed wordpressScheme and asked the port "https".
expect "wordpressScheme https: the readiness probe asks over HTTP" present "scheme: HTTP" \
        --show-only templates/deployment.yaml --set wordpressScheme=https
expect "wordpressScheme https: no probe asks for TLS"              absent  "scheme: HTTPS" \
        --show-only templates/deployment.yaml --set wordpressScheme=https --set startupProbe.enabled=true

# containerPorts.https, service.ports.https, service.httpsTargetPort and
# service.nodePorts.https are gone from values.yaml. A values file that
# still sets them renders, and renders the same objects as one without
# them. The passwords are set, or two renders differ in what Helm generates.
OLD_HTTPS_VALUES="$(mktemp)"
cat >"$OLD_HTTPS_VALUES" <<'VALUES'
containerPorts:
  http: 80
  https: 443
service:
  type: NodePort
  ports:
    http: 80
    https: 443
  httpsTargetPort: https
  nodePorts:
    http: "30080"
    https: "30443"
VALUES
SAME_SECRETS=(--set wordpressPassword=pw --set mariadb.auth.password=pw --set mariadb.auth.rootPassword=pw)
WITHOUT_HTTPS_VALUES=(--set service.type=NodePort --set-string service.nodePorts.http=30080)
check         "a values file that still sets the HTTPS values renders" -f "$OLD_HTTPS_VALUES"
no_https_port "a values file that still sets the HTTPS values"         -f "$OLD_HTTPS_VALUES"
if with_old="$(helm template tst "$CHART" "${SAME_SECRETS[@]}" -f "$OLD_HTTPS_VALUES" 2>&1)" \
   && without_old="$(helm template tst "$CHART" "${SAME_SECRETS[@]}" "${WITHOUT_HTTPS_VALUES[@]}" 2>&1)" \
   && [ "$with_old" = "$without_old" ]; then
    echo "ok:   the HTTPS values change nothing in what is rendered"
else
    echo "FAIL: the render with the HTTPS values differs from the one without them"
    diff <(printf '%s\n' "${without_old:-}") <(printf '%s\n' "${with_old:-}") | head -10 | sed 's/^/      /'
    FAILURES=$((FAILURES + 1))
fi
# The chart has no defaults for them any more, so a key that is there was
# set by the release, and the notes name it.
notes_say "the notes name an HTTPS value that is still set"  present "service.httpsTargetPort" -f "$OLD_HTTPS_VALUES"
notes_say "and say that it has no effect"                    present "no longer have an effect" -f "$OLD_HTTPS_VALUES"
notes_say "each one that is set is named"                    present "containerPorts.https" --set containerPorts.https=8443
notes_say "one that is not set is not named"                 absent  "service.ports.https" --set containerPorts.https=8443
notes_say "without them the notes are silent about it"       absent  "no longer have an effect"
rm -f "$OLD_HTTPS_VALUES"

# A probe that still asks the port "https", or asks the HTTP port for TLS,
# would never succeed, and the pods of the upgrade would not get ready. The
# render fails instead and says what to change.
# probe_refuses <desc> <helm args...>
probe_refuses() {
    local desc="$1" out; shift
    if out="$(helm template tst "$CHART" "$@" 2>&1)"; then
        echo "FAIL: $desc rendered - must fail the render"
        FAILURES=$((FAILURES + 1))
    elif ! grep -qF 'TLS ends at the Ingress' <<<"$out"; then
        echo "FAIL: $desc fails the render, but not with the probe's message"
        printf '%s\n' "$out" | tail -4 | sed 's/^/      /'
        FAILURES=$((FAILURES + 1))
    else
        echo "ok:   $desc fails the render"
    fi
}
probe_refuses "a readiness probe on the port https"      --set readinessProbe.httpGet.port=https
probe_refuses "the earlier default probe with wordpressScheme https" --set wordpressScheme=https \
        --set-string 'readinessProbe.httpGet.port=\{\{ .Values.wordpressScheme \}\}' \
        --set-string 'readinessProbe.httpGet.scheme=\{\{ .Values.wordpressScheme | upper \}\}'
probe_refuses "a startup probe on the port https"        --set startupProbe.enabled=true --set startupProbe.httpGet.port=https
probe_refuses "a liveness probe on the port https"       --set livenessProbe.tcpSocket.port=https
probe_refuses "a custom probe on the port https"         --set-json 'customReadinessProbe={"httpGet":{"path":"/","port":"https","scheme":"HTTPS"}}'
probe_refuses "a custom probe given as template text"    --set-string $'customLivenessProbe=tcpSocket:\n  port: \{\{ print "https" \}\}'
probe_refuses "TLS asked of the HTTP port"               --set readinessProbe.httpGet.scheme=HTTPS
probe_refuses "TLS asked of the HTTP port by its number" --set readinessProbe.httpGet.scheme=https --set readinessProbe.httpGet.port=80
check  "the earlier default probe with wordpressScheme http" \
        --set-string 'readinessProbe.httpGet.port=\{\{ .Values.wordpressScheme \}\}' \
        --set-string 'readinessProbe.httpGet.scheme=\{\{ .Values.wordpressScheme | upper \}\}'
check  "a probe on a port named https that the release declares" --set readinessProbe.httpGet.port=https \
        --set readinessProbe.httpGet.scheme=HTTPS --set-json 'extraContainerPorts=[{"name":"https","containerPort":8443}]'
check  "a disabled probe is not looked at"       --set readinessProbe.enabled=false --set readinessProbe.httpGet.port=https
check  "diagnostic mode renders no probes"       --set diagnosticMode.enabled=true --set readinessProbe.httpGet.port=https

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
# Drop-ins are checked against W3TC's own copies on every site, never
# accepted by name: a name allowance is exactly what replaced drop-ins hide
# behind, and a digest would break with every automatic W3TC update.
expect "drop-ins are checked against W3TC"       present '"object-cache.php": "wp-content/plugins/w3-total-cache/wp-content/object-cache.php"' \
        "${FIM[@]}" "${FIM_ONLY[@]}"
expect "drop-ins are not accepted by name"       absent  '"advanced-cache.php",' "${FIM[@]}" "${FIM_ONLY[@]}" \
        --set wordpressConfigureCache=true --set memcached.enabled=true
expect "a drop-in can point at another plugin"   present '"object-cache.php": "wp-content/plugins/redis-cache/includes/object-cache.php"' \
        "${FIM[@]}" "${FIM_ONLY[@]}" --set-json 'fim.dropins={"object-cache.php":"/wp-content/plugins/redis-cache/includes/object-cache.php"}'
expect "an empty value removes a drop-in"        absent  '"db.php"' "${FIM[@]}" "${FIM_ONLY[@]}" \
        --set-json 'fim.dropins={"db.php":""}'
expect "index.php is judged by content, not name" absent '"index.php"' "${FIM[@]}" "${FIM_ONLY[@]}"
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
echo "=== The bundled MariaDB takes over an existing data directory"
# A new MariaDB series starts on the data of the earlier one, and the image
# then updates its system tables itself. Tried on a cluster (12.2.2 to
# 12.3.3) as an upgrade of an installed release; this pins the setting on
# the rendered Deployment.
mariadb_upgrade=$(helm template tst "$CHART" 2>&1 | python3 -c '
import sys, yaml
problems = []
for d in yaml.safe_load_all(sys.stdin):
    if not d or d.get("kind") != "Deployment" or d["metadata"]["name"] != "tst-wordpress-nginx-mariadb":
        continue
    env = {e["name"]: e.get("value") for e in d["spec"]["template"]["spec"]["containers"][0]["env"]}
    if env.get("MARIADB_AUTO_UPGRADE") != "1":
        problems.append("MARIADB_AUTO_UPGRADE is not \"1\"")
    break
else:
    problems.append("no MariaDB Deployment rendered")
print("; ".join(problems))
' 2>&1) || mariadb_upgrade="render failed"
if [ -z "$mariadb_upgrade" ]; then
    echo "ok:   the database updates its system tables itself"
else
    echo "FAIL: the bundled MariaDB — $mariadb_upgrade"
    FAILURES=$((FAILURES + 1))
fi
expect "an external database renders no MariaDB" absent "MARIADB_AUTO_UPGRADE" \
    --set mariadb.enabled=false --set externalDatabase.host=db.example.com

echo "=== The examples render, with keys the chart knows"
# examples/ lives next to the chart in the repository and is not part of the
# packaged chart, so a chart tested on its own has none. An example that no
# longer renders, or sets a key the chart has renamed or dropped, would
# otherwise only fail for the reader who follows its page: helm ignores
# unknown keys.
EXAMPLES="$(cd "$(dirname "$0")/../.." && pwd)/examples"
for values in "$EXAMPLES"/*/values.yaml; do
    [ -f "$values" ] || continue
    name="examples/$(basename "$(dirname "$values")")"
    check "$name renders" -f "$values"
    if unknown="$(python3 "$(dirname "$0")/check-example-keys.py" "$CHART/values.yaml" "$values")" \
            && [ -z "$unknown" ]; then
        echo "ok:   $name sets only keys of values.yaml"
    else
        echo "FAIL: $name sets keys values.yaml does not know: $(echo "$unknown" | tr '\n' ' ')"
        FAILURES=$((FAILURES + 1))
    fi
done
# What the k3d page relies on (examples/k3d/README.md).
K3D="$EXAMPLES/k3d/values.yaml"
if [ -f "$K3D" ]; then
    expect "k3d: no LoadBalancer next to k3s's Traefik" absent  'type: LoadBalancer' -f "$K3D"
    expect "k3d: the Ingress is Traefik's"              present 'ingressClassName: "traefik"' -f "$K3D"
    expect "k3d: the Ingress is for localhost"          present '- host: "localhost"' -f "$K3D"
    expect "k3d: the Ingress routes /idx to the sidecar" present 'path: /idx' -f "$K3D"
    expect "k3d: the watcher runs in a pod of its own"  present 'name: tst-wordpress-nginx-fim' -f "$K3D"
    expect "k3d: the watcher accepts Hello Dolly"       present '"hello.php"' -f "$K3D"
    expect "k3d: the reindex key comes from the command line" present 'idx-reindex-api-key:' -f "$K3D" \
            --set idx.reindexApiKey=test
    expect "k3d: without it there is no key"            absent  'idx-reindex-api-key' -f "$K3D"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "=== $FAILURES check(s) FAILED"
    exit 1
fi
echo "=== All checks passed"
