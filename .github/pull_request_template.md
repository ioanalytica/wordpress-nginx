<!-- What changes and why. Link the issue it fixes, if any. -->

## Tests

<!-- What you ran and what it showed, e.g. the last line of ./chart/tests/template-test.sh and of ./docker/tests/smoke-test.sh. -->

## Checklist

- [ ] A test covers the change
- [ ] New values are documented (`## @param` in `chart/values.yaml`, the section in `chart/README.md`) and have their entry in `chart/values.schema.json`
- [ ] The region comments of the READMEs (`<!-- #region … -->`) are still around their sections
- [ ] `chart/CHANGELOG.md` has an entry under `## Unreleased`, if the change touches the chart or the image
- [ ] The chart version is unchanged; a release pull request raises it (see [CONTRIBUTING.md](https://github.com/ioanalytica/wordpress-nginx/blob/main/CONTRIBUTING.md#versions-and-releases))
- [ ] A security fix is worded as hardening, without describing how an earlier release could be attacked
- [ ] Every commit is signed off (`git commit -s`, see [CONTRIBUTING.md](https://github.com/ioanalytica/wordpress-nginx/blob/main/CONTRIBUTING.md#sign-your-commits-dco))
