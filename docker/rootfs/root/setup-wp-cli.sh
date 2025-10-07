#!/usr/bin/env sh
echo "Installing WP-CLI …"
[ -z "$DEBUG" ] || set -ex && set -e

env-default "alias wp-cli='$WPCLI_PATH --allow-root'"
env-default INITIAL_PROJECT     'manual'
env-default WP_CLI_DIR          '/.wp-cli'
env-default WP_CLI_CACHE_DIR    '$WP_CLI_DIR/cache/'
env-default WP_CLI_PACKAGES_DIR '$WP_CLI_DIR/packages/'
env-default WP_CLI_CONFIG_PATH  '$WP_CLI_DIR/config.yml'
env-default WP_DEBUG            '$(is-debug && echo 1 || echo 0)'
env-default WP_DEBUG_LOG        '$(log-path stdout)'
env-default WORDPRESS_DEBUG     '$(is-debug && echo 1 || echo 0)'

php -r "copy('$WPCLI_URL', '$WPCLI_PATH');" && chmod +xr "$WPCLI_PATH"
$WPCLI_PATH --allow-root --version

web-cmd wp "$WPCLI_PATH --allow-root"

# end
