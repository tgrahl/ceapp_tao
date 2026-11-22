# Shared helpers for the scripts/vps-*.sh scripts. Sourced, not run.
# shellcheck shell=bash

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPS_DIR="${REPO_DIR}/vps"
ENV_FILE="${VPS_DIR}/.env"
COMPOSE_FILE="${VPS_DIR}/docker-compose.yml"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

OVERRIDE_FILE="${VPS_DIR}/docker-compose.override.yml"

# Optional vps/docker-compose.override.yml (not in git) for server-specific tweaks,
# e.g. resource limits; included automatically when present.
compose() {
  if [ -f "$OVERRIDE_FILE" ]; then
    docker compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" --env-file "$ENV_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
  fi
}

load_env() {
  [ -f "$ENV_FILE" ] || die "${ENV_FILE} not found. Create it first: ./scripts/vps-configure.sh <domain-or-ip>"
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
  local var
  for var in DB_PASSWORD DB_ROOT_PASSWORD TAO_ADMIN_PASSWORD; do
    case "${!var:-}" in
      "") die "${var} is empty in ${ENV_FILE}" ;;
      *[!A-Za-z0-9._-]*) die "${var} may only contain letters, digits and . _ - (it is used in SQL and shell commands)" ;;
    esac
  done
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. Run ./scripts/vps-setup.sh first (as root)."
  docker compose version >/dev/null 2>&1 || die "The Docker Compose plugin is missing. Run ./scripts/vps-setup.sh first (as root)."
  docker info >/dev/null 2>&1 || die "Cannot talk to Docker. Run this as root (or a user in the docker group)."
}

# Wait until MySQL accepts root logins (up to ~5 minutes; the first start initialises the database).
wait_for_db() {
  local _
  for _ in $(seq 1 100); do
    if compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -h127.0.0.1 -e "SELECT 1" >/dev/null 2>&1'; then
      return 0
    fi
    sleep 3
  done
  compose logs --tail 30 db >&2 || true
  die "MySQL did not become ready. If DB_ROOT_PASSWORD in ${ENV_FILE} was changed after the first install, put the original value back."
}

# Run SQL as MySQL root inside the db container (statement on stdin).
db_root_sql() {
  compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -h127.0.0.1'
}
