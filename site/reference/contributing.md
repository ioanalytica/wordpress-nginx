# Contributing

Issues and pull requests are welcome at
[github.com/ioanalytica/wordpress-nginx](https://github.com/ioanalytica/wordpress-nginx).
For a vulnerability, use the private channel described under
[Report a vulnerability](/security/reporting) instead of an issue.

## Tests

The repository's tests are shell scripts. Run the ones that cover what you
changed:

```bash
# the chart: renders it with many value sets and checks the manifests
helm dependency build ./chart
./chart/tests/template-test.sh

# the file-integrity watcher, against volume trees
./chart/tests/fim-test.sh

# the image: build it, then start it and probe it
docker build -t wordpress-nginx:test ./docker
./docker/tests/smoke-test.sh wordpress-nginx:test

# the .htaccess report of the init container
./docker/tests/htaccess-test.sh
```

Continuous integration runs them on every pull request that touches the chart
or the image.

## Versions and the changelog

A change to the chart or the image is released as a new chart version, with an
entry at the top of the [Changelog](/reference/changelog).
[Versioning](/reference/versioning) explains how the version is formed. An
existing version is never published a second time.

## This site

The site is built with [VitePress](https://vitepress.dev/) from `site/`. Most
pages show sections of `chart/README.md`, marked there with
`<!-- #region name -->` comments, so the text has one source: edit the README
and the page follows. To build the site locally:

```bash
cd site
npm ci --ignore-scripts
npm run dev      # or: npm run build
```
