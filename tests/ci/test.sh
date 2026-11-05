#!/usr/bin/env bash
#
# Test for what CI and a release rely on outside the chart and the image:
# the rules every workflow follows, the release tag check, the list of images
# the daily CVE scan covers, the findings that scan accepts, and the Renovate
# configuration.
#
# Needs helm with the chart's dependencies resolved (helm dependency update
# chart/), yq, jq and python3 with PyYAML, as the template test does.
#
#   tests/ci/test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FAILURES=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()   { echo "ok:   $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# accepts <desc> <command...> / refuses <desc> <command...>
accepts() {
    local desc="$1" out; shift
    if out="$("$@" 2>&1)"; then ok "$desc"; else fail "$desc — refused: $out"; fi
}
refuses() {
    local desc="$1" out; shift
    if out="$("$@" 2>&1)"; then fail "$desc — accepted: $out"; else ok "$desc"; fi
}

echo "=== Workflows follow the rules"
if out="$(python3 "$HERE/check-workflows.py" "$ROOT" 2>&1)"; then
    ok "every workflow: pinned actions, time limits, pinned runners, least permissions"
else
    fail "workflow rules"
    printf '%s\n' "$out" | sed 's/^/      /'
fi

# The checker itself: a workflow that breaks every rule is reported for each.
mkdir -p "$WORK/bad/.github/workflows"
cat >"$WORK/bad/.github/workflows/bad.yml" <<'EOF'
name: bad
on: push
permissions:
  contents: write
env:
  TOOL_VERSION: 1.2.3
jobs:
  one:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - run: echo "${{ github.event.pull_request.title }}"
  two:
    runs-on: ubuntu-26.04
    timeout-minutes: 5
    permissions: write-all
    steps:
      - run: "true"
  three:
    runs-on: ubuntu-26.04
    timeout-minutes: 5
    permissions:
      id-token: write
      pages: read
    steps:
      - run: "true"
  four:
    runs-on: ubuntu-26.04
    timeout-minutes: 5
    permissions:
      id-token: write
    steps:
      - run: "true"
EOF
out="$(python3 "$HERE/check-workflows.py" "$WORK/bad" 2>&1 || true)"
for needle in "not pinned by a commit SHA" "has no '# vX.Y.Z' comment" "no timeout-minutes" \
              "not on a pinned runner image" "contents: write for every job" \
              "expression inside the run script" "keeps its token" "without a '# renovate:' line" \
              "has permissions: write-all" \
              "more than one job can get an OIDC token: bad.yml: job three; bad.yml: job four"; do
    if grep -qF -- "$needle" <<<"$out"; then ok "the checker reports: $needle"
    else fail "the checker misses: $needle"; fi
done

echo "=== Release tag check"
TAG_CHECK="$ROOT/scripts/check-release-tag.sh"
version="$(sed -n 's/^version: *//p' "$ROOT/chart/Chart.yaml" | tr -d '"')"
accepts "the chart's version as the tag"            "$TAG_CHECK" "$version"
refuses "another version as the tag"                "$TAG_CHECK" "${version}9"
refuses "the version with a v prefix"               "$TAG_CHECK" "v$version"
refuses "no tag at all"                             "$TAG_CHECK"
printf 'name: x\n' >"$WORK/noversion.yaml"
refuses "a Chart.yaml without a version"            "$TAG_CHECK" "$version" "$WORK/noversion.yaml"

echo "=== The CVE scan covers every image the chart can run"
IMAGES="$ROOT/scripts/cve-scan-images.sh"
if list="$("$IMAGES" 2>&1)" && jq -e 'type == "array" and length > 0' <<<"$list" >/dev/null; then
    ok "the list is a JSON array: $(jq -r 'map(.name) | join(", ")' <<<"$list")"
else
    fail "cve-scan-images.sh: $list"
    list='[]'
fi
# Every image a render with all optional parts switched on asks for is in the
# list: our own at :latest, any other at the tag it is rendered with, one
# without a tag at :latest.
rendered="$(helm template tst "$ROOT/chart" \
    --set idx.enabled=true --set metrics.enabled=true --set memcached.enabled=true --set fim.enabled=true 2>&1)" \
    || { fail "helm template with every optional part: $rendered"; rendered=""; }
count=0
while IFS= read -r image; do
    [ -n "$image" ] || continue
    count=$((count + 1))
    case "$image" in
        ghcr.io/ioanalytica/*) want="${image%:*}:latest" ;;
        *.*/*|*:*/*)           want="$image" ;;
        *)                     want="docker.io/$image" ;;
    esac
    case "$want" in *:*) ;; *) want="$want:latest" ;; esac
    if jq -e --arg ref "$want" 'any(.[]; .ref == $ref)' <<<"$list" >/dev/null; then
        ok "scanned: $want"
    else
        fail "the chart renders $image, which the scan does not cover as $want"
    fi
done < <(sed -n 's/^ *image: *//p' <<<"$rendered" | tr -d '"' | sort -u)
[ "$count" -ge 5 ] || fail "the render names $count images, fewer than the chart has"

# An image whose tag YAML reads as a number is refused, not scanned at
# another tag.
mkdir -p "$WORK/chart/templates"
printf 'a:\n  image:\n    repository: example/thing\n    tag: 1.10\n' >"$WORK/chart/values.yaml"
refuses "a tag that is a number"                    "$IMAGES" "$WORK/chart"
printf 'a:\n  image:\n    repository: one/thing\n    tag: "1"\nb:\n  image: "two/thing:2"\n' >"$WORK/chart/values.yaml"
refuses "two images of one name"                    "$IMAGES" "$WORK/chart"
printf 'a:\n  image: "registry.example:5000/group/thing:1.2"\nb:\n  image:\n    repository: other\n    tag: "3"\n' >"$WORK/chart/values.yaml"
printf '      containers:\n        - image: busybox\n        - image: {{ .Values.b.image }}\n' >"$WORK/chart/templates/x.yaml"
got="$("$IMAGES" "$WORK/chart" | jq -r 'map(.ref) | sort | join(" ")')"
want="docker.io/busybox:latest docker.io/other:3 registry.example:5000/group/thing:1.2"
if [ "$got" = "$want" ]; then ok "a registry with a port, a bare name and a template's own image"
else fail "expected '$want', got '$got'"; fi

echo "=== Accepted findings of the CVE scan"
# Each entry: the vulnerability, where it applies, why it waits, and an
# expiry date at most three months out. A date that has passed is the scan's
# business, which then fails on the finding again; it does not fail this test.
if out="$(python3 - "$ROOT/.github/cve-scan-accepted.yaml" <<'EOF' 2>&1
import datetime, re, sys, yaml
entries = (yaml.safe_load(open(sys.argv[1])) or {}).get("vulnerabilities") or []
limit = datetime.date.today() + datetime.timedelta(days=93)
problems = []
seen = set()
for entry in entries:
    name = entry.get("id", "an entry without id")
    if not re.fullmatch(r"(CVE-\d{4}-\d+|GHSA(-[0-9a-z]{4}){3})", str(entry.get("id", ""))):
        problems.append(f"{name}: not a CVE or GHSA id")
    if name in seen:
        problems.append(f"{name}: listed twice")
    seen.add(name)
    if not (entry.get("paths") or entry.get("purls")):
        problems.append(f"{name}: neither paths nor purls, so it would apply to every package")
    if len(str(entry.get("statement", "")).split()) < 8:
        problems.append(f"{name}: no statement that says why it waits and on what")
    expiry = entry.get("expired_at")
    if not isinstance(expiry, datetime.date):
        problems.append(f"{name}: no expired_at date")
    elif expiry > limit:
        problems.append(f"{name}: expires {expiry}, more than three months out")
    unknown = set(entry) - {"id", "paths", "purls", "statement", "expired_at"}
    if unknown:
        problems.append(f"{name}: unknown keys {sorted(unknown)}")
print("\n".join(problems) if problems else f"{len(entries)} entries")
sys.exit(1 if problems else 0)
EOF
)"; then
    ok "every accepted finding has a place, a reason and an expiry date ($out)"
else
    fail "accepted findings"
    printf '%s\n' "$out" | sed 's/^/      /'
fi
if grep -q 'trivyignores: .github/cve-scan-accepted.yaml' "$ROOT/.github/workflows/cve-scan.yml" \
   && grep -q 'ignore-unfixed: true' "$ROOT/.github/workflows/cve-scan.yml"; then
    ok "the scan's failing step reads the accepted findings and skips what has no fix"
else
    fail "cve-scan.yml no longer reads .github/cve-scan-accepted.yaml in a step with ignore-unfixed"
fi

echo "=== Renovate configuration"
RENOVATE="$ROOT/.github/renovate.json"
# has <desc> <jq filter that is true>
has() {
    if jq -e "$2" "$RENOVATE" >/dev/null 2>&1; then ok "$1"; else fail "$1"; fi
}
has "the file is JSON with the Renovate schema"  '."$schema" == "https://docs.renovatebot.com/renovate-schema.json"'
has "actions are pinned by digest"               '.extends | index("helpers:pinGitHubActionDigestsToSemver")'
has "Dragonfly stays with its own workflow"      '[.packageRules[] | select(.enabled == false) | .matchPackageNames[]?] | index("docker.dragonflydb.io/dragonflydb/dragonfly")'
has "the common chart dependency stays manual"   '.helmv3.enabled == false'
has "only the chart's own values file is read"   '."helm-values".managerFilePatterns == ["/^chart/values\\.yaml$/"]'
has "a moved action tag waits for approval"      'any(.packageRules[]; .matchUpdateTypes == ["digest"] and .dependencyDashboardApproval == true)'
has "the base image moves only by approval"      'any(.packageRules[]; .matchDepNames == ["shinsenter/php"] and .dependencyDashboardApproval == true)'

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "=== $FAILURES check(s) FAILED"
    exit 1
fi
echo "=== All checks passed"
