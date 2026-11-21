#!/bin/sh
# One-time TAO installation. Run by the Container Apps job "tao-install".
# Idempotent: exits successfully if TAO is already installed on the shared config volume.
set -eu

cd /var/www/html

if [ -f config/generis.conf.php ]; then
  echo "TAO is already installed (config/generis.conf.php exists) – nothing to do."
  exit 0
fi

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
