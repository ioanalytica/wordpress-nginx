<?php
define('WP_USE_THEMES', false);
require __DIR__ . '/wp-load.php';

// If we reach here, WP core and database are working
http_response_code(200);
header('Content-Type: text/plain');
echo 'ok';
