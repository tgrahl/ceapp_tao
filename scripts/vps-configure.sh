#!/usr/bin/env bash
# Create vps/.env for this server (never overwrites an existing one).
#
#   ./scripts/vps-configure.sh tao.example.co.za   # domain: HTTPS with automatic certificate
#   ./scripts/vps-configure.sh 203.0.113.10        # IP address: plain HTTP (no certificate for IPs)
#
# Passwords are generated randomly. Keep a copy of vps/.env somewhere safe (password manager):
# you need it to restore backups onto a new server.
set -euo pipefail

source "$(dirname "$0")/vps-lib.sh"

ADDRESS="${1:-}"
[ -n "$ADDRESS" ] || die "Usage: $0 <domain-or-ip>   e.g. $0 tao.example.co.za"
[ ! -e "$ENV_FILE" ] || die "${ENV_FILE} already exists – edit it instead (see docs/vps-deployment.md)."

case "$ADDRESS" in
  http://*|https://*|*/*|*" "*) die "Give only the host name or IP, e.g. tao.example.co.za" ;;
esac

if [[ "$ADDRESS" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  TAO_SITE=":80"
  TAO_URL="http://${ADDRESS}"
  echo "IP address given: TAO will use plain HTTP. Switch to a domain later for HTTPS."
else
  TAO_SITE="$ADDRESS"
  TAO_URL="https://${ADDRESS}"
fi

# Permanent ID for TAO's data (not a web address); must never change after the install.
NAMESPACE_ID="$(openssl rand -hex 6)"
TAO_NAMESPACE="http://tao-${NAMESPACE_ID}.local/tao.rdf"

pw() { openssl rand -hex 16; }

# InnoDB buffer pool: about a quarter of RAM, between 256M and 2G.
MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 4096)"
POOL_MB=$(( MEM_MB / 4 )); [ "$POOL_MB" -lt 256 ] && POOL_MB=256; [ "$POOL_MB" -gt 2048 ] && POOL_MB=2048

umask 077
cat > "$ENV_FILE" <<EOF
# TAO on this VPS – created by scripts/vps-configure.sh on $(date -u +%Y-%m-%d).
# Keep a copy in a password manager. After changes, run ./scripts/vps-deploy.sh.

# Where TAO is reached. TAO_SITE: a domain (automatic HTTPS) or ":80" (plain HTTP on the IP).
TAO_SITE=${TAO_SITE}
TAO_URL=${TAO_URL}

# Permanent data ID, set once. NEVER change after the first install.
TAO_NAMESPACE=${TAO_NAMESPACE}

# TAO version (see docs/tao-versions.md).
PHP_VERSION=8.3
TAO_COMMUNITY_VERSION=2026.11
TAO_EXTENSIONS=taoCe,taoMediaManager

# TAO admin login. The password is applied at the first install only; to set it again later,
# run: RESET_ADMIN_PASSWORD=yes ./scripts/vps-deploy.sh
TAO_ADMIN_USER=admin
TAO_ADMIN_PASSWORD=$(pw)

# Database. DB_PASSWORD may be changed (the deploy updates MySQL and TAO).
# DB_ROOT_PASSWORD must stay as it was at the first start of the database.
DB_PASSWORD=$(pw)
DB_ROOT_PASSWORD=$(pw)
MYSQL_BUFFER_POOL=${POOL_MB}M

# Options: guest access on the login page (on/off), log level (debug|info|notice|warning|error).
TAO_GUEST_ACCESS=off
TAO_LOG_LEVEL=warning

# Backups (scripts/vps-backup.sh). BACKUP_RCLONE_REMOTE: optional off-server copy, e.g. "b2:my-bucket/tao"
BACKUP_DIR=/var/backups/tao
BACKUP_KEEP_DAYS=14
BACKUP_RCLONE_REMOTE=
EOF

info "Created ${ENV_FILE}"
echo "    TAO address: ${TAO_URL}"
echo "    Admin login: admin / $(grep '^TAO_ADMIN_PASSWORD=' "$ENV_FILE" | cut -d= -f2)"
echo "Next: ./scripts/vps-deploy.sh"
