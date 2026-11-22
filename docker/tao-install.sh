#!/bin/sh
# TAO installation and post-install settings. Run by the Container Apps job "tao-install"
# (and the local `install` compose service).
#
# Idempotent:
#   * installs TAO only if config/generis.conf.php doesn't exist yet on the shared config volume;
#   * applies the guest-access setting on every run (TAO_GUEST_ACCESS=off|on, default off).
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
