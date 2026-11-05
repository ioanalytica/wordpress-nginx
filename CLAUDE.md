# wordpress-nginx — project conventions

## Version scheme

A chart version is `x.y.P` with `P = z * 100 + N`: `x.y.z` is the WordPress
release the chart ships (`appVersion`) and `N` the build number on it, 0 to
99. `7.1.408` is build 8 on WordPress 7.1.4; the first version for WordPress
7.1.5 is `7.1.500`, then `7.1.501`. SemVer allows no leading zeros, so
WordPress 7.2.0 gives `7.2.0`, `7.2.1`, ... and WordPress 7.2.1 starts at
`7.2.100`.

- `scripts/chart-version.sh next <chart-version>` prints the next build,
  `scripts/chart-version.sh first <wordpress-version>` the first version for
  a new WordPress release.
- `appVersion` stays the plain WordPress version.
- No suffix, ever: `x.y.z-N` (the scheme up to `7.1.4-7`) is a SemVer
  pre-release, which Helm skips without `--devel` and Artifact Hub never
  shows as the latest version. The tags of that scheme stay as they are.
- The template test fails on a version outside the scheme: a suffix, a build
  past 99, a patch component that does not belong to `appVersion`.

## Version bump checklist (chart and image move in lockstep)

The chart version IS the image tag. A release that bumps one without the
others ships a chart that deploys the previous image (happened in 7.1.0-4
and 7.1.0-16; the template test now fails on it, CI stays red until all
spots agree).

Every bump touches **all** of these spots in `chart/Chart.yaml`:

1. `version:` — the chart version (e.g. `7.1.408`)
2. `annotations.imageTag:` — must equal `version`
3. `annotations.images:` — the `wordpress-nginx` entry's tag must equal `version`

When bumping the **wordpress-idx sidecar**, additionally:

4. `annotations.idxImageTag:`
5. `annotations.images:` — the `wordpress-idx` entry's tag (easy to forget:
   4 and 5 are two separate spots)

Then, always:

6. Add a `chart/CHANGELOG.md` entry for the new version (top of file).
7. Verify pinned image tags actually exist on GHCR before committing —
   a release tag existing does not mean the image was published:
   `docker manifest inspect ghcr.io/ioanalytica/wordpress-idx:<tag>`
8. Run `./chart/tests/template-test.sh` — it enforces the version agreement
   above and must be fully green.
9. For image (docker/) changes also run
   `docker build -t wordpress-nginx:test ./docker` and
   `./docker/tests/smoke-test.sh wordpress-nginx:test`.

## Release semantics

- Never move or re-publish an existing version tag: deployed HelmReleases
  do not see a moved tag. Any change, however small, gets the next build
  number.
- Fleet rollout is per site: the HelmReleases in the k3s-io repo pin chart
  versions individually. Never sweep-bump all site pins; raise only the
  site(s) the task at hand is about.

## Commit conventions

- Message style: `Version <chart-version>: <imperative summary>` for
  releases; plain imperative summaries otherwise.
- No attribution trailers (no `Co-Authored-By`, no generator footers).
- Never push without an explicit instruction in the current exchange.

## Security wording

- CHANGELOG entries and commit messages frame security fixes as hardening.
  Never describe how a vulnerability in a past release could be exploited.
