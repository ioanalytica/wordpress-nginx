################################################################################
#     These setups are part of the project: https://code.shin.company/php
#     Please respect the intellectual effort that went into creating them.
#     If you use or copy these ideas, proper credit would be appreciated.
#      - Author:  Mai Nhut Tan <shin@shin.company>
#      - License: https://code.shin.company/php/blob/main/LICENSE
################################################################################

ARG PHP_VERSION="8.4"
ARG PHP_VARIANT=""
ARG DEBUG

################################################################################
# The base image, as a layer of this image's own.
#
# The base image creates a key pair under /etc/ssl/site when it is built, as
# a placeholder for its listeners on port 443. This image serves H		P only
# (see the guard near the end of this file), and it must not hold a private
# key in any of its layers. Deleting the pair in a RUN of a build that starts
# FROM the base image does not do that: the base image's layers stay part of
# the image, with the pair in them.
#
# So the build takes the base image's files instead of its layers: the stage
# "base" removes the pair, "flat-base" copies what is left into an empty
# image, and the rest of the build starts from there. That leaves the base
# image's configuration behind, which "flat-base" declares again.
FROM shinsenter/php:${PHP_VERSION}-fpm-nginx-alpine AS base

# The build fails if the pair is not where it was, or if another private key
# turns up under /etc: the base image changed, and this stage has to follow.
#
# Four variables of the base image change with every one of its builds: its
# build date and the URL, signature and checksum of the PHP release it was
# built from. "flat-base" cannot declare those, since a Dockerfile takes no
# value from a stage. They go into a file that the base image's environment
# file loads, as defaults in that file's own style, so its scripts and a
# login shell still have them; `docker inspect` and a plain `docker exec env`
# do not show them any more. The grep makes sure that each of the four got
# its line and that the environment file has the place the line goes to.
# SC2016: the single quotes keep ${NAME:=...} for the file.
# hadolint ignore=SC2016
RUN test -f /etc/ssl/site/server.key \
 && rm -r /etc/ssl/site \
 && ! grep -rlE -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' /etc \
 && for name in DOCKER_DATE PHP_ASC_URL PHP_SHA256 PHP_URL; do \
        eval "value=\${$name}" \
     && test -n "$value" \
     && printf 'export %s="${%s:="%s"}"\n' "$name" "$name" "$value" >>/usr/local/etc/base-image.env \
     || exit 1; \
    done \
 && test "$(grep -cE '^export (DOCKER_DATE|PHP_ASC_URL|PHP_SHA256|PHP_URL)="\$\{[A-Z0-9_]+:="[^"$`\\]+"\}"$' /usr/local/etc/base-image.env)" = 4 \
 && grep -qxF '# Other user-defined environment variables are from here' /usr/local/etc/.env \
 && printf '%s\n' '. /usr/local/etc/base-image.env' >>/usr/local/etc/.env

# What a RUN of the base image sees of its configuration: the environment
# (ENV), the working directory (WORKDIR, as PWD) and the user (USER). The
# four variables above are left out, and the two that differ from one RUN to
# the next. "flat-base" compares its own with this list.
FROM base AS base-config
RUN env >/tmp/env \
 && grep -vE '^(DOCKER_DATE|PHP_ASC_URL|PHP_SHA256|PHP_URL|HOSTNAME|_)=' /tmp/env >/tmp/config \
 && id -u >>/tmp/config \
 && sort -o /base-config /tmp/config

FROM scratch AS flat-base
# DL3067: the whole filesystem is the point of this stage.
# hadolint ignore=DL3067
COPY --from=base / /

# The base image's configuration, declared again. An image built FROM
# scratch has none, and COPY brings files only.
#
# Kept in step with the base image by the RUN below, which fails the build
# when the environment, the working directory or the user differ from the
# base image's, and prints the difference: change the lines here to match.
# What a RUN cannot see is checked by docker/tests/smoke-test.sh, which
# compares the built image's configuration with the base image's:
# ENTRYPOINT, CMD, STOPSIGNAL, VOLUME, HEALTHCHECK, SHELL and the labels.
#
# Meant to differ from the base image:
#   - EXPOSE names port 80 alone, the one port the image serves. The base
#     image also names 22, 443 (TCP and UDP) and 9000.
#   - The labels org.opencontainers.image.created and .revision are facts of
#     the base image's build, like the four variables above. A release sets
#     both for this image.
#   - The base image's ONBUILD instruction ran when the stage "base" began,
#     as it did when this build started FROM the base image. This file's
#     own ONBUILD is at its end.
ARG PHP_VERSION
ENV APP_GROUP="www-data" \
    APP_PATH="/var/www/html" \
    APP_USER="www-data" \
    COMPOSER_ALLOW_SUPERUSER="1" \
    COMPOSER_HOME="/.composer" \
    DOCKER_NAME="shinsenter/phpfpm-nginx" \
    DOCKER_TAG="shinsenter/phpfpm-nginx:php${PHP_VERSION}-alpine" \
    ENV="/usr/local/etc/.env" \
    GPG_KEYS="AFD8691FDAEDF03BDF6E460563F15A9B715376CA 9D7F99A0CB8F05C8A6958D6256A97AF7600A39A6 0616E93D95AF471243E26761770426E17EBBB3DD" \
    MAINTAINER="Mai Nhut Tan <shin@shin.company>" \
    NGINX_PID="/run/nginx.pid" \
    PATH="/usr/local/aliases:/usr/local/utils:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    PHPIZE_DEPS="autoconf 		dpkg-dev dpkg 		file 		g++ 		gcc 		libc-dev 		make 		pkgconf 		re2c" \
    PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64" \
    PHP_CPPFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64" \
    PHP_INI_DIR="/usr/local/etc/php" \
    PHP_LDFLAGS="-Wl,-O1 -pie" \
    PHP_VERSION="${PHP_VERSION}" \
    PRESQUASH_SCRIPTS="cleanup" \
    PS1="\\u@\\h:\\w\\\$ "
LABEL org.opencontainers.image.authors="Mai Nhut Tan <shin@shin.company>" \
      org.opencontainers.image.description="🌏 (PHP) PHP + Nginx Docker images for both production and development." \
      org.opencontainers.image.documentation="https://hub.docker.com/r/shinsenter/phpfpm-nginx" \
      org.opencontainers.image.licenses="GPL-3.0" \
      org.opencontainers.image.source="https://github.com/shinsenter/php" \
      org.opencontainers.image.title="shinsenter/phpfpm-nginx" \
      org.opencontainers.image.url="https://hub.docker.com/r/shinsenter/phpfpm-nginx/tags" \
      org.opencontainers.image.vendor="Docker Hub" \
      traefik.enable="true"
WORKDIR /var/www/html
EXPOSE 80
STOPSIGNAL SIGTERM
ENTRYPOINT ["docker-php-entrypoint"]

# The guard for the lines above. The entrypoint has to be the base image's
# file, with the set-user-ID bit the copy must have kept; the comparison
# covers ENV, WORKDIR and USER.
RUN --mount=type=bind,from=base-config,source=/base-config,target=/run/base-config \
    test -u /usr/local/bin/docker-php-entrypoint \
 && env >/tmp/env \
 && grep -vE '^(HOSTNAME|_)=' /tmp/env >/tmp/config \
 && id -u >>/tmp/config \
 && sort -o /tmp/config /tmp/config \
 && if ! diff /run/base-config /tmp/config; then \
        echo 'The configuration declared in "flat-base" differs from the base image (-) as shown above (+).' >&2; \
        exit 1; \
    fi \
 && rm /tmp/env /tmp/config

################################################################################
FROM flat-base

# community repo + upgrades for CVE freshness.
RUN sed -i 's/#\(.*\/community\)/\1/' /etc/apk/repositories
# The build cache keeps the upgrade layer as long as the base image is
# unchanged, which would ship an older build's package set. The release
# workflow passes the tag here, so every release upgrades afresh.
ARG APK_REFRESH
RUN apk update && apk upgrade --no-cache && rm -rf /var/cache/apk/*

ENV WP_VERSION=7.1.4

# Links the GHCR package to this repository.
LABEL org.opencontainers.image.source="https://github.com/ioanalytica/wordpress-nginx"

# Enable SBOM attestations
# See: https://docs.docker.com/build/attestations/sbom/
ARG BUILDKIT_SBOM_SCAN_CONTEXT=true
ARG BUILDKIT_SBOM_SCAN_STAGE=true

################################################################################
ARG BUILD_FROM_IMAGE="shinsenter/phpfpm-apache"
ARG BUILD_TAG_PREFIX=""

################################################################################
COPY ./rootfs/ /

################################################################################
# https://wordpress.org/documentation/category/installation/
ENV DOCUMENT_ROOT=""
ENV DISABLE_AUTORUN_GENERATING_INDEX=1
ENV APP_PATH=/var/www/html

# recommended PHP configuration limits
ENV PHP_MAX_EXECUTION_TIME="600"
ENV PHP_MAX_INPUT_TIME="400"
ENV PHP_MAX_INPUT_VARS="1000"
ENV PHP_MEMORY_LIMIT="256M"
ENV PHP_POST_MAX_SIZE="48M"
ENV PHP_UPLOAD_MAX_FILESIZE="32M"

################################################################################
# installs wp-cli
ARG WPCLI_URL=https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
ARG WPCLI_PATH=/usr/local/bin/wp-cli

# hadolint ignore=DL3059
RUN /root/setup-wp-cli.sh

# hadolint ignore=DL3059
RUN hook create-project
# phpaddmod reads PHP_URL, one of the base image's variables that this image
# keeps in a file (see the stage "base").
# SC1091: the file is in the image, not in the build context.
# hadolint ignore=SC1091
RUN . /usr/local/etc/base-image.env && phpaddmod imagick memcache && apk update && apk upgrade --no-cache && rm -Rf /tmp/*

################################################################################
# The base image defaults SMTP_HOST to "mailpit" (its dev mail-catcher, port
# 1025) in /usr/local/etc/.env. In production that default makes PHP mail()
# resolve a nonexistent host and fail silently on every wp_mail() call.
# Emptying the defaults makes the sendmail wrapper refuse loudly instead
# ("[mail error] SMTP_HOST is not defined") until a deployment sets SMTP_HOST;
# with the port empty, msmtp falls back to its native default (25).
# This must happen at build time: the .env uses ":=" expansion, which applies
# the default even when the variable is set but empty, so a runtime
# SMTP_HOST="" cannot disable it. The grep guards against the base image
# moving or renaming the lines, which would silently bring the default back.
RUN sed -i -e 's|:="mailpit"|:=""|' -e 's|:="1025"|:=""|' /usr/local/etc/.env \
 && ! grep -qE 'mailpit|SMTP_PORT.*1025' /usr/local/etc/.env

# The sendmail wrapper exposes msmtp's --tls switch as SMTP_TLS, which with
# msmtp's default tls_starttls=on means STARTTLS (port 587). Implicit-TLS
# submission (smtps, port 465) additionally needs --tls-starttls=off, which
# the wrapper has no variable for - so teach it SMTP_STARTTLS in the same
# style as its other options. It goes in right before the final exec line:
# that line has outlived rewrites of the option blocks above it (the
# SMTP_TLS one-liner became an if/elif block), and every option is set by
# then, so --tls-starttls lands after the wrapper's own --tls.
# The grep guards the insertion: if the base image rewrites the wrapper and
# the sed anchor no longer matches, the build fails here instead of silently
# shipping an image where smtpProtocol=ssl configures nothing.
# SC2016: the single quotes are the point - sed must see the literal $
# of the wrapper's own variables, not a build-time expansion.
# hadolint ignore=SC2016
RUN sed -i 's|^exec msmtp $options "$@"$|[ -n "$SMTP_STARTTLS" ] \&\& options="$options --tls-starttls=$SMTP_STARTTLS"\n&|' /usr/local/utils/sendmail \
 && grep -qF -- '--tls-starttls=$SMTP_STARTTLS' /usr/local/utils/sendmail \
 && bash -n /usr/local/utils/sendmail

# With SMTP_FROM set, the message's From *header* is rewritten to match it
# (plus SMTP_FROM_NAME as display name) on the way into msmtp - see
# rewrite-mail-from for why this is a transport concern and not WordPress'.
# Same guard pattern as above: if the base image reshapes the wrapper's
# final exec line, the build fails instead of silently dropping the rewrite.
# SC2016: single quotes intended, as above.
# hadolint ignore=SC2016
RUN sed -i 's|^exec msmtp $options "$@"$|[ -n "$SMTP_FROM" ] \&\& exec /usr/local/utils/rewrite-mail-from msmtp $options "$@"\nexec msmtp $options "$@"|' /usr/local/utils/sendmail \
 && grep -qF -- 'rewrite-mail-from msmtp' /usr/local/utils/sendmail \
 && bash -n /usr/local/utils/sendmail /usr/local/utils/rewrite-mail-from

# The image serves the site over HTTP on port 80 and nothing else: TLS ends
# at the Ingress. The base image's default site also listens on 443, for TLS
# (sites-enabled/00-default.conf) and for HTTP/3 (custom.d/00-ext-http3.conf,
# which announces it in an Alt-Svc header as well), with the key pair the
# stage "base" removed. Nothing uses those listeners, so they go. The TLS
# settings of the http block went the same way; they are left out of this
# image's nginx.conf.
# The base image's start hook finds no dhparam.pem then and says in the log
# that it disables ssl_dhparam, a directive this image no longer has.
# The greps guard the removal: if the base image moves a listener to another
# file, renames one of the files or adds a certificate elsewhere in the NGINX
# configuration, the build fails here instead of shipping an image that
# listens on 443 again or does not start for want of the key pair. The
# second one matches a listen directive on anything but port 80, in any file
# and commented out or not; the start hook comments the IPv6 ones in and out.
RUN sed -i -E \
        -e '/^[[:space:]]*listen[[:space:]]+(\[::\]:)?443[[:space:]]/d' \
        -e '/^[[:space:]]*ssl_certificate(_key)?[[:space:]]/d' \
        -e '/^[[:space:]]*# SSL$/d' \
        /etc/nginx/sites-enabled/00-default.conf \
 && rm /etc/nginx/custom.d/00-ext-http3.conf \
 && test ! -e /etc/ssl/site \
 && grep -qE '^[[:space:]]*listen[[:space:]]+80[[:space:]]' /etc/nginx/sites-enabled/00-default.conf \
 && ! grep -rnE '^[[:space:]]*#?[[:space:]]*listen[[:space:]]+(\[::\]:)?([^8[[:space:]]|8[^0]|80[^[:space:];])' /etc/nginx \
 && ! grep -rnE 'ssl_|[[:space:]]quic([[:space:];]|$)|http3|Alt-Svc|/etc/ssl/site' /etc/nginx \
 && ! grep -rlE -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' /etc/ssl /etc/nginx

################################################################################
ONBUILD RUN hook onbuild

################################################################################
