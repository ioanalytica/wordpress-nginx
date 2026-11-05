# Report a vulnerability

Report a vulnerability in the chart or the image privately through GitHub:
[**Report a vulnerability**](https://github.com/ioanalytica/wordpress-nginx/security/advisories/new)
(the Security tab of the repository). Please do not open a public issue or
pull request for a vulnerability that is not public yet.

A useful report names the chart version, the values it needs and what an
attacker gains.

## Scope

This covers what the repository builds: the Helm chart and the
`wordpress-nginx` image with its configuration and scripts.

- A vulnerability in **WordPress** itself belongs to the
  [WordPress project](https://wordpress.org/about/security/), one in a plugin
  or theme to its author.
- A vulnerability in the **search sidecar** belongs to
  [wordpress-idx](https://github.com/ioanalytica/wordpress-idx/security).
- Known vulnerabilities in the image's Alpine packages are found by a daily
  scan; [Update policy](/security/update-policy) says what that scan covers.
  An issue about one that is already public is fine.

## Fixes

A fix is released as a new chart version. The
[Changelog](/reference/changelog) lists the versions.
