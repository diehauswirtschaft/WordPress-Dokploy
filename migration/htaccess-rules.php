<?php
// OpenLiteSpeed does not report mod_rewrite to WordPress, so the core
// "WordPress" .htaccess block stays empty. Write the standard rules.
require_once ABSPATH . 'wp-admin/includes/misc.php';

$rules = array(
	'<IfModule mod_rewrite.c>',
	'RewriteEngine On',
	'RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]',
	'RewriteBase /',
	'RewriteRule ^index\.php$ - [L]',
	'RewriteCond %{REQUEST_FILENAME} !-f',
	'RewriteCond %{REQUEST_FILENAME} !-d',
	'RewriteRule . /index.php [L]',
	'</IfModule>',
);

if ( ! insert_with_markers( ABSPATH . '.htaccess', 'WordPress', $rules ) ) {
	WP_CLI::error( 'Could not write .htaccess' );
}
WP_CLI::success( 'WordPress rewrite rules written to .htaccess' );
