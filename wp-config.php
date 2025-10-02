<?php
/** Enable W3 Total Cache */
define('WP_CACHE', true); // Added by W3 Total Cache

/**
 * The base configuration for WordPress
 *
 * The wp-config.php creation script uses this file during the installation.
 * You don't have to use the website, you can copy this file to "wp-config.php"
 * and fill in the values.
 *
 * This file contains the following configurations:
 *
 * * Database settings
 * * Secret keys
 * * Database table prefix
 * * ABSPATH
 *
 * @link https://developer.wordpress.org/advanced-administration/wordpress/wp-config/
 *
 * @package WordPress
 */

// ** Database settings - You can get this info from your web host ** //
/** The name of the database for WordPress */
define( 'DB_NAME', 'styxnet' );

/** Database username */
define( 'DB_USER', 'styxnet' );

/** Database password */
define( 'DB_PASSWORD', '9bk@H@3WM3BH-KMGku4rgT43qDCmfdL4' );

/** Database hostname */
define( 'DB_HOST', 'weblog-db-primary.weblogs.svc:3306' );

/** Database charset to use in creating database tables. */
define( 'DB_CHARSET', 'utf8' );

/** The database collate type. Don't change this if in doubt. */
define( 'DB_COLLATE', '' );

/**#@+
 * Authentication unique keys and salts.
 *
 * Change these to different unique phrases! You can generate these using
 * the {@link https://api.wordpress.org/secret-key/1.1/salt/ WordPress.org secret-key service}.
 *
 * You can change these at any point in time to invalidate all existing cookies.
 * This will force all users to have to log in again.
 *
 * @since 2.6.0
 */
define( 'AUTH_KEY',         '_oLwt}>N+mL3AeS!%?`T0Fiz5uf./!vL50U}<*R|e.iOKWU!Y}BZN{PO*U (8Cs{' );
define( 'SECURE_AUTH_KEY',  't->?q4S:ASLZ^#On5R9{sI[eqr%=ih3AQaV0fZ%]=Y2KY4E^V64rUefRC*WC;jV-' );
define( 'LOGGED_IN_KEY',    'oPFc~8ON7Wz9`$^Ks!,b#=~Zdh$nAB3w/&S]Wa/6w$<j;{}B[n]^2EwMb!NWam,D' );
define( 'NONCE_KEY',        '+zR{I@L_BYqnIr.-,jnAZ,}_bWj,xoK>h/lkD#-n}~anFZd.,*!:_$:o2sT3Q1|4' );
define( 'AUTH_SALT',        'OK!g_0rTmDhZ|9M)DApIPY?8ZyW|kRn=GV|H|iPm%Nk~w%7e7j(=2ACs<g$!gAM4' );
define( 'SECURE_AUTH_SALT', 'Vw0_O<t?:yP=!RT6y-Oy,dgII8eHP5q*$j14_Qnj82@F``!(CSe$AGVeoq$K,@^X' );
define( 'LOGGED_IN_SALT',   '1<]aHXiaSoI.WiWt_KBlVmq]Gv4C.aL<0OUOc2BwNAhD#`+Y%Fg#ZVKlsv}ka@td' );
define( 'NONCE_SALT',       'c.hi7Jz3ADFpwn5-EwpKb,Vw#*B|9(NsPF+e=Sd6?%sriMw0#wOWOt{dO}A{PzKb' );

/**#@-*/

/**
 * WordPress database table prefix.
 *
 * You can have multiple installations in one database if you give each
 * a unique prefix. Only numbers, letters, and underscores please!
 *
 * At the installation time, database tables are created with the specified prefix.
 * Changing this value after WordPress is installed will make your site think
 * it has not been installed.
 *
 * @link https://developer.wordpress.org/advanced-administration/wordpress/wp-config/#table-prefix
 */
$table_prefix = 'wp_';

/**
 * For developers: WordPress debugging mode.
 *
 * Change this to true to enable the display of notices during development.
 * It is strongly recommended that plugin and theme developers use WP_DEBUG
 * in their development environments.
 *
 * For information on other constants that can be used for debugging,
 * visit the documentation.
 *
 * @link https://developer.wordpress.org/advanced-administration/debug/debug-wordpress/
 */
define( 'WP_DEBUG', false );

/* Add any custom values between this line and the "stop editing" line. */

define( 'FS_METHOD', 'direct' );
/**
 * Handle potential reverse proxy headers. Ref:
 *  - https://wordpress.org/support/article/faq-installation/#how-can-i-get-wordpress-working-when-im-behind-a-reverse-proxy
 *  - https://wordpress.org/support/article/administration-over-ssl/#using-a-reverse-proxy
 */
if ( ! empty( $_SERVER['HTTP_X_FORWARDED_HOST'] ) ) {
	$_SERVER['HTTP_HOST'] = $_SERVER['HTTP_X_FORWARDED_HOST'];
}
if ( ! empty( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && 'https' === $_SERVER['HTTP_X_FORWARDED_PROTO'] ) {
	$_SERVER['HTTPS'] = 'on';
}

/**
 * The WP_SITEURL and WP_HOME options are configured to access from any hostname or IP address.
 * If you want to access only from an specific domain, you can modify them. For example:
 *  define('WP_HOME','http://example.com');
 *  define('WP_SITEURL','http://example.com');
 *
 */
define( 'WP_HOME', 'https://' . $_SERVER['HTTP_HOST'] . '/' );
define( 'WP_SITEURL', 'https://' . $_SERVER['HTTP_HOST'] . '/' );
define( 'WP_AUTO_UPDATE_CORE', false );

/* That's all, stop editing! Happy publishing. */

/** Absolute path to the WordPress directory. */
if ( ! defined( 'ABSPATH' ) ) {
	define( 'ABSPATH', __DIR__ . '/' );
}

/** Sets up WordPress vars and included files. */
require_once ABSPATH . 'wp-settings.php';

/**
 * Disable pingback.ping xmlrpc method to prevent WordPress from participating in DDoS attacks
 * More info at: https://docs.bitnami.com/general/apps/wordpress/troubleshooting/xmlrpc-and-pingback/
 */
if ( !defined( 'WP_CLI' ) ) {
	// remove x-pingback HTTP header
	add_filter("wp_headers", function($headers) {
		unset($headers["X-Pingback"]);
		return $headers;
	});
	// disable pingbacks
	add_filter( "xmlrpc_methods", function( $methods ) {
		unset( $methods["pingback.ping"] );
		return $methods;
	});
}

