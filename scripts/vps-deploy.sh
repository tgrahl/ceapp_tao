#!/usr/bin/env bash
# Install or update TAO on this VPS. Run from the repo, as root (or a user in the docker group):
#   ./scripts/vps-deploy.sh
#
# First run: builds the image (~10–15 min), starts MySQL, installs TAO, starts TAO + Caddy.
# Later runs (after `git pull` or editing vps/.env): rebuilds, re-applies settings, restarts.
# Your data stays in the Docker volumes tao_db, tao_config, tao_data.
#
# Optional: SKIP_BUILD=yes (reuse the existing image), RESET_ADMIN_PASSWORD=yes (set the TAO admin
# password to TAO_ADMIN_PASSWORD from vps/.env).
set -euo pipefail

source "$(dirname "$0")/vps-lib.sh"

require_docker
load_env

if [ "${SKIP_BUILD:-no}" = "yes" ]; then
  docker image inspect tao-vps:latest >/dev/null 2>&1 || die "SKIP_BUILD=yes but there is no tao-vps:latest image yet."
  info "Reusing the existing image tao-vps:latest"
else
  info "Building the TAO image (TAO ${TAO_COMMUNITY_VERSION:-2026.11}, PHP ${PHP_VERSION:-8.3}); first build ~10–15 min"
  compose build tao
fi

info "Starting MySQL"
compose up -d db
wait_for_db

# vps/.env is the source of truth for the TAO database password: apply it to MySQL every time
# (the install step then updates TAO's stored copy to match).
info "Applying DB_PASSWORD to the MySQL user 'tao'"
printf "ALTER USER 'tao'@'%%' IDENTIFIED BY '%s';\n" "$DB_PASSWORD" | db_root_sql

info "Installing TAO if needed, then applying settings (DB password, address, logging, guest access)"
compose run --rm install

info "Starting TAO and Caddy"
compose up -d --remove-orphans tao caddy

info "Checking TAO answers inside the server"
ok=
for _ in $(seq 1 30); do
  if compose exec -T tao php -r 'exit(@file_get_contents("http://127.0.0.1:8080/healthz") === "ok\n" ? 0 : 1);' 2>/dev/null; then
    ok=1; break
  fi
  sleep 2
done
[ -n "$ok" ] || { compose logs --tail 50 tao >&2; die "TAO did not start. See the log above (or: docker compose -f vps/docker-compose.yml logs tao)."; }
STATUS="$(compose exec -T tao php -r '$h = @get_headers("http://127.0.0.1:8080/"); echo $h ? $h[0] : "no answer";' 2>/dev/null || true)"
echo "    TAO start page: ${STATUS}"

docker image prune -f >/dev/null 2>&1 || true

info "Done: ${TAO_URL}"
if [ "${TAO_SITE}" != ":80" ]; then
  echo "    HTTPS: Caddy requests a certificate for ${TAO_SITE} on first access. The domain's DNS"
  echo "    A record must point to this server, and ports 80/443 must be reachable."
  echo "    Check: docker compose -f vps/docker-compose.yml --env-file vps/.env logs caddy"
fi
