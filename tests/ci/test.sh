#!/usr/bin/env bash
#
# Test for what CI and a release rely on outside the chart and the image:
# the rules every workflow follows, the scripts a release runs (tag check,
# release candidates, release notes, Artifact Hub annotations, tags after
# signing) and the order of its jobs, the list of images the daily CVE scan
# covers, the findings that scan accepts, and the Renovate configuration.
# tests/ci/fake-oras/oras stands in for the registry.
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
      - {uses: docker/login-action@v4, with: {registry: ghcr.io}}
  five:
    uses: example/workflows/.github/workflows/build.yml@main
    permissions: write-all
  six:
    uses: ./.github/workflows/other.yml
    permissions:
      id-token: write
EOF
out="$(python3 "$HERE/check-workflows.py" "$WORK/bad" 2>&1 || true)"
for needle in "not pinned by a commit SHA" "has no '# vX.Y.Z' comment" "no timeout-minutes" \
              "not on a pinned runner image" "contents: write for every job" \
              "expression inside the run script" "keeps its token" "without a '# renovate:' line" \
              "job two has permissions: write-all" "job five has permissions: write-all" \
              "job four: docker/login-action@v4 is not pinned" \
              "job five: example/workflows/.github/workflows/build.yml@main is not pinned" \
              "more than one job can get an OIDC token: bad.yml: job three; bad.yml: job four; bad.yml: job six"; do
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

echo "=== Release candidates"
accepts "a release candidate of the chart's version"   "$TAG_CHECK" "$version-rc.1"
accepts "a later candidate"                            "$TAG_CHECK" "$version-rc.12"
refuses "a candidate of another version"               "$TAG_CHECK" "${version}9-rc.1"
refuses "a candidate without a number"                 "$TAG_CHECK" "$version-rc"
refuses "a candidate number with a leading zero"       "$TAG_CHECK" "$version-rc.01"
refuses "another suffix than rc"                       "$TAG_CHECK" "$version-beta.1"
refuses "the -N suffix of the earlier scheme"          "$TAG_CHECK" "$version-1"

# The chart a candidate packages: the tag's version, and the two images of
# this project at it; appVersion and every other image stay.
RELEASE_VERSION="$ROOT/scripts/chart-release-version.sh"
cp "$ROOT/chart/Chart.yaml" "$WORK/Chart.yaml"
accepts "a release leaves the chart as it is"          "$RELEASE_VERSION" "$version" "$WORK/Chart.yaml"
if cmp -s "$ROOT/chart/Chart.yaml" "$WORK/Chart.yaml"; then ok "the file is unchanged"
else fail "chart-release-version.sh changed the chart of a release"; fi
accepts "a candidate gets its version"                 "$RELEASE_VERSION" "$version-rc.1" "$WORK/Chart.yaml"
changed="$(diff "$ROOT/chart/Chart.yaml" "$WORK/Chart.yaml" | grep -c '^>' || true)"
if [ "$changed" = 3 ] \
   && grep -qxF "version: $version-rc.1" "$WORK/Chart.yaml" \
   && grep -qxF "      image: ghcr.io/ioanalytica/wordpress-nginx:$version-rc.1" "$WORK/Chart.yaml" \
   && grep -qxF "      image: ghcr.io/ioanalytica/wordpress-idx:$version-rc.1" "$WORK/Chart.yaml"; then
    ok "the candidate's chart names its version and its two images, and nothing else changed"
else
    fail "the candidate's chart: $changed lines changed, expected version and the two images"
fi
printf 'version: 1.0.0\n' >"$WORK/short.yaml"
refuses "a chart without the two image entries"        "$RELEASE_VERSION" 1.0.0-rc.1 "$WORK/short.yaml"

echo "=== Release notes and Artifact Hub changes come from the changelog"
SECTION="$ROOT/scripts/changelog-section.sh"
cat >"$WORK/CHANGELOG.md" <<'EOF'
# Changelog

## Unreleased

* Not released yet.

## 7.1.409

* **A lead in bold.** More text. Another sentence.
  * A nested bullet that belongs to the one above.
* A bullet without a lead, e.g. this one. A second sentence.
* See the [release notes](https://example.com/notes) and `code`.

### Project and CI

* A change to the repository alone.

## 7.1.4-7

* The earlier scheme.
EOF
got="$("$SECTION" 7.1.409 "$WORK/CHANGELOG.md" | head -n 1)"
[ "$got" = "* **A lead in bold.** More text. Another sentence." ] && ok "a version's section starts at its first line" \
    || fail "changelog-section 7.1.409 starts with '$got'"
[ "$("$SECTION" 7.1.409-rc.2 "$WORK/CHANGELOG.md")" = "$("$SECTION" 7.1.409 "$WORK/CHANGELOG.md")" ] \
    && ok "a candidate without a section gets its release's" || fail "a candidate's notes differ from its release's"
[ "$("$SECTION" 7.1.4-7 "$WORK/CHANGELOG.md")" = "* The earlier scheme." ] \
    && ok "a version of the earlier scheme has its own section" || fail "changelog-section 7.1.4-7"
[ -z "$("$SECTION" 7.1.410 "$WORK/CHANGELOG.md")" ] && ok "a version without a section prints nothing" \
    || fail "changelog-section printed something for a version without a section"
if "$SECTION" 7.1.409 "$WORK/CHANGELOG.md" | grep -q 'earlier scheme\|Not released'; then
    fail "a section runs into its neighbours"
else ok "a section ends at the next version"; fi

ANNOTATE="$ROOT/scripts/artifacthub-annotations.sh"
cp "$ROOT/chart/Chart.yaml" "$WORK/Chart.yaml"
accepts "the annotations of a release"                 "$ANNOTATE" 7.1.409 "$WORK/Chart.yaml" "$WORK/CHANGELOG.md"
changes="$(yq '.annotations["artifacthub.io/changes"]' "$WORK/Chart.yaml" | yq -o=json -I=0 .)"
want='["A lead in bold.","A bullet without a lead, e.g. this one.","See the release notes and code."]'
if [ "$changes" = "$want" ]; then ok "changes are the leads, as plain text, without the repository's own"
else fail "artifacthub.io/changes is $changes"; fi
[ "$(yq '.annotations["artifacthub.io/prerelease"]' "$WORK/Chart.yaml")" = false ] && ok "a release is no prerelease" \
    || fail "a release is marked as a prerelease"
[ "$(yq '.annotations["artifacthub.io/images"]' "$WORK/Chart.yaml" | yq 'length')" -gt 0 ] && ok "the images list is still there" \
    || fail "the images list is gone"
refuses "a chart that has the annotations already"     "$ANNOTATE" 7.1.409 "$WORK/Chart.yaml" "$WORK/CHANGELOG.md"
cp "$ROOT/chart/Chart.yaml" "$WORK/Chart.yaml"
accepts "the annotations of a candidate"               "$ANNOTATE" 7.1.409-rc.1 "$WORK/Chart.yaml" "$WORK/CHANGELOG.md"
grep -qxF '  artifacthub.io/prerelease: "true"' "$WORK/Chart.yaml" && ok "a candidate is a prerelease" \
    || fail "a candidate is not marked as a prerelease"
for key in artifacthub.io/changes artifacthub.io/prerelease; do
    if grep -q "^  $key:" "$ROOT/chart/Chart.yaml"; then fail "chart/Chart.yaml carries $key; a release writes it"
    else ok "chart/Chart.yaml leaves $key to the release"; fi
done

echo "=== Tags are set after signing, and a published version stays"
TAG_IMAGES="$ROOT/scripts/release-tag-images.sh"
W=ghcr.io/ioanalytica/wordpress-nginx
I=ghcr.io/ioanalytica/wordpress-idx
nl=$'\n'
export ORAS_FAKE_STATE="$WORK/registry"
mkdir -p "$ORAS_FAKE_STATE/runs"
for pair in aaa:12 bbb:12 ccc:13 ddd:14 old:; do echo "${pair#*:}" >"$ORAS_FAKE_STATE/runs/sha256:${pair%%:*}"; done
# tagged <image> <tag>: the digest the stand-in registry has for a tag.
tagged() { cat "$ORAS_FAKE_STATE/tags/${1//\//_}/$2" 2>/dev/null || true; }
with_oras() { PATH="$HERE/fake-oras:$PATH" "$@"; }

accepts "a release tags both images"   with_oras "$TAG_IMAGES" 7.1.409 \
    "$W@sha256:aaa" "$W:7.1.409$nl$W:latest" "$I@sha256:bbb" "$I:7.1.409$nl$I:latest"
if [ "$(tagged "$W" 7.1.409)$(tagged "$W" latest)$(tagged "$I" 7.1.409)$(tagged "$I" latest)" = "sha256:aaasha256:aaasha256:bbbsha256:bbb" ]; then
    ok "the version and latest name the release's digests"
else fail "tags after a release: $(grep -r . "$ORAS_FAKE_STATE/tags")"; fi
accepts "a re-run of the tag job"      with_oras "$TAG_IMAGES" 7.1.409 "$W@sha256:aaa" "$W:7.1.409$nl$W:latest"
refuses "latest for a candidate"       with_oras "$TAG_IMAGES" 7.1.410-rc.1 "$W@sha256:ccc" "$W:7.1.410-rc.1$nl$W:latest"
[ -z "$(tagged "$W" 7.1.410-rc.1)" ] && ok "a refused list sets no tag at all" || fail "a refused list left a tag behind"
refuses "a tag of another image"       with_oras "$TAG_IMAGES" 7.1.410 "$W@sha256:ccc" "$I:7.1.410"
refuses "an empty list"                with_oras "$TAG_IMAGES" 7.1.410 "$W@sha256:ccc" ""
refuses "an index of no release run"   with_oras "$TAG_IMAGES" 7.1.410 "$W@sha256:old" "$W:7.1.410"
refuses "a version published already"  with_oras "$TAG_IMAGES" 7.1.409 "$W@sha256:ddd" "$W:7.1.409$nl$W:latest"
[ "$(tagged "$W" 7.1.409)$(tagged "$W" latest)" = "sha256:aaasha256:aaa" ] && ok "the published version and latest stay" \
    || fail "a second build of 7.1.409 moved a tag"
accepts "a later release moves latest" with_oras "$TAG_IMAGES" 7.1.410 "$W@sha256:ddd" "$W:7.1.410$nl$W:latest"
accepts "a late re-run of an older release" with_oras "$TAG_IMAGES" 7.1.411 "$W@sha256:ccc" "$W:7.1.411$nl$W:latest"
[ "$(tagged "$W" latest)" = "sha256:ddd" ] && [ "$(tagged "$W" 7.1.411)" = "sha256:ccc" ] \
    && ok "latest stays on the later run's image" || fail "a late re-run moved latest back"
refuses "a registry that answers with an error" env ORAS_FAKE_BROKEN=1 PATH="$HERE/fake-oras:$PATH" \
    "$TAG_IMAGES" 7.1.412 "$W@sha256:ddd" "$W:7.1.412"

# The chart's tag, and the sidecar's own version: set once, never moved.
TAG_ONCE="$ROOT/scripts/release-tag-once.sh"
C=ghcr.io/ioanalytica/charts/wordpress-nginx
accepts "the chart gets its version"   with_oras "$TAG_ONCE" "$C@sha256:eee" 7.1.409
accepts "a re-run finds it there"      with_oras "$TAG_ONCE" "$C@sha256:eee" 7.1.409
refuses "another chart under the same version" with_oras "$TAG_ONCE" "$C@sha256:fff" 7.1.409
[ "$(tagged "$C" 7.1.409)" = "sha256:eee" ] && ok "the chart's version stays on the first chart" || fail "the chart's version moved"
accepts "the sidecar's own version, when it is new" with_oras "$TAG_ONCE" --keep "$I@sha256:bbb" 1.3.8
accepts "a later build of the same sidecar version" with_oras "$TAG_ONCE" --keep "$I@sha256:ccc" 1.3.8
[ "$(tagged "$I" 1.3.8)" = "sha256:bbb" ] && ok "the sidecar's version stays on its first build" || fail "the sidecar's version moved"
refuses "a registry error while tagging once" env ORAS_FAKE_BROKEN=1 PATH="$HERE/fake-oras:$PATH" "$TAG_ONCE" "$C@sha256:eee" 7.1.410
refuses "a reference without a digest"  with_oras "$TAG_ONCE" "$C:7.1.409" 7.1.409

# Artifact Hub's repository metadata moves forward only, like latest.
METADATA="$ROOT/scripts/release-artifacthub-metadata.sh"
accepts "the first release pushes the metadata"     with_oras "$METADATA" "$C" 12 "$ROOT/artifacthub-repo.yml"
accepts "a later release replaces it"               with_oras "$METADATA" "$C" 14 "$ROOT/artifacthub-repo.yml"
accepts "a late re-run of an older release"         with_oras "$METADATA" "$C" 13 "$ROOT/artifacthub-repo.yml"
[ "$(tagged "$C" artifacthub.io)" = "sha256:pushed-by-run-14" ] && ok "the later run's metadata stays" \
    || fail "an older run replaced the metadata: $(tagged "$C" artifacthub.io)"
accepts "a re-run of the same release pushes again" with_oras "$METADATA" "$C" 14 "$ROOT/artifacthub-repo.yml"
refuses "a registry error while reading the metadata" env ORAS_FAKE_BROKEN=1 PATH="$HERE/fake-oras:$PATH" \
    "$METADATA" "$C" 15 "$ROOT/artifacthub-repo.yml"
refuses "a metadata file that is not there"         with_oras "$METADATA" "$C" 15 "$WORK/none.yml"

UNPUBLISHED="$ROOT/scripts/release-unpublished.sh"
accepts "a version no repository has"   with_oras "$UNPUBLISHED" 7.1.499 "$W" "$I" "$C"
refuses "a version one repository has"  with_oras "$UNPUBLISHED" 7.1.409 "$W" "$I" "$C"
refuses "a registry error while asking" env ORAS_FAKE_BROKEN=1 PATH="$HERE/fake-oras:$PATH" "$UNPUBLISHED" 7.1.499 "$W"

echo "=== The search sidecar's version comes from the submodule"
IDX_VERSION="$ROOT/scripts/idx-version.sh"
mkdir -p "$WORK/idx/app"
echo '{"version": "1.4.0"}' >"$WORK/idx/app/package.json"
[ "$("$IDX_VERSION" "$WORK/idx")" = 1.4.0 ] && ok "the version of app/package.json" || fail "idx-version.sh on a fixture"
echo '{"version": "1.4"}' >"$WORK/idx/app/package.json"
refuses "a version that is not x.y.z"   "$IDX_VERSION" "$WORK/idx"
refuses "a directory without the app"   "$IDX_VERSION" "$WORK"
# The pinned submodule itself, where it is checked out: a pin without a
# readable version would fail the release's first job.
if [ -e "$ROOT/wordpress-idx/app/package.json" ]; then
    accepts "the pinned wordpress-idx has a version" "$IDX_VERSION"
elif [ -n "${CI:-}" ]; then
    fail "the wordpress-idx submodule is not checked out"
else
    echo "skip: the wordpress-idx submodule is not checked out (git submodule update --init)"
fi
if [ "$(git -C "$ROOT" config -f .gitmodules submodule.wordpress-idx.url)" = "https://github.com/ioanalytica/wordpress-idx.git" ]; then
    ok "the submodule is wordpress-idx, by its public address"
else
    fail ".gitmodules does not name https://github.com/ioanalytica/wordpress-idx.git"
fi

echo "=== The release signs before it tags"
RELEASE="$ROOT/.github/workflows/release.yml"
BUILD="$ROOT/.github/workflows/build-image.yml"
if out="$(python3 "$HERE/check-release-workflow.py" "$RELEASE" "$BUILD" 2>&1)"; then ok "one job signs, tags follow the signatures, the release follows the tags"
else
    fail "the release workflow"
    printf '%s\n' "$out" | sed 's/^/      /'
fi
signer="$(sed -n "s/^  SIGNER: '\(.*\)'$/\1/p" "$RELEASE")"
# shellcheck disable=SC2016 # the README's and the workflow's own variables
if [ -n "$signer" ] && grep -qF -- "--certificate-identity \"$signer\$version\"" "$ROOT/README.md" \
   && grep -qF -- '--certificate-identity "$SIGNER$GITHUB_REF_NAME"' "$RELEASE"; then
    ok "the README verifies with the identity the release signs and checks with: the workflow at the version's tag"
else
    fail "README.md and release.yml do not verify with the same identity, '$signer' followed by the version"
fi

echo "=== Latest is the release with the highest version"
IS_LATEST="$ROOT/scripts/release-is-latest.sh"
# latest <desc> <expected> <version> <published versions, one a line>
latest() {
    local got
    got="$("$IS_LATEST" "$3" <<<"$4" 2>&1)" || true
    if [ "$got" = "$2" ]; then ok "$1"; else fail "$1 — expected $2, got '$got'"; fi
}
latest "the first release of all"                 true  7.1.409 ""
latest "a release above every published one"      true  7.1.409 "7.1.408${nl}7.1.4-7${nl}7.1.4-6"
latest "a re-run of the newest release"           true  7.1.409 "7.1.409${nl}7.1.408"
latest "a late re-run of an older release"        false 7.1.409 "7.1.410${nl}7.1.409${nl}7.1.408"
latest "a release of the next WordPress release"  true  7.1.500 "7.1.499${nl}7.1.4-7"
latest "a version of the earlier scheme"          false 7.1.4-7 "7.1.408"
latest "a release candidate"                      false 7.1.410-rc.1 "7.1.409"

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
    # A tag or a digest stands in the last component; a colon before it is
    # a registry's port.
    case "${want##*/}" in *:*|*@*) ;; *) want="$want:latest" ;; esac
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
printf '      containers:\n        - image: busybox\n        - image: {{ .Values.b.image }}\n          image: "alpine:3.24"  # a comment\n' >"$WORK/chart/templates/x.yaml"
got="$("$IMAGES" "$WORK/chart" | jq -r 'map(.ref) | sort | join(" ")')"
want="docker.io/alpine:3.24 docker.io/busybox:latest docker.io/other:3 registry.example:5000/group/thing:1.2"
if [ "$got" = "$want" ]; then ok "a registry with a port, a bare name and a template's own images, one with a comment"
else fail "expected '$want', got '$got'"; fi
# A digest in the values is what the chart runs, whatever the tag says.
digest="sha256:$(printf '%064d' 1)"
printf 'a:\n  image:\n    repository: one/thing\n    tag: 1.10\n    digest: %s\nb:\n  image: "two/other:2@%s"\n' "$digest" "$digest" >"$WORK/chart/values.yaml"
rm "$WORK/chart/templates/x.yaml"
got="$("$IMAGES" "$WORK/chart" | jq -r 'map(.ref) | sort | join(" ")')"
want="docker.io/one/thing@$digest docker.io/two/other@$digest"
if [ "$got" = "$want" ]; then ok "an image pinned by digest is scanned by that digest"
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
has "its commits are signed off"                 '.commitBody == "Signed-off-by: {{{gitAuthor}}}"'
has "the sidecar's image does not wait for a release date GHCR does not give" \
    'any(.packageRules[]; .matchPackageNames == ["ghcr.io/ioanalytica/wordpress-idx"] and .minimumReleaseAgeBehaviour == "timestamp-optional")'
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
