<!-- What changes and why. Link the issue it fixes, if any. -->

## Tests

<!-- What you ran and what it showed, e.g. the last line of ./chart/tests/template-test.sh and of ./docker/tests/smoke-test.sh. -->

## Checklist

- [ ] A test covers the change
- [ ] New values are documented (`## @param` in `chart/values.yaml`, the section in `chart/README.md`)
- [ ] The region comments of the READMEs (`<!-- #region … -->`) are still around their sections
- [ ] The chart version is either unchanged or raised in every place, with its `chart/CHANGELOG.md` entry (see [CONTRIBUTING.md](https://github.com/ioanalytica/wordpress-nginx/blob/main/CONTRIBUTING.md#versions-and-releases))
- [ ] A security fix is worded as hardening, without describing how an earlier release could be attacked
