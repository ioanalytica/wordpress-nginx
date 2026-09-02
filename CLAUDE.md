# wordpress-nginx — project conventions

## Version bump checklist (chart and image move in lockstep)

The chart version IS the image tag. A release that bumps one without the
others ships a chart that deploys the previous image (happened in 7.1.0-4
and 7.1.0-16; the template test now fails on it, CI stays red until all
spots agree).

Every bump touches **all** of these spots in `chart/Chart.yaml`:

1. `version:` — the chart version (e.g. `7.1.0-16`)
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
  do not see a moved tag. Any change, however small, gets a new `-N` bump.
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
