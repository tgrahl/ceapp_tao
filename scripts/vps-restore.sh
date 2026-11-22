#!/usr/bin/env bash
# Restore a backup made by vps-backup.sh. REPLACES the current TAO database, config and data.
#   ./scripts/vps-restore.sh /var/backups/tao/20261124-023000
#
# Works on the same server or on a new one (run vps-setup.sh, vps-configure.sh and vps-deploy.sh
# there first). Afterwards the deploy settings from vps/.env (DB password, address) are re-applied.
# Add --yes to skip the confirmation question.
set -euo pipefail

source "$(dirname "$0")/vps-lib.sh"

SRC="${1:-}"
[ -n "$SRC" ] || die "Usage: $0 <backup-folder> [--yes]   (backups are in /var/backups/tao)"
SRC="$(cd "$SRC" && pwd)"
[ -f "${SRC}/db.sql.gz" ] && [ -f "${SRC}/files.tar.gz" ] || die "${SRC} doesn't contain db.sql.gz and files.tar.gz"

require_docker
load_env
docker image inspect tao-vps:latest >/dev/null 2>&1 || die "Image tao-vps:latest not found – run ./scripts/vps-deploy.sh first."

if [ -f "${SRC}/SHA256SUMS" ]; then
  info "Checking backup files"
  (cd "$SRC" && sha256sum -c --quiet SHA256SUMS) || die "Checksum mismatch – backup damaged"
fi
[ -f "${SRC}/backup-info.txt" ] && sed 's/^/    /' "${SRC}/backup-info.txt"

if [ "${2:-}" != "--yes" ]; then
  echo "This REPLACES the current TAO database, config and data on this server with the backup above."
  read -r -p "Type RESTORE to continue: " answer
  [ "$answer" = "RESTORE" ] || die "Cancelled."
fi

info "Starting MySQL, stopping TAO"
compose up -d db
wait_for_db
compose stop tao >/dev/null 2>&1 || true

info "Restoring TAO config + data"
docker run --rm \
  -v tao_config:/restore/config -v tao_data:/restore/data -v "${SRC}:/backup:ro" \
  --entrypoint sh tao-vps:latest -c \
  'find /restore/config /restore/data -mindepth 1 -delete \
   && tar xzf /backup/files.tar.gz -C /restore \
   && mkdir -p /restore/data/_sessions \
   && chown -R www-data:www-data /restore/config /restore/data'

info "Restoring the database"
printf "DROP DATABASE IF EXISTS tao;\nCREATE DATABASE tao CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\nGRANT ALL PRIVILEGES ON tao.* TO 'tao'@'%%';\n" | db_root_sql
gzip -dc "${SRC}/db.sql.gz" | db_root_sql

info "Re-applying settings from vps/.env (DB password, address, logging, guest access)"
printf "ALTER USER 'tao'@'%%' IDENTIFIED BY '%s';\n" "$DB_PASSWORD" | db_root_sql
compose run --rm install

info "Starting TAO and Caddy"
compose up -d tao caddy

info "Restore finished: ${TAO_URL}"
