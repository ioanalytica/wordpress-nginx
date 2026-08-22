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
    if printf '%s' "$out" | grep -q -- "$needle"; then
        if [ "$mode" = "present" ]; then echo "ok:   $desc"
        else echo "FAIL: $desc — found '$needle' but expected it absent"; FAILURES=$((FAILURES + 1)); fi
    else
        if [ "$mode" = "absent" ]; then echo "ok:   $desc"
        else echo "FAIL: $desc — expected '$needle', not found"; FAILURES=$((FAILURES + 1)); fi
    fi
}

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
