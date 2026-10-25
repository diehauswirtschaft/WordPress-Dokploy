<?php
/*
 * Plugin Name: Pause Newsletter signup (nordstern migration)
 * Description: Rejects Newsletter subscriptions on blog 6 while the site moves.
 *
 * Install on webhost as wp-content/mu-plugins/pause-newsletter-signup.php
 * before the final export, remove it on rollback. Subscriptions are POSTs
 * with na in the body, so this can't be done in the Apache vhost.
 */
$nordstern_na = $_REQUEST['na'] ?? '';
if (get_current_blog_id() === 6 && is_string($nordstern_na)
    && in_array($nordstern_na, ['s', 'subscribe', 'sa', 'ajaxsub'], true)) {
    http_response_code(503);
    header('Retry-After: 3600');
    header('Content-Type: text/plain; charset=utf-8');
    echo 'Die Newsletter-Anmeldung ist wegen eines Serverumzugs kurz pausiert. Bitte versuche es in einer Stunde noch einmal.';
    exit;
}
unset($nordstern_na);
