# Main starting point: https://wordpress.org/support/topic/good-varnish-4-defaultvcl

vcl 4.0;

# Default backend definition. Set this to point to the nginx or Apache server.
backend default {
  .host = "127.0.0.1";
  .port = "8080";
  .connect_timeout = 600s;
  .first_byte_timeout = 600s;
  .between_bytes_timeout = 600s;
  .max_connections = 800;
}

# Only allow purging from specific IPs
acl purge {
  "localhost";
  "127.0.0.1";
}

# This function is used when a request is sent by a HTTP client (Browser)
sub vcl_recv {

  # Normalize the header, remove the port (in case you're testing this on various TCP ports)
  set req.http.Host = regsub(req.http.Host, ":[0-9]+", "");

  # https://support.cloudflare.com/hc/en-us/articles/200169376-Can-I-use-CloudFlare-and-Varnish-together-
  # Remove has_js and CloudFlare/Google Analytics __* cookies.
  set req.http.Cookie = regsuball(req.http.Cookie, "(^|;\s*)(_[_a-z]+|has_js)=[^;]*", "");
  # Remove a ";" prefix, if present.
  set req.http.Cookie = regsub(req.http.Cookie, "^;\s*", "");

  # https://www.varnish-cache.org/trac/wiki/VCLExampleHashAlwaysMiss
  # Downside of this method is that it will leave multiple copies of the same object in cache.
  if (req.http.X-Force-Refresh) {
    # Force a cache miss
    set req.hash_always_miss = true;
  }

  # Allow purging from ACL
  if (req.method == "PURGE") {
    # If not allowed then a error 405 is returned
    if (!client.ip ~ purge) {
      return(synth(405, "This IP is not allowed to send PURGE requests."));
    }

    # https://info.varnish-software.com/blog/step-step-speed-wordpress-varnish-software
    if (req.http.X-Purge-Method == "regex") {
      ban("req.url ~ " + req.url + " && req.http.host ~ " + req.http.host);
      return (synth(200, "Banned."));
    } else {
      return (purge);
    }
  }

  # Post requests will not be cached
  if (req.http.Authorization || req.method == "POST") {
    return (pass);
  }
  
  # WORDPRESS SPECIFIC
  # Do not cache the admin, login, post preview and cornerstone post editor pages
  if (req.url ~ "(wp-login|wp-admin|preview=true|cornerstone=1)") {
    return (pass);
  }

  # Remove the "has_js" cookie
  set req.http.Cookie = regsuball(req.http.Cookie, "has_js=[^;]+(; )?", "");

  # Remove any Google Analytics based cookies
  set req.http.Cookie = regsuball(req.http.Cookie, "__utm.=[^;]+(; )?", "");

  # Remove the Quant Capital cookies (added by some plugin, all __qca)
  set req.http.Cookie = regsuball(req.http.Cookie, "__qc.=[^;]+(; )?", "");

  # Remove the wp-settings-1 cookie
  set req.http.Cookie = regsuball(req.http.Cookie, "wp-settings-1=[^;]+(; )?", "");

  # Remove the wp-settings-time-1 cookie
  set req.http.Cookie = regsuball(req.http.Cookie, "wp-settings-time-1=[^;]+(; )?", "");

  # Remove the wp test cookie
  set req.http.Cookie = regsuball(req.http.Cookie, "wordpress_test_cookie=[^;]+(; )?", "");

  # Are there cookies left with only spaces or that are empty?
  if (req.http.cookie ~ "^ *$") {
    unset req.http.cookie;
  }

  # Cache the following file extensions
# TODO: add more extensions
  if (req.url ~ "\.(css|js|png|gif|jp(e)?g|swf|ico)") {
    unset req.http.cookie;
  }

  # Normalize Accept-Encoding header and compression
  if (req.http.Accept-Encoding) {
    # Do no compress compressed files...
# TODO: add more extensions
    if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|tbz|mp3|ogg|img|zip)$") {
      unset req.http.Accept-Encoding;
    } elsif (req.http.Accept-Encoding ~ "gzip") {
      set req.http.Accept-Encoding = "gzip";
    } elsif (req.http.Accept-Encoding ~ "deflate") {
      set req.http.Accept-Encoding = "deflate";
    } else {
      unset req.http.Accept-Encoding;
    }
  }

  # Check the cookies for wordpress-specific items
  if (req.http.Cookie ~ "wordpress_" || req.http.Cookie ~ "comment_") {
    return (pass);

  }
  if (!req.http.cookie) {
    unset req.http.cookie;
  }
  ## END WORDPRESS SPECIFIC

  # Do not cache under HTTP authentication
  if (req.http.Authorization) {
    # Not cacheable by default
    return (pass);
  }

  # Cache all others requests
  return (hash);
}

sub vcl_pipe {
  return (pipe);
}

sub vcl_pass {
  return (fetch);
}

# The data on which the hashing will take place
sub vcl_hash {
  hash_data(req.url);
  if (req.http.host) {
    hash_data(req.http.host);
  } else {
    hash_data(server.ip);
  }
  return (lookup);
}

# This function is used when a request is sent by our backend (Nginx server)
sub vcl_backend_response {
  # Remove some headers we never want to see
  unset beresp.http.Server;
  unset beresp.http.X-Powered-By;

  # For static content strip all backend cookies
# TODO: add more extensions
  if (bereq.url ~ "\.(css|js|png|gif|jp(e?)g)|swf|ico") {
    unset beresp.http.cookie;
  }

  # Only allow cookies to be set if we're in admin area
  if (!(bereq.url ~ "(wp-login|wp-admin|preview=true|cornerstone=1)")) {
    unset beresp.http.set-cookie;
  }

  # Do not cache the admin, login, post preview and cornerstone post editor pages
  if (bereq.url ~ "(wp-login|wp-admin|preview=true|cornerstone=1)") {
    set beresp.uncacheable = true;
    set beresp.ttl = 30s;
    return (deliver);
  }

  # don't cache response to posted requests or those with basic auth
  if (bereq.method == "POST" || bereq.http.Authorization) {
    set beresp.uncacheable = true;
    set beresp.ttl = 120s;
    return (deliver);
  }
        
  # don't cache search results
  if (bereq.url ~ "\?s=") {
    set beresp.uncacheable = true;
    set beresp.ttl = 120s;
    return (deliver);
  }

  # only cache status ok
  if (beresp.status != 200) {
    set beresp.uncacheable = true;
    set beresp.ttl = 120s;
    return (deliver);
  }

  # A TTL of 30m (helps clear out those X-Force-Refresh objects)
  set beresp.ttl = 30m;

  # Define the default grace period to serve cached content
  set beresp.grace = 30s;

  return (deliver);
}

# The routine when we deliver the HTTP request to the user
# Last chance to modify headers that are sent to the client
sub vcl_deliver {
  if (obj.hits > 0) {
    set resp.http.X-Cache = "cached";
  } else {
    set resp.http.X-Cache = "uncached";
  }

  # Remove some headers: PHP version
  unset resp.http.X-Powered-By;

  # Remove some headers: Apache version & OS
  unset resp.http.Server;

  # Remove some heanders: Varnish
  unset resp.http.Via;
  unset resp.http.X-Varnish;
# TODO: maybe hide more headers?

  return (deliver);
}

sub vcl_init {
  return (ok);
}

sub vcl_fini {
  return (ok);
}
