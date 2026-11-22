#!/bin/sh
# TAO installation and post-install settings. Run by the Container Apps job "tao-install"
# (and the local `install` compose service).
#
# Idempotent:
#   * installs TAO only if config/generis.conf.php doesn't exist yet on the shared config volume;
#   * on every run: syncs TAO's stored DB connection with TAO_DB_* (e.g. after a password change),
#     writes the log config (TAO_LOG_LEVEL) and applies guest access (TAO_GUEST_ACCESS=off|on);
#   * TAO_RESET_ADMIN_PASSWORD=yes sets the admin user's password to TAO_ADMIN_PASSWORD.
set -eu

cd /var/www/html

if [ -f config/generis.conf.php ]; then
  echo "TAO is already installed (config/generis.conf.php exists) – skipping install."
else
  : "${TAO_DB_HOST:?}" "${TAO_DB_NAME:?}" "${TAO_DB_USER:?}" "${TAO_DB_PASSWORD:?}"
  : "${TAO_URL:?}" "${TAO_ADMIN_USER:?}" "${TAO_ADMIN_PASSWORD:?}"

  mkdir -p data/_sessions
  chown -R www-data:www-data config data 2>/dev/null || true

  runuser -u www-data -- php tao/scripts/taoInstall.php \
    --db_driver "${TAO_DB_DRIVER:-pdo_mysql}" \
    --db_host "${TAO_DB_HOST}" \
    --db_name "${TAO_DB_NAME}" \
    --db_user "${TAO_DB_USER}" \
    --db_pass "${TAO_DB_PASSWORD}" \
    --module_namespace "${TAO_NAMESPACE:-${TAO_URL}/tao.rdf}" \
    --module_url "${TAO_URL}" \
    --module_lang "${TAO_LANG:-en-US}" \
    --module_mode "${TAO_MODE:-production}" \
    --timezone "${TAO_TIMEZONE:-UTC}" \
    --file_path /var/www/html/data/ \
    --user_login "${TAO_ADMIN_USER}" \
    --user_pass "${TAO_ADMIN_PASSWORD}" \
    -e "${TAO_EXTENSIONS:-taoCe}" -vv

  echo "TAO installation finished."
fi

# Database connection: the installer stores host/user/password once, but every deployment sets the
# MySQL admin password from MYSQL_ADMIN_PASSWORD. Bring TAO's copy in line, then test it.
runuser -u www-data -- php /usr/local/bin/tao-sync-db-config.php
runuser -u www-data -- php /usr/local/bin/tao-sync-db-config.php --check

# Web address (opt-in, used by the VPS setup): keep ROOT_URL in config/generis.conf.php equal to
# TAO_URL, so the address can change after install (e.g. from the IP to a domain). Only ROOT_URL
# changes; LOCAL_NAMESPACE (TAO_NAMESPACE) is a permanent ID inside the data and is never touched.
if [ "${TAO_SYNC_ROOT_URL:-no}" = "yes" ]; then
  : "${TAO_URL:?}"
  case "$TAO_URL" in
    http://*|https://*) ;;
    *) echo "TAO_URL must start with http:// or https:// (got '${TAO_URL}')" >&2; exit 1 ;;
  esac
  case "$TAO_URL" in
    *"'"*|*"#"*|*"\\"*|*" "*) echo "TAO_URL contains unsupported characters" >&2; exit 1 ;;
  esac
  NEW_ROOT="${TAO_URL%/}/"
  CUR_ROOT="$(sed -n "s/^define('ROOT_URL', *'\([^']*\)');.*/\1/p" config/generis.conf.php)"
  if [ -z "$CUR_ROOT" ]; then
    echo "Could not find ROOT_URL in config/generis.conf.php" >&2; exit 1
  elif [ "$CUR_ROOT" != "$NEW_ROOT" ]; then
    sed -i "s#^define('ROOT_URL', *'[^']*');#define('ROOT_URL','${NEW_ROOT}');#" config/generis.conf.php
    chown www-data:www-data config/generis.conf.php 2>/dev/null || true
    echo "Updated TAO web address: ${CUR_ROOT} -> ${NEW_ROOT}"
  else
    echo "TAO web address is ${NEW_ROOT}"
  fi
fi

if [ "${TAO_RESET_ADMIN_PASSWORD:-no}" = "yes" ]; then
  : "${TAO_ADMIN_PASSWORD:?}"
  runuser -u www-data -- php /usr/local/bin/tao-reset-admin-password.php
fi

# Logging: TAO's default config/generis/log.conf.php uses a null logger, so errors behind
# "Something unexpected happened" are logged nowhere. Send them to stderr instead; php-fpm
# forwards worker output to the container log (Azure: Container Apps console logs).
LEVEL="$(echo "${TAO_LOG_LEVEL:-warning}" | tr '[:upper:]' '[:lower:]')"
case "$LEVEL" in
  debug|info|notice|warning|error|critical) ;;
  *) echo "TAO_LOG_LEVEL must be debug, info, notice, warning, error or critical (got '${TAO_LOG_LEVEL}')" >&2; exit 1 ;;
esac
echo "Setting TAO log output: stderr, level ${LEVEL}"
cat > config/generis/log.conf.php <<EOF
<?php
// Managed by docker/tao-install.sh (rewritten on every deployment): TAO log messages go to
// the container output. Level from TAO_LOG_LEVEL (default: warning).
return new oat\oatbox\log\LoggerService([
    'logger' => [
        'class' => \oat\oatbox\log\logger\TaoMonolog::class,
        'options' => [
            'name' => 'tao',
            'handlers' => [
                [
                    'class' => \Monolog\Handler\StreamHandler::class,
                    'options' => ['php://stderr', '${LEVEL}'],
                ],
            ],
        ],
    ],
]);
EOF
chown www-data:www-data config/generis/log.conf.php 2>/dev/null || true

# Guest access: the "Guest access" link on the login page, which lets anyone take deliveries
# that allow guests. TAO's own action removes the login-page entry point and revokes the
# anonymous role's access to the guest controller (or restores both with "on").
GUEST="$(echo "${TAO_GUEST_ACCESS:-off}" | tr '[:upper:]' '[:lower:]')"
case "$GUEST" in
  on|off)
    echo "Setting guest access: ${GUEST}"
    runuser -u www-data -- php index.php 'oat\taoDeliveryRdf\scripts\ToggleGuestAccess' "$GUEST"
    ;;
  *)
    echo "TAO_GUEST_ACCESS must be 'on' or 'off' (got '${TAO_GUEST_ACCESS}')" >&2
    exit 1
    ;;
esac
