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

FROM shinsenter/php:${PHP_VERSION}-fpm-nginx-alpine

# community repo + upgrades for CVE freshness.
RUN sed -i 's/#\(.*\/community\)/\1/' /etc/apk/repositories
RUN apk update && apk upgrade --no-cache && rm -rf /var/cache/apk/*

ENV WP_VERSION=7.1

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
RUN phpaddmod imagick memcache && apk update && apk upgrade --no-cache && rm -Rf /tmp/*

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
# style as its other options, right after the SMTP_TLS line it extends.
# The grep guards the insertion: if the base image rewrites the wrapper and
# the sed anchor no longer matches, the build fails here instead of silently
# shipping an image where smtpProtocol=ssl configures nothing.
# SC2016: the single quotes are the point - sed must see the literal $
# of the wrapper's own variables, not a build-time expansion.
# hadolint ignore=SC2016
RUN sed -i 's|^\[ -n "$SMTP_TLS" \].*|&\n[ -n "$SMTP_STARTTLS" ] \&\& options="$options --tls-starttls=$SMTP_STARTTLS"|' /usr/local/utils/sendmail \
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

################################################################################
ONBUILD RUN hook onbuild

################################################################################
