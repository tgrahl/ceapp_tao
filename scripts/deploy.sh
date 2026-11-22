#!/usr/bin/env bash
# Deploys TAO to Azure Container Apps (scale to zero) and runs the one-time install.
#
# Required:  MYSQL_ADMIN_PASSWORD, TAO_ADMIN_PASSWORD
# Optional:  RG (rg-tao), LOCATION (swedencentral), PREFIX (tao), ACR (derived),
#            IMAGE_TAG (timestamp), MAX_REPLICAS (3), MYSQL_SKU (Standard_B1ms)
#            PHP_VERSION (8.1) + TAO_COMMUNITY_VERSION (empty = package-tao composer.lock, TAO 2022.11.6)
#            e.g. PHP_VERSION=8.3 TAO_COMMUNITY_VERSION=2026.11 for the current LTS
#            TAO_EXTENSIONS (taoCe; taoCe,taoMediaManager when TAO_COMMUNITY_VERSION is set)
set -euo pipefail

cd "$(dirname "$0")/.."

: "${MYSQL_ADMIN_PASSWORD:?set MYSQL_ADMIN_PASSWORD (8-128 chars, 3 of: upper, lower, digit, symbol)}"
: "${TAO_ADMIN_PASSWORD:?set TAO_ADMIN_PASSWORD}"

RG="${RG:-rg-tao}"
LOCATION="${LOCATION:-swedencentral}"
PREFIX="${PREFIX:-tao}"
IMAGE_TAG="${IMAGE_TAG:-$(date -u +%Y%m%d%H%M%S)}"
PHP_VERSION="${PHP_VERSION:-8.1}"
TAO_COMMUNITY_VERSION="${TAO_COMMUNITY_VERSION:-}"
# Newer TAO releases wire taoItems to a taoMediaManager service, but taoCe doesn't install it.
if [ -n "$TAO_COMMUNITY_VERSION" ]; then DEFAULT_EXT="taoCe,taoMediaManager"; else DEFAULT_EXT="taoCe"; fi
TAO_EXTENSIONS="${TAO_EXTENSIONS:-$DEFAULT_EXT}"
MAX_REPLICAS="${MAX_REPLICAS:-3}"
MYSQL_SKU="${MYSQL_SKU:-Standard_B1ms}"

SUB_ID="$(az account show --query id -o tsv)"
ACR="${ACR:-${PREFIX}acr$(printf '%s' "${SUB_ID}/${RG}" | sha1sum | cut -c1-10)}"

echo "==> Subscription ${SUB_ID}, resource group ${RG} (${LOCATION}), registry ${ACR}"

for ns in Microsoft.App Microsoft.ContainerRegistry Microsoft.DBforMySQL \
          Microsoft.OperationalInsights Microsoft.Storage Microsoft.Network; do
  az provider register --namespace "$ns" --only-show-errors >/dev/null
done

az extension add --name containerapp --upgrade --only-show-errors

if RG_LOCATION="$(az group show -n "$RG" --query location -o tsv 2>/dev/null)"; then
  echo "==> Using existing resource group ${RG} (metadata in ${RG_LOCATION}); resources go to ${LOCATION}"
else
  az group create -n "$RG" -l "$LOCATION" -o none
fi

if ! az acr show -n "$ACR" -g "$RG" -o none 2>/dev/null; then
  echo "==> Creating container registry ${ACR}"
  az acr create -n "$ACR" -g "$RG" -l "$LOCATION" --sku Basic -o none
fi

if az acr repository show -n "$ACR" --image "tao:${IMAGE_TAG}" -o none 2>/dev/null; then
  echo "==> Image tao:${IMAGE_TAG} already exists in ${ACR} – skipping build"
else
  echo "==> Building image tao:${IMAGE_TAG} in ACR (takes ~10 min)"
  az acr build -r "$ACR" -t "tao:${IMAGE_TAG}" -t "tao:latest" \
    --build-arg "PHP_VERSION=${PHP_VERSION}" \
    --build-arg "TAO_COMMUNITY_VERSION=${TAO_COMMUNITY_VERSION}" docker/
fi
echo "==> Using image tao:${IMAGE_TAG}"

echo "==> Deploying infrastructure"
az deployment group create -g "$RG" -n tao -f infra/main.bicep -o none \
  -p prefix="$PREFIX" location="$LOCATION" acrName="$ACR" image="tao:${IMAGE_TAG}" maxReplicas="$MAX_REPLICAS" taoExtensions="$TAO_EXTENSIONS" mysqlSku="$MYSQL_SKU" \
     mysqlAdminPassword="$MYSQL_ADMIN_PASSWORD" taoAdminPassword="$TAO_ADMIN_PASSWORD"

out() { az deployment group show -g "$RG" -n tao --query "properties.outputs.$1.value" -o tsv; }
TAO_URL="$(out taoUrl)"
JOB="$(out installJobName)"

echo "==> Running install job ${JOB} (no-op if TAO is already installed)"
EXEC="$(az containerapp job start -g "$RG" -n "$JOB" --query name -o tsv)"
while :; do
  STATUS="$(az containerapp job execution show -g "$RG" -n "$JOB" \
            --job-execution-name "$EXEC" --query properties.status -o tsv)"
  case "$STATUS" in
    Succeeded) break ;;
    Failed|Stopped|Degraded)
      echo "Install job ${EXEC} ended with status ${STATUS}. Logs:" >&2
      echo "  az containerapp job logs show -g $RG -n $JOB --execution $EXEC --container install" >&2
      exit 1 ;;
    *) printf '.'; sleep 15 ;;
  esac
done
echo

echo "==> Done. TAO: ${TAO_URL}  (login: admin / \$TAO_ADMIN_PASSWORD)"
echo "    The app scales to 0 after the cooldown; the first request afterwards takes ~15-30 s."
