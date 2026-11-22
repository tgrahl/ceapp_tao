#!/usr/bin/env bash
# One-time preparation of a fresh Ubuntu 22.04 / 24.04 VPS for TAO. Run as root, from the repo:
#   sudo ./scripts/vps-setup.sh
#
# Installs Docker + Compose, opens only SSH/80/443 in the firewall, enables automatic security
# updates, adds swap if there is none, and schedules a nightly backup. Safe to run again.
#
# Optional: SWAP_SIZE (2G), BACKUP_TIME ("30 2" = 02:30 server time, cron "minute hour")
set -euo pipefail

source "$(dirname "$0")/vps-lib.sh"

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0"

[ -r /etc/os-release ] || die "Cannot identify the OS (/etc/os-release missing). Use Ubuntu 24.04."
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || die "This script is for Ubuntu (24.04 recommended); this server runs ${PRETTY_NAME:-unknown}. Reinstall the VPS with Ubuntu 24."
case "${VERSION_ID:-}" in
  22.04|24.04) ;;
  *) echo "WARNING: written for Ubuntu 22.04/24.04; this is ${PRETTY_NAME}. Continuing." ;;
esac

info "Installing packages (Docker, Compose, firewall, automatic updates)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q docker.io docker-compose-v2 ufw unattended-upgrades git openssl curl gzip cron
systemctl enable --now docker cron
docker compose version

info "Automatic security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

info "Swap"
if swapon --show --noheadings | grep -q .; then
  echo "Swap already active:"; swapon --show
else
  SWAP_SIZE="${SWAP_SIZE:-2G}"
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "Created ${SWAP_SIZE} swap at /swapfile"
fi

info "Firewall: allow SSH, HTTP, HTTPS; block everything else inbound"
# Keep every port sshd currently listens on open, so a non-standard SSH port doesn't lock you out.
SSH_PORTS="$(ss -tlnpH 2>/dev/null | awk '/"sshd"/ {n=split($4,a,":"); print a[n]}' | sort -u)"
[ -n "$SSH_PORTS" ] || SSH_PORTS=22
for p in $SSH_PORTS; do ufw allow "${p}/tcp" >/dev/null; echo "  SSH port ${p}/tcp allowed"; done
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
ufw --force enable
ufw status
# Note: Docker publishes ports outside ufw; only Caddy publishes any (80/443), MySQL and TAO don't.

info "Nightly backup at ${BACKUP_TIME:-30 2} (minute hour) -> /var/backups/tao"
cat > /etc/cron.d/tao-backup <<EOF
# Created by scripts/vps-setup.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${BACKUP_TIME:-30 2} * * * root ${REPO_DIR}/scripts/vps-backup.sh >> /var/log/tao-backup.log 2>&1
EOF
chmod 644 /etc/cron.d/tao-backup

info "Done. Next: ./scripts/vps-configure.sh <domain-or-ip>, then ./scripts/vps-deploy.sh"
