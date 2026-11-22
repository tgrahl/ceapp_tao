#!/usr/bin/env bash
# Back up TAO: database dump + TAO's config and data folders, into BACKUP_DIR/<timestamp>/.
# Runs nightly via /etc/cron.d/tao-backup (created by vps-setup.sh); can also be run by hand:
#   ./scripts/vps-backup.sh
#
# Settings in vps/.env: BACKUP_DIR (/var/backups/tao), BACKUP_KEEP_DAYS (14),
# BACKUP_RCLONE_REMOTE (optional off-server copy with rclone, e.g. "b2:my-bucket/tao").
# A backup that only lives on the same server doesn't survive losing the server: set up the
# off-server copy, or download the backups regularly.
set -euo pipefail

source "$(dirname "$0")/vps-lib.sh"

require_docker
load_env

BASE="${BACKUP_DIR:-/var/backups/tao}"
case "$BASE" in
  /|/bin*|/boot*|/dev*|/etc*|/lib*|/proc*|/sbin*|/sys*|/usr*) die "BACKUP_DIR='${BASE}' is not a sensible backup location" ;;
  /*) ;;
  *) die "BACKUP_DIR must be an absolute path (got '${BASE}')" ;;
esac
KEEP="${BACKUP_KEEP_DAYS:-14}"
[[ "$KEEP" =~ ^[0-9]+$ ]] || die "BACKUP_KEEP_DAYS must be a number"

[ -n "$(compose ps -q --status running db)" ] || die "The database container isn't running."
docker image inspect tao-vps:latest >/dev/null 2>&1 || die "Image tao-vps:latest not found (run vps-deploy.sh first)."

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${BASE}/${STAMP}"
mkdir -p "$DEST"
chmod 700 "$BASE" "$DEST"

info "Database dump -> ${DEST}/db.sql.gz"
compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -uroot -h127.0.0.1 --single-transaction --quick --routines --triggers --events --set-gtid-purged=OFF --databases tao' \
  | gzip > "${DEST}/db.sql.gz"
gzip -t "${DEST}/db.sql.gz"
[ "$(gzip -dc "${DEST}/db.sql.gz" | tail -n 1 | grep -c 'Dump completed')" -eq 1 ] || die "Database dump looks incomplete"

info "TAO config + data -> ${DEST}/files.tar.gz"
docker run --rm \
  -v tao_config:/src/config:ro -v tao_data:/src/data:ro -v "${DEST}:/dst" \
  --entrypoint tar tao-vps:latest \
  czf /dst/files.tar.gz -C /src --exclude=data/_sessions config data

{
  echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "tao_community_version=${TAO_COMMUNITY_VERSION:-}"
  echo "tao_url=${TAO_URL:-}"
} > "${DEST}/backup-info.txt"
(cd "$DEST" && sha256sum db.sql.gz files.tar.gz backup-info.txt > SHA256SUMS)
chmod 600 "${DEST}"/*

echo "    $(du -sh "$DEST" | cut -f1)  ${DEST}"

if [ -n "${BACKUP_RCLONE_REMOTE:-}" ]; then
  if command -v rclone >/dev/null 2>&1; then
    info "Off-server copy -> ${BACKUP_RCLONE_REMOTE}/${STAMP}"
    rclone copy "$DEST" "${BACKUP_RCLONE_REMOTE}/${STAMP}"
  else
    echo "WARNING: BACKUP_RCLONE_REMOTE is set but rclone isn't installed – no off-server copy made." >&2
  fi
fi

info "Removing local backups older than ${KEEP} days"
find "$BASE" -mindepth 1 -maxdepth 1 -type d -name '20[0-9][0-9][01][0-9][0-3][0-9]-*' -mtime +"$KEEP" -print -exec rm -rf {} +

info "Backup finished: ${DEST}"
