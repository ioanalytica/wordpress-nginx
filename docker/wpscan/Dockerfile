FROM alpine:3.24

# Links the GHCR package to this repository.
LABEL org.opencontainers.image.source="https://github.com/ioanalytica/wordpress-nginx"

# community repo + upgrades for CVE freshness.
RUN sed -i 's/#\(.*\/community\)/\1/' /etc/apk/repositories
RUN apk update && apk upgrade --no-cache && rm -rf /var/cache/apk/*

# Runtime dependencies. libcurl is loaded via FFI by wpscan's HTTP stack
# (typhoeus/ethon) and libstdc++ by its native extensions, so both must survive
# the removal of the build toolchain below. bash/curl/less are for interactive use.
# hadolint ignore=DL3018
RUN apk add --no-cache ruby libcurl libstdc++ ca-certificates bash curl less \
    && rm -rf /var/cache/apk/*

# The compiler is only needed to build wpscan's native gems; it is dropped again
# so the scanner image stays small and carries no build tooling.
# wpscan is deliberately unpinned: each build pulls the newest release so the
# bundled vulnerability data is current.
# hadolint ignore=DL3018,DL3028
RUN apk add --no-cache --virtual .build-deps build-base ruby-dev \
    && gem install --no-document wpscan \
    && gem cleanup \
    && apk del .build-deps \
    && rm -rf /var/cache/apk/* /root/.gem /usr/lib/ruby/gems/*/cache

CMD ["/bin/bash"]
