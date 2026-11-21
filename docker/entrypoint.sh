#!/bin/sh
set -e
# Make sure the session directory exists on the (possibly fresh) data share.
mkdir -p /var/www/html/data/_sessions
chown www-data:www-data /var/www/html/data/_sessions 2>/dev/null || true
exec "$@"
