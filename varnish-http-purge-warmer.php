<?php
/**
Plugin Name: Varnish HTTP Purge Warmer
Plugin URI: https://michaelshadle.com/projects/varnish-http-purge-warmer/
Description: Piggybacks on the Varnish HTTP Purge plugin to warm the Varnish cache for the selected pages after purge.
Author: Michael Shadle <mike503@gmail.com>
Author URI: https://michaelshadle.com
Version: 1.0
License: BSD
Text Domain: varnish-http-purge-warmer
*/

function varnish_http_purge_warmer($url = '') {
  // Fire a request off with a timeout of 1 second.
  // This should be enough time to kickstart the regeneration for most things.
  $response = wp_remote_request($url, array('timeout' => 1));
}

add_action('after_purge_url', 'varnish_http_purge_warmer');
