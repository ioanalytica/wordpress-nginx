#!/bin/bash
# Guard test for the page "Try it locally" (examples/k3d/README.md), its
# runner (run.sh, chart.sh) and its workflow
# (.github/workflows/try-locally.yml). The three name the same things in
# several places: the page's blocks, its URL and chart, the cluster, the k3d
# and k3s versions, the paths the workflow watches. A block the page gains or
# loses, a name changed on one side only or a path the workflow does not
# watch fails here, in a second and without a cluster, rather than in the
# k3d run of the next pull request that happens to touch the chart.
#
#   tests/try-locally/test.sh

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERE="$TRY_ROOT/tests/try-locally"
WF="$TRY_ROOT/.github/workflows/try-locally.yml"
VALUES="$EXAMPLES/values.yaml"
FAILURES=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ok DESC, bad DESC - report one check, and count the failed ones.
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
# is DESC COMMAND... - ok when the command succeeds.
is() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
# has DESC NEEDLE TEXT - ok when a line of TEXT is NEEDLE.
has() {
  if grep -qxF -- "$2" <<<"$3"; then ok "$1"; else bad "$1 - no line '$2'"; fi
}

# sh_block "HEADING|N" - the page's shell block that an entry of PAGE_BLOCKS names.
sh_block() { page_block "${1%|*}" sh "${1#*|}"; }

echo "=== The page has the blocks the run takes, and no others"
for b in "${PAGE_BLOCKS[@]}"; do
  if [ -n "$(sh_block "$b")" ]; then ok "shell block ${b#*|} under '${b%|*}'"
  else bad "the page has no shell block ${b#*|} under '${b%|*}'"; fi
done
# Every command of the page is run: a block added to the page has to be
# added to PAGE_BLOCKS, and with it to run.sh.
on_page="$(grep -c '^```sh$' "$PAGE" || true)"
if [ "$on_page" -eq "${#PAGE_BLOCKS[@]}" ]; then ok "the page has ${#PAGE_BLOCKS[@]} shell blocks, the run takes ${#PAGE_BLOCKS[@]}"
else bad "the page has $on_page shell blocks, the run takes ${#PAGE_BLOCKS[@]}"; fi
other="$(grep '^```' "$PAGE" | grep -vx '```sh' | grep -vx '```' || true)"
if [ -z "$other" ]; then ok "every code block is a shell block or an output"
else bad "code blocks of a kind the run does not know: $(tr '\n' ' ' <<<"$other")"; fi
for b in "${PAGE_OUTPUTS[@]}"; do
  if [ -n "$(page_block "${b%|*}" "" "${b#*|}")" ]; then ok "output block ${b#*|} under '${b%|*}'"
  else bad "the page shows no output block ${b#*|} under '${b%|*}'"; fi
done
before=$FAILURES
for b in "${PAGE_BLOCKS[@]}"; do
  grep -qF "page \"${b%|*}\" ${b#*|}" "$HERE/run.sh" || grep -qF "page_out \"${b%|*}\" ${b#*|}" "$HERE/run.sh" \
    || bad "run.sh does not run block ${b#*|} under '${b%|*}'"
done
[ "$FAILURES" -ne "$before" ] || ok "run.sh runs every block of PAGE_BLOCKS"
before=$FAILURES
for b in "${PAGE_OUTPUTS[@]}"; do
  grep -qF "\"${b%|*}\" ${b#*|} \"\$out\"" "$HERE/run.sh" \
    || bad "run.sh does not compare output block ${b#*|} under '${b%|*}'"
done
[ "$FAILURES" -ne "$before" ] || ok "run.sh compares every block of PAGE_OUTPUTS"

echo
echo "=== A section ends at the next heading, not at a comment in a block"
REAL_PAGE="$PAGE"
PAGE="$TMP/page.md"
cat >"$PAGE" <<'EOF'
# Page

## 1. One

```sh
echo one
# a comment, not a heading
echo one more
```

```
the output
```

```sh
echo two
```

### A subsection

```sh
echo sub
```

## 2. Two

```sh
echo three
```
EOF
[ "$(page_block "## 1. " sh 1)" = "$(printf 'echo one\n# a comment, not a heading\necho one more')" ] \
  && ok "a comment line stays in its block" || bad "block 1: $(page_block "## 1. " sh 1)"
[ "$(page_block "## 1. " sh 2)" = "echo two" ] && ok "the second shell block" || bad "block 2: $(page_block "## 1. " sh 2)"
[ "$(page_block "## 1. " "" 1)" = "the output" ] && ok "a plain block is an output" || bad "output: $(page_block "## 1. " "" 1)"
[ -z "$(page_block "## 1. " sh 3)" ] && ok "a section does not run into its subsection" || bad "step 1 runs into its subsection"
[ "$(page_block "## 2. " sh 1)" = "echo three" ] && ok "the next section" || bad "step 2: $(page_block "## 2. " sh 1)"
PAGE="$REAL_PAGE"

echo
echo "=== The run puts the checkout's values and chart where the page names its own"
all=""
for b in "${PAGE_BLOCKS[@]}"; do
  all+="$(sh_block "$b" | localize /checkout/chart "--set a=b")"$'\n'
done
if grep -qF "$PAGE_URL" <<<"$all"; then bad "the page's URL is left after localize"; else ok "no block keeps the page's URL"; fi
if grep -qF "$PAGE_CHART" <<<"$all"; then bad "the released chart is left after localize"; else ok "no block keeps the released chart"; fi
has "\$url is the checkout's examples/k3d" "url=$EXAMPLES" "$all"
install="$(sh_block "## 2. |1")"
has "the install takes the chart directory and the extra flags" \
    "helm install $PAGE_RELEASE /checkout/chart --set a=b \\" "$(localize /checkout/chart "--set a=b" <<<"$install")"
has "without a chart directory the install is the page's own" \
    "helm install $PAGE_RELEASE $PAGE_CHART \\" "$(localize "" "" <<<"$install")"
has "the install reads the values file from \$url" '  -f $url/values.yaml \' "$install"
has "the install goes to the namespace $PAGE_NAMESPACE" "  --namespace $PAGE_NAMESPACE --create-namespace \\" "$install"
if grep -q -- '--version' <<<"$install"; then bad "the install pins a version: the page installs the latest release"
else ok "the install pins no version"; fi

echo
echo "=== The steps are the shape the run relies on"
create="$(sh_block "## 1. |1")"
# The port on the loopback address: the site is served over plain HTTP, with
# a generated admin password, and is not for the network the machine is on.
if grep -qxE 'k3d cluster create [a-z0-9-]+ --image rancher/k3s:v[0-9]+\.[0-9]+\.[0-9]+-k3s[0-9]+ -p "127\.0\.0\.1:[0-9]+:80@loadbalancer"' <<<"$create"; then
  ok "step 1 creates one cluster, by name, k3s image and loopback port"
else bad "step 1 is not 'k3d cluster create NAME --image rancher/k3s:TAG -p \"127.0.0.1:PORT:80@loadbalancer\"': $create"; fi
cluster="$(sed -n 's/^k3d cluster create \([^ ]*\).*/\1/p' <<<"$create")"
port="$(sed -n 's/.* -p "127\.0\.0\.1:\([0-9][0-9]*\):80@loadbalancer".*/\1/p' <<<"$create")"
has "the clean-up deletes the cluster of step 1" "k3d cluster delete $cluster" "$(sh_block "## Clean up|1")"
# Every URL of the page is on the port step 1 maps.
urls="$(grep -oE 'http://localhost(:[0-9]+)?' "$PAGE" | sort -u)"
if [ "$urls" = "http://localhost:$port" ]; then ok "every URL of the page is http://localhost:$port"
else bad "the page's URLs are not all http://localhost:$port: $(tr '\n' ' ' <<<"$urls")"; fi
# A wait without a time limit would hold the run, and a reader, for ever.
waits="$(for b in "${PAGE_BLOCKS[@]}"; do sh_block "$b"; done | grep -E ' (rollout status|wait) ' || true)"
if [ -z "$waits" ]; then bad "the page waits for nothing"
elif grep -qv -- ' --timeout=' <<<"$waits"; then bad "a wait without --timeout: $(grep -v -- ' --timeout=' <<<"$waits")"
else ok "every wait has a time limit"; fi
# run.sh starts each block in a shell of its own, as a reader may after a
# break: a block must not rely on a variable an earlier one set.
before=$FAILURES
for b in "${PAGE_BLOCKS[@]}"; do
  code="$(sh_block "$b")"
  for var in $(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' <<<"$code" | tr -d '${' | sort -u); do
    grep -qE "^$var=" <<<"$code" || bad "block ${b#*|} under '${b%|*}' uses \$$var and does not set it"
  done
done
[ "$FAILURES" -ne "$before" ] || ok "no block relies on a variable of another"
# Names the page's commands and the values file must agree on.
user="$(sed -n 's/.*the user is `\([^`]*\)`.*/\1/p' "$PAGE")"
chart_user="$(sed -n 's/^wordpressUsername: *//p' "$TRY_ROOT/chart/values.yaml")"
if [ -n "$user" ] && [ "$user" = "$chart_user" ]; then ok "the page signs in as the chart's default user, $user"
else bad "the page signs in as '$user', the chart's wordpressUsername is '$chart_user'"; fi
if grep -q '^wordpressUsername:' "$VALUES"; then bad "examples/k3d/values.yaml sets wordpressUsername: the page names the chart's default"
else ok "the example values keep the default user"; fi
is "the example values set a blog name for the run to look for" grep -q '^wordpressBlogName: ' "$VALUES"
has "the example Ingress is for localhost" "  hostname: localhost" "$(cat "$VALUES")"

echo
echo "=== The example sets known keys and no secret, the page has no link that needs GitHub"
# Helm ignores a key it does not know. The template test checks the same;
# here a wrong key stops the workflow before it creates a cluster.
if unknown="$(python3 "$TRY_ROOT/chart/tests/check-example-keys.py" "$TRY_ROOT/chart/values.yaml" "$VALUES" 2>&1)" \
    && [ -z "$unknown" ]; then ok "examples/k3d/values.yaml sets only keys the chart knows"
else bad "examples/k3d/values.yaml sets keys the chart does not know: $(tr '\n' ' ' <<<"$unknown")"; fi
secrets="$(grep -v '^ *#' "$VALUES" | grep -iE 'password|secret|apikey|token' || true)"
if [ -z "$secrets" ]; then ok "examples/k3d/values.yaml sets no password, key or token"
else bad "examples/k3d/values.yaml sets: $secrets"; fi
# The documentation site includes the page: a relative link would point into
# the repository there. Links are absolute, or anchors of the page.
links="$(grep -oE '\]\([^)]*\)' "$PAGE" | grep -vE '^\]\((https://|#)' || true)"
if [ -z "$links" ]; then ok "every link is absolute or an anchor"
else bad "relative links: $(tr '\n' ' ' <<<"$links")"; fi
repo_links="$(grep -oE 'https://github\.com/ioanalytica/wordpress-nginx[^) ]*' "$PAGE" || true)"
if [ -z "$repo_links" ]; then ok "no link into the repository's GitHub pages"
else bad "links that only work on GitHub: $(tr '\n' ' ' <<<"$repo_links")"; fi
# The site's page is this page, by include and whole: what the site shows is
# what the run has tested.
site_page="$TRY_ROOT/site/guide/try-locally.md"
body="$(awk 'NR == 1 && $0 == "---" { front = 1; next } front && $0 == "---" { front = 0; next } !front && NF' "$site_page" 2>/dev/null || true)"
if [ "$body" = '<!--@include: ../../examples/k3d/README.md-->' ]; then ok "the site's page includes the page, and nothing else"
else bad "site/guide/try-locally.md is not the include of the page alone: $body"; fi

echo
echo "=== The workflow runs when what the run reads changes"
pr_paths="$(awk '
  $0 == "  pull_request:" { ev = 1; next }
  ev && /^  [^ ]/ { exit }
  ev && $1 == "paths:" { on = 1; next }
  on && $1 == "-" { p = $2; gsub(/\047/, "", p); print p; next }
  on { on = 0 }' "$WF")"
for want in 'chart/**' 'docker/**' 'wordpress-idx' 'examples/k3d/**' 'site/guide/try-locally.md' 'tests/try-locally/**' \
            '.github/workflows/try-locally.yml'; do
  has "pull requests run on $want" "$want" "$pr_paths"
done
has "a weekly run" "  schedule:" "$(cat "$WF")"
# inputs EVENT - the inputs of one trigger, "name type required default" per
# line (a dash for what is not set).
inputs() {
  awk -v ev="  $1:" '
    $0 == ev { on = 1; next }
    on && /^  [^ ]/ { exit }
    on && /^      [a-z][a-z-]*:$/ { if (n) print n, t, r, d; n = $1; sub(/:$/, "", n); t = "-"; r = "-"; d = "-"; next }
    on && n && $1 == "type:" { t = $2 }
    on && n && $1 == "required:" { r = $2 }
    on && n && $1 == "default:" { d = $2 }
    END { if (n) print n, t, r, d }' "$WF"
}
has "by hand: the release or the checkout" "chart choice - release" "$(inputs workflow_dispatch)"
has "by hand: a published version" "chart-version string - -" "$(inputs workflow_dispatch)"
[ "$(inputs workflow_call)" = "chart-version string true -" ] \
  && ok "called: the version to install, nothing else" || bad "the called run's inputs: $(inputs workflow_call)"

echo
echo "=== The workflow is pinned, limited and wired to the runner"
uses="$(grep -E '^ *(- )?uses:' "$WF" || true)"
unpinned="$(grep -vE 'uses: [A-Za-z0-9._/-]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$uses" || true)"
if [ -n "$uses" ] && [ -z "$unpinned" ]; then ok "every action is pinned by commit, with its version as a comment"
else bad "actions not pinned by commit and version comment: $unpinned"; fi
perms="$(awk '/^permissions:/ { on = 1; next } on && /^  [a-z-]+:/ { print $1 $2; next } on && !/^ *#/ { exit }' "$WF")"
[ "$perms" = "contents:read" ] && ok "the workflow asks for contents: read and nothing more" || bad "the workflow's permissions: $perms"
if grep -q '^    permissions:' "$WF"; then bad "a job sets permissions of its own"; else ok "no job widens the permissions"; fi
jobs="$(grep -cE '^  [a-z][a-z0-9-]*:$' <(sed -n '/^jobs:/,$p' "$WF") || true)"
limits="$(grep -cE '^    timeout-minutes: [0-9]+$' "$WF" || true)"
[ "$jobs" -gt 0 ] && [ "$jobs" -eq "$limits" ] && ok "every job has a time limit" || bad "$jobs job(s), $limits time limit(s)"
runners="$(sed -n 's/^    runs-on: *//p' "$WF")"
if [ -n "$runners" ] && ! grep -qvE '^ubuntu-[0-9]+\.[0-9]+$' <<<"$runners"; then ok "the runner image is pinned: $(tr '\n' ' ' <<<"$runners")"
else bad "runs-on is not a pinned image: $runners"; fi
if grep -q '^concurrency:' "$WF"; then bad "concurrency at the workflow level: a called run could cancel its caller's jobs"
else ok "no concurrency at the workflow level"; fi
wf="$(cat "$WF")"
has "a pull request's newer push replaces its run, no other run is cancelled" \
    "      cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "$wf"
has "the checkout keeps no credentials" "          persist-credentials: false" "$wf"
has "the checkout has the submodule the sidecar's image is built from" "          submodules: true" "$wf"
has "the guard test runs before the cluster" "        run: tests/try-locally/test.sh" "$wf"
has "the chart step reads the version input" '          VERSION: ${{ inputs.chart-version }}' "$wf"
has "pull requests install the checkout's chart, the others the choice" \
    "          CHOICE: \${{ github.event_name == 'pull_request' && 'checkout' || inputs.chart }}" "$wf"
has "the chart step knows the event" '          EVENT: ${{ github.event_name }}' "$wf"
has "the image is built under the name the chart asks for" '          tags: ${{ steps.chart.outputs.image }}' "$wf"
has "the run gets the chart step's directory" '          CHART: ${{ steps.chart.outputs.dir }}' "$wf"
has "the run imports the image only when it was built" \
    "          IMAGE: \${{ steps.chart.outputs.build != '' && steps.chart.outputs.image || '' }}" "$wf"
has "the sidecar's image is built under the name the chart asks for" '          tags: ${{ steps.chart.outputs.idx_image }}' "$wf"
has "the sidecar's image is built from the submodule" "          context: ./wordpress-idx" "$wf"
has "the run imports the sidecar's image only when it was built" \
    "          IDX_IMAGE: \${{ steps.chart.outputs.idx_build != '' && steps.chart.outputs.idx_image || '' }}" "$wf"
has "the run is run.sh with the chart and both images" \
    '        run: tests/try-locally/run.sh ${IMAGE:+--import "$IMAGE"} ${IDX_IMAGE:+--import "$IDX_IMAGE"} ${CHART:+"$CHART"}' "$wf"
# Without pipefail in the step's shell, a pipe into tee would hide a
# failing chart.sh.
if grep -qE 'chart\.sh.*\|' "$WF"; then bad "chart.sh is piped: its failure would be lost"; else ok "chart.sh is not piped"; fi

echo
echo "=== The job runs the k3d and the k3s the page is tested with"
k3d="$(sed -n 's/^ *K3D_VERSION: \([0-9]*\.[0-9]*\)\..*/\1/p' "$WF")"
tested="$(sed -n 's/.*Tested with k3d \([0-9]*\.[0-9]*\) and$/\1/p' "$PAGE")"
tested_k3s="$(sed -n 's/^k3s \([0-9]*\.[0-9]*\)\.$/\1/p' "$PAGE")"
if [ -z "$tested" ] || [ -z "$tested_k3s" ]; then
  # The sentence may be wrapped differently: read it across the line break.
  both="$(tr '\n' ' ' <"$PAGE" | sed -n 's/.*Tested with k3d \([0-9]*\.[0-9]*\) and k3s \([0-9]*\.[0-9]*\)\..*/\1 \2/p')"
  tested="${both% *}"; tested_k3s="${both#* }"
fi
[ -n "$tested" ] && [ -n "$tested_k3s" ] && ok "the page says: tested with k3d $tested and k3s $tested_k3s" \
  || bad "the page says no \"Tested with k3d X.Y and k3s X.Y.\""
[ -n "$k3d" ] && [ "$k3d" = "$tested" ] && ok "the workflow installs k3d $k3d" \
  || bad "the workflow installs k3d '$k3d', the page is tested with '$tested'"
k3s="$(sed -n 's/.* --image rancher\/k3s:v\([0-9]*\.[0-9]*\)\..*/\1/p' <<<"$create")"
[ -n "$k3s" ] && [ "$k3s" = "$tested_k3s" ] && ok "step 1 runs k3s $k3s" \
  || bad "step 1 runs k3s '$k3s', the page is tested with '$tested_k3s'"

echo
echo "=== chart.sh: which chart, and where the image comes from"
# Stand-ins for helm, docker and git, steered by the environment: helm logs
# its arguments and lays out what `helm pull --untar` would; docker knows an
# image, does not know it, or cannot reach the registry, for the sidecar's
# image by a setting of its own; git fetches the release's tag or fails to,
# and says whether docker/ or the submodule differ from it.
mkdir -p "$TMP/bin" "$TMP/runner"
cat >"$TMP/bin/helm" <<'EOF'
#!/bin/sh
echo "$*" >>"$HELM_LOG"
dir=""
while [ $# -gt 0 ]; do [ "$1" = --untardir ] && dir="$2"; shift; done
[ -z "$dir" ] || mkdir -p "$dir/wordpress-nginx"
EOF
cat >"$TMP/bin/docker" <<'EOF'
#!/bin/sh
[ "$1 $2" = "manifest inspect" ] || { echo "unexpected: docker $*" >&2; exit 2; }
published="$STUB_PUBLISHED"
case "$3" in */wordpress-idx:*) published="${STUB_IDX_PUBLISHED:-$STUB_PUBLISHED}" ;; esac
case "$published" in
  yes) echo '{}' ;;
  no) echo "manifest unknown" >&2; exit 1 ;;
  *) echo "Get https://ghcr.io/v2/: dial tcp: connection refused" >&2; exit 1 ;;
esac
EOF
cat >"$TMP/bin/git" <<'EOF'
#!/bin/sh
case "$3" in
  rev-parse)   # the tag is not in the checkout, which is a shallow one
    case "$4" in --is-shallow-repository) echo true ;; *) exit 1 ;; esac ;;
  fetch) shift 2; echo "$*" >>"$GIT_LOG"; [ "$STUB_TAG" = yes ] ;;
  diff)
    for last; do :; done
    case "$last" in
      wordpress-idx) [ "${STUB_IDX_CHANGED:-no}" != yes ] ;;
      *) [ "$STUB_DOCKER_CHANGED" != yes ] ;;
    esac ;;
  *) echo "unexpected: git $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TMP"/bin/*
version="$(sed -n 's/^version: *//p' "$TRY_ROOT/chart/Chart.yaml" | tr -d '"')"
image="ghcr.io/ioanalytica/wordpress-nginx:$version"
idx_image="ghcr.io/ioanalytica/wordpress-idx:$version"
# chart_sh VERSION CHOICE EVENT TAG DOCKER_CHANGED PUBLISHED - the outputs in $out.
chart_sh() {
  : >"$TMP/helm.log"
  : >"$TMP/git.log"
  out="$(PATH="$TMP/bin:$PATH" HELM_LOG="$TMP/helm.log" GIT_LOG="$TMP/git.log" RUNNER_TEMP="$TMP/runner" \
         VERSION="$1" CHOICE="$2" EVENT="$3" STUB_TAG="$4" STUB_DOCKER_CHANGED="$5" STUB_PUBLISHED="$6" \
         "$HERE/chart.sh" 2>"$TMP/chart.err")" || { bad "chart.sh failed: $(cat "$TMP/chart.err")"; out=""; }
}
# get NAME - one output of the last chart_sh call.
get() { sed -n "s/^$1=//p" <<<"$out"; }

chart_sh 7.1.408 release workflow_dispatch no no no
[ "$(get dir)" = "$TMP/runner/chart/wordpress-nginx" ] && [ -z "$(get image)$(get build)$(get idx_image)$(get idx_build)" ] \
  && ok "a version: the pulled chart, with the images it names" || bad "a version gives: $out"
has "a version is pulled from the page's registry" \
    "pull $PAGE_CHART --version 7.1.408 --untar --untardir $TMP/runner/chart" "$(cat "$TMP/helm.log")"
chart_sh 7.1.408 checkout workflow_dispatch no no no
[ "$(get dir)" = "$TMP/runner/chart/wordpress-nginx" ] && ok "a version wins over the choice" || bad "a version with the checkout gives: $out"

chart_sh "" checkout pull_request yes no yes
[ "$(get dir)" = "$TRY_ROOT/chart" ] && [ "$(get image)" = "$image" ] && [ -z "$(get build)" ] \
  && ok "docker/ as the release has it, image published: the registry's image" || bad "gives: $out"
[ "$(get idx_image)" = "$idx_image" ] && [ -z "$(get idx_build)" ] \
  && ok "the submodule as the release has it, sidecar image published: the registry's image" || bad "gives: $out"
has "the comparison is with the tag of the chart's version, fetched for it" \
    "fetch --quiet --depth 1 origin refs/tags/$version:refs/tags/$version" "$(cat "$TMP/git.log")"
has "the checkout's chart gets its dependencies" "dependency update $TRY_ROOT/chart" "$(cat "$TMP/helm.log")"
chart_sh "" checkout pull_request yes yes yes
[ "$(get image)" = "$image" ] && [ "$(get build)" = "docker/ has changed since the release $version" ] \
  && ok "docker/ changed since the release, in this pull request or before it: built from the checkout" || bad "gives: $out"
chart_sh "" checkout pull_request yes no no
[ "$(get build)" = "$image is not in the registry" ] && [ "$(get idx_build)" = "$idx_image is not in the registry" ] \
  && ok "a pull request whose images are not published: both built from the checkout" || bad "gives: $out"
# Each image is decided for itself.
STUB_IDX_PUBLISHED=no chart_sh "" checkout pull_request yes no yes
[ -z "$(get build)" ] && [ "$(get idx_build)" = "$idx_image is not in the registry" ] \
  && ok "only the sidecar's image unpublished: only that one is built" || bad "gives: $out"
STUB_IDX_CHANGED=yes chart_sh "" checkout pull_request yes no yes
[ -z "$(get build)" ] && [ "$(get idx_build)" = "wordpress-idx has changed since the release $version" ] \
  && ok "the submodule moved since the release: the sidecar's image is built from it" || bad "gives: $out"
# A registry that cannot be reached is neither: the step fails rather than
# test a rebuilt image in place of the published one.
if PATH="$TMP/bin:$PATH" HELM_LOG="$TMP/helm.log" RUNNER_TEMP="$TMP/runner" VERSION="" CHOICE=checkout \
   GIT_LOG="$TMP/git.log" EVENT=pull_request STUB_TAG=yes STUB_DOCKER_CHANGED=no STUB_PUBLISHED=down "$HERE/chart.sh" >/dev/null 2>&1; then
  bad "a registry that cannot be reached reads as an image to build"
else ok "a registry that cannot be reached fails the step"; fi
# So is a release whose tag cannot be fetched: there is nothing to compare
# the published image's source with.
if PATH="$TMP/bin:$PATH" HELM_LOG="$TMP/helm.log" RUNNER_TEMP="$TMP/runner" VERSION="" CHOICE=checkout \
   GIT_LOG="$TMP/git.log" EVENT=pull_request STUB_TAG=no STUB_DOCKER_CHANGED=no STUB_PUBLISHED=yes "$HERE/chart.sh" >/dev/null 2>&1; then
  bad "a release tag that cannot be fetched reads as an unchanged image"
else ok "a release tag that cannot be fetched fails the step"; fi
# An image that is not published needs no tag: there is none yet.
chart_sh "" checkout pull_request no no no
[ "$(get build)" = "$image is not in the registry" ] && [ ! -s "$TMP/git.log" ] \
  && ok "an unpublished image is built without asking for a tag" || bad "gives: $out, git: $(cat "$TMP/git.log")"
chart_sh "" checkout workflow_dispatch no no yes
[ -n "$(get build)" ] && [ -n "$(get idx_build)" ] && ok "the checkout by hand: built from the checkout" || bad "gives: $out"

for choice in release ""; do
  chart_sh "" "$choice" schedule no no no
  [ -z "$(get dir)$(get image)$(get build)$(get idx_image)$(get idx_build)" ] && [ ! -s "$TMP/helm.log" ] \
    && ok "choice '$choice': the latest release, nothing pulled or built" || bad "choice '$choice' gives: $out"
done

echo
echo "=== run.sh refuses what it cannot run, before it needs a cluster"
# rc WANT DESC ARG... - run.sh with ARG... must exit with WANT.
rc() {
  local want="$1" desc="$2" got=0; shift 2
  "$HERE/run.sh" "$@" >/dev/null 2>&1 || got=$?
  [ "$got" -eq "$want" ] && ok "$desc" || bad "$desc - exit $got, expected $want"
}
rc 2 "--import without a chart directory" --import some/image:1
rc 2 "--import without an image" --import
rc 2 "an unknown option" --published "$TRY_ROOT/chart"
rc 2 "a directory that is no chart" "$EXAMPLES"
rc 2 "two chart directories" "$TRY_ROOT/chart" "$TRY_ROOT/chart"

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "=== $FAILURES check(s) FAILED"
  exit 1
fi
echo "=== All checks passed"
