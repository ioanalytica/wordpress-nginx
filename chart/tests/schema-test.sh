#!/bin/bash
# Test for chart/values.schema.json.
#
# Helm checks the values of every install, upgrade, template and lint against
# the schema, and Artifact Hub shows it as the chart's values reference. The
# schema is written by hand, so two things can go wrong without any other test
# noticing: it falls behind values.yaml, or it refuses values a working
# release sets.
#
# check-schema.py covers the first: every `## @param` of values.yaml is in the
# schema, every schema entry is a key of values.yaml with the same default,
# and every key of values.yaml is in the schema.
#
# This script covers the second. The schema is permissive on purpose:
#   - no `required`, no `additionalProperties: false`, so a key the schema
#     does not know is left to the chart. The entries of nginx.deniedPaths and
#     wordpressPreinstallPlugins are the exception: a misspelled key in a rule
#     would silently become another rule;
#   - an `enum` only for the modes with a fixed set of values;
#   - text also as a number and numbers also as text, as --set, --set-string
#     and a quoted value in a values file deliver them; switches also as 0/1
#     or text; a list also as a map of entries or as text; a map also as an
#     empty list, and as text where the chart renders it as a template.
# It lets such values through; it does not make the chart read them right. A
# switch given as the text "false" still counts as on in a template's `if`,
# as it did before the schema listed the switch. The six switches the schema
# listed before (mariadb.enabled, metrics.enabled, and enabled and tls of both
# Ingresses) stay limited to true and false.
#
# --skip-schema-validation needs Helm 3.16 or later.
#
#   ./schema-test.sh [chart-dir]

set -euo pipefail

CHART="${1:-$(dirname "$0")/..}"
FAILURES=0

preflight="$(helm template tst "$CHART" 2>&1 || true)"
if printf '%s' "$preflight" | grep -q "missing in charts/ directory"; then
    echo "ERROR: chart dependencies are missing. Run:"
    echo "         helm dependency update $CHART"
    exit 1
fi

ok()   { echo "ok:   $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# passes <helm args...>: the chart renders with these values, schema and all.
passes() {
    local out
    if out="$(helm template tst "$CHART" "$@" 2>&1)"; then
        ok "passes: $*"
    else
        fail "refused: $*"
        printf '%s\n' "$out" | sed 's/^/      /' | tail -4
    fi
}

# refused <path> <helm args...>: the schema refuses the value at <path>, and
# nothing else. <path> is given as /a/b/0, the way Helm 4 names it; Helm 3
# writes a.b.0.
refused() {
    local path="$1" dotted out; shift
    dotted="${path#/}"; dotted="${dotted//\//.}"
    if out="$(helm template tst "$CHART" "$@" 2>&1)"; then
        fail "rendered, expected the schema to refuse it: $*"
    elif grep -qF "the schema" <<<"$out" && { grep -qF -- "$path" <<<"$out" || grep -qF -- "$dotted" <<<"$out"; }; then
        ok "refused by the schema: $*"
    else
        fail "failed, but not at $path of the schema: $*"
        printf '%s\n' "$out" | sed 's/^/      /' | tail -4
    fi
}

echo "=== The schema keeps step with values.yaml"
if out="$(python3 "$(dirname "$0")/check-schema.py" "$CHART" 2>&1)"; then
    ok "$(tail -n 1 <<<"$out")"
else
    fail "values.schema.json and values.yaml disagree"
    printf '%s\n' "$out" | sed 's/^/      /'
fi
# helm lint compiles the schema against its meta-schema and checks
# values.yaml with it.
if out="$(helm lint "$CHART" 2>&1)"; then
    ok "values.yaml passes the schema"
else
    fail "helm lint"
    printf '%s\n' "$out" | sed 's/^/      /' | tail -6
fi

echo "=== Values in the forms --set, --set-string and values files deliver"
passes --set smtpPort=587
passes --set-string smtpPort=587
passes --set wordpressPassword=123456
passes --set replicaCount=2
passes --set-string replicaCount=2
passes --set-string idx.startupDelay=45
passes --set persistence.size=20
passes --set externalDatabase.port=3306 --set mariadb.enabled=false --set externalDatabase.host=db
passes --set-string externalDatabase.port=3306 --set mariadb.enabled=false --set externalDatabase.host=db
passes --set wordpressCacheInstanceId=1512969306
passes --set wordpressWpCache=true
passes --set wordpressPlugins=all
passes --set-json 'wordpressPlugins=["akismet","hello"]'
# Switches as 0/1, which a template's `if` reads as off and on, and as text.
passes --set fim.enabled=1
passes --set idx.enabled=0
passes --set-string networkPolicy.enabled=true

echo "=== Lists also pass as maps and as text, maps as an empty list or as template text"
passes --set-json 'tolerations={}'
passes --set-json 'nodeSelector=[]'
passes --set-json 'extraEnvVars={}'
passes --set resources=
passes --set-json 'resources=null'
passes --set-json 'persistence.storageClass=null'
passes --set-string 'podAnnotations=team: ops'
passes --set-string 'commonLabels=team: ops'
passes --set-string 'tolerations=- operator: Exists'
passes --set fim.enabled=true --set-string 'fim.tolerations=- operator: Exists'
passes --set fim.enabled=true --set-string 'fim.nodeSelector=kubernetes.io/os: linux'

# A list as a map of entries: where the chart ranges over the value, the
# entries of a map render like those of a list. Releases use the form to
# merge entries from several values files.
passes --set-json 'extraDeploy={"extra":{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"extra"}}}'
passes --set-json 'extraDeploy=[{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"extra"}}]'
passes --set ingress.enabled=true --set-json 'ingress.extraHosts={"alias":{"name":"blog.example.com","path":"/"}}'
passes --set secondaryIngress.enabled=true --set-json 'secondaryIngress.extraHosts={"alias":{"name":"blog.example.com","path":"/"}}'
# A list as text, where the template writes the value out as it is.
passes --set-string 'service.loadBalancerSourceRanges=[10.0.0.0/8\, 192.168.0.0/16]'

echo "=== A key the schema does not list is left to the chart"
passes --set unknownTopLevel.key=1
passes --set image.tag=1.2.3
passes --set mariadb.architecture=replication
passes --set updateStrategy.rollingUpdate.maxSurge=1
passes --set livenessProbe.terminationGracePeriodSeconds=30

echo "=== A value the chart cannot use is refused"
refused /restApiHardening/mode     --set-json 'restApiHardening.mode=false'
refused /phpExecutionAllowlist/mode --set phpExecutionAllowlist.mode=audit
refused /nginx/htaccessPolicy      --set nginx.htaccessPolicy=block
refused /ingress/enabled           --set-json 'ingress.enabled=["true"]'
refused /replicaCount              --set-json 'replicaCount=1.5'
refused /smtpHost                  --set-json 'smtpHost=["mail.example.com"]'
refused /extraDeploy               --set-json 'extraDeploy=5'
refused /phpExecutionAllowlist/extraAllowedPaths --set-json 'phpExecutionAllowlist.extraAllowedPaths={"a":"~*^/x\\.php$"}'
refused /wordpressWpCache          --set-json 'wordpressWpCache="true"'
# Switches that were limited to true and false before: the text "false"
# would count as on.
refused /mariadb/enabled           --set-string mariadb.enabled=false
refused /ingress/enabled           --set-string ingress.enabled=false
refused /metrics/enabled           --set metrics.enabled=1
# The two lists of rules: an entry with a misspelled or missing key.
refused /nginx/deniedPaths/0       --set-json 'nginx.deniedPaths=[{"pth":"/wp-content/uploads/x"}]'
refused /nginx/deniedPaths/0       --set-json 'nginx.deniedPaths=[{"path":"/a","acton":"honeypot"}]'
refused /nginx/deniedPaths/0/action --set-json 'nginx.deniedPaths=[{"path":"/a","action":"teapot"}]'
refused /wordpressPreinstallPlugins/0 --set-json 'wordpressPreinstallPlugins=[{"name":"two-factor","activ":true}]'
refused /wordpressPreinstallPlugins/0 --set-json 'wordpressPreinstallPlugins=[{"activate":true}]'

echo "=== The schema changes no render"
# same_render <desc> <helm args...>: with and without the schema the chart
# renders the same manifests. Secrets are left out of the comparison: their
# generated passwords differ between any two renders.
same_render() {
    local desc="$1" with without; shift
    if with="$(helm template tst "$CHART" -n default "$@" 2>&1)" \
       && without="$(helm template tst "$CHART" -n default "$@" --skip-schema-validation 2>&1)" \
       && [ "$(strip_secrets <<<"$with")" = "$(strip_secrets <<<"$without")" ]; then
        ok "same render: $desc"
    else
        fail "the render differs with and without the schema: $desc"
    fi
}
strip_secrets() {
    python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") != "Secret"]
print(yaml.safe_dump_all(docs, sort_keys=True))
'
}
same_render "defaults"
same_render "features on" --set metrics.enabled=true --set metrics.serviceMonitor.enabled=true \
        --set idx.enabled=true --set fim.enabled=true --set wordpressConfigureCache=true \
        --set memcached.enabled=true --set ingress.enabled=true --set ingress.hostname=example.com \
        --set restApiHardening.mode=enforce --set phpExecutionAllowlist.mode=report
same_render "denied paths fixture" -f "$(dirname "$0")/fixtures/denied-paths-multi.yaml"
for example in "$(dirname "$0")"/../../examples/*/values.yaml; do
    [ -f "$example" ] || continue
    same_render "example ${example#"$(dirname "$0")"/../../}" -f "$example"
done

echo "=== The image trackers keep the schema's defaults"
# The trackers change a pinned image in values.yaml. The schema repeats the
# default, so a tracker that left it alone would open a pull request this
# very test fails on. scripts/schema-default.sh is their step for it.
PKG_TMP="$(mktemp -d)"
trap 'rm -rf "$PKG_TMP"' EXIT
REPO="$(dirname "$0")/../.."
SET_DEFAULT="$REPO/scripts/schema-default.sh"
cp "$CHART/values.schema.json" "$PKG_TMP/schema.json"
# pin <key>: the default of <key> in values.yaml.
pin() {
    python3 -c '
import sys, yaml
value = yaml.safe_load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value[key]
print(value)
' "$CHART/values.yaml" "$1"
}
for key in metrics.image.tag memcached.image; do
    if "$SET_DEFAULT" "$key" "$(pin "$key")" "$PKG_TMP/schema.json" \
       && cmp -s "$PKG_TMP/schema.json" "$CHART/values.schema.json"; then
        ok "setting $key to its present default changes nothing"
    else
        fail "scripts/schema-default.sh rewrites the schema when setting $key to its present default"
    fi
    if "$SET_DEFAULT" "$key" "a-new-pin" "$PKG_TMP/schema.json" \
       && [ "$(diff "$PKG_TMP/schema.json" "$CHART/values.schema.json" | grep -c '^[<>]')" = 2 ] \
       && grep -qF '"default": "a-new-pin"' "$PKG_TMP/schema.json"; then
        ok "a new pin for $key changes one line of the schema"
    else
        fail "scripts/schema-default.sh does not change exactly the default of $key"
    fi
    cp "$CHART/values.schema.json" "$PKG_TMP/schema.json"
done
if "$SET_DEFAULT" metrics.image.nope x "$PKG_TMP/schema.json" 2>/dev/null \
   || "$SET_DEFAULT" replicaCount 2 "$PKG_TMP/schema.json" 2>/dev/null \
   || ! cmp -s "$PKG_TMP/schema.json" "$CHART/values.schema.json"; then
    fail "scripts/schema-default.sh accepts a key without a text default, or changes the file while refusing"
else
    ok "a key without a text default is refused"
fi
# SC2016: the needles are the workflows' own text, variables and all.
# shellcheck disable=SC2016
if grep -qF 'scripts/schema-default.sh metrics.image.tag "${NEW}"' "$REPO/.github/workflows/image-version-check.yml" \
   && grep -qF 'scripts/schema-default.sh memcached.image "docker.dragonflydb.io/dragonflydb/dragonfly:${NEW}"' \
        "$REPO/.github/workflows/dragonfly-version-check.yml"; then
    ok "both trackers set the schema's default with their bump"
else
    fail "a tracker changes a pinned image in values.yaml without scripts/schema-default.sh"
fi

echo "=== The packaged chart carries the schema"
if helm package "$CHART" -d "$PKG_TMP" >/dev/null 2>&1 \
   && tar -tzf "$PKG_TMP"/wordpress-nginx-*.tgz | grep -qx 'wordpress-nginx/values.schema.json'; then
    ok "values.schema.json is in the package"
else
    fail "values.schema.json is not in the package"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "=== $FAILURES check(s) FAILED"
    exit 1
fi
echo "=== All checks passed"
