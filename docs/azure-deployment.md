# Deploying to Azure (Container Apps, scale to zero)

## What gets created

```
            HTTPS (managed cert, *.azurecontainerapps.io)
Internet ───────────────► Container App  tao-app   (0 … N replicas, HTTP-scaled)
                            nginx + php-fpm
                            ├─ Azure Files  tao-config → /var/www/html/config
                            ├─ Azure Files  tao-data   → /var/www/html/data   (+ PHP sessions)
                            └─ VNet (private) ──► MySQL Flexible Server 8.0 (B1ms, always on, private)

Container Apps Job  tao-install  (manual, runs once) ── same image, runs taoInstall.php
```

| Resource | Purpose |
|---|---|
| Container Registry (Basic) | Holds the TAO image. Built in Azure with `az acr build`, so no local Docker is needed. |
| Container Apps environment + app `tao-app` | Runs TAO with `minReplicas: 0`: no cost while idle, starts on the first request. |
| Container Apps job `tao-install` | One-time CLI install into the shared storage and database. |
| Storage account, file shares `tao-config` and `tao-data` | TAO writes its config and all content (items, tests, media, results) to disk. These must survive scale-to-zero and be shared between replicas. PHP sessions live here too, so users stay logged in. |
| MySQL Flexible Server (Burstable B1ms) | The database. Always on, reachable only inside the VNet. |
| VNet, private DNS zone, managed identity, Log Analytics | Private networking, registry pull without passwords, logs. |

Everything is defined in [`infra/main.bicep`](../infra/main.bicep).

## Prerequisites

1. An Azure subscription, and a role that can create resources **and role assignments** on it:
   Owner, or Contributor + User Access Administrator.
2. [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.60 or newer, logged in:
   ```bash
   az login
   ```
   ```bash
   az account set --subscription "<subscription name or id>"
   ```
3. Bash (Linux, macOS, WSL or Azure Cloud Shell). Azure Cloud Shell has everything preinstalled. Upload
   or clone this repository there.

## Step 1: Check the template

```bash
az bicep build -f infra/main.bicep --stdout > /dev/null && echo OK
```

## Step 2: Choose passwords

```bash
export MYSQL_ADMIN_PASSWORD='<8-128 chars, at least 3 of: upper, lower, digit, symbol>'
```

```bash
export TAO_ADMIN_PASSWORD='<password for the TAO admin user>'
```

## Step 3: Deploy

Known-good TAO 2022.11.6 on PHP 8.1:

```bash
./scripts/deploy.sh
```

Or, for a new installation, the current LTS (recommended):

```bash
PHP_VERSION=8.3 TAO_COMMUNITY_VERSION=2026.11 ./scripts/deploy.sh
```

Optional variables, set them in front of the command:

| Variable | Default | Meaning |
|---|---|---|
| `RG` | `rg-tao` | Resource group |
| `LOCATION` | `swedencentral` | Azure region. Some regions (e.g. West Europe) refuse new resources for some subscriptions with *"The selected region is currently not accepting new customers"*; pick another region then. |
| `PREFIX` | `tao` | Name prefix for all resources |
| `MAX_REPLICAS` | `3` | Upper limit for autoscaling |
| `TAO_EXTENSIONS` | `taoCe` (`taoCe,taoMediaManager` when a version is set) | Extensions to install |
| `IMAGE_TAG` | timestamp | Image tag in the registry. If that tag already exists, the build is skipped. |
| `MYSQL_SKU` | `Standard_B1ms` | Database size (see below) |
| `TAO_GUEST_ACCESS` | `off` | `on` shows the "Guest access" link on the login page, so anyone can take deliveries that allow guests. Applied on every deploy. |

The script takes about 20–30 minutes in total. It:
1. Registers the required resource providers, then creates the resource group and the registry.
2. Builds the image in the registry (~10–15 min).
3. Deploys the Bicep template (~10 min, mostly MySQL).
4. Runs the `tao-install` job and waits for it to finish.
5. Prints the TAO URL.

## Step 4: Log in

Open the printed URL (`https://tao-app.<random>.<region>.azurecontainerapps.io`), then log in with
`admin` and your `TAO_ADMIN_PASSWORD`. The first request can take 15–30 s while the first replica starts.

## How the autoscaling works

| Setting (`infra/main.bicep`) | Default | Effect |
|---|---|---|
| `minReplicas` | `0` | Nothing runs and nothing is billed while there's no traffic. |
| `cooldownSeconds` | `900` | Scales to 0 after 15 minutes without requests. |
| `concurrentRequestsPerReplica` | `30` | Adds a replica when one has more than 30 requests in flight. |
| `maxReplicas` | `3` | Upper limit. |
| `cpu` / `memory` | `1.0` / `2Gi` | Size of each replica. |

To change a setting, edit the parameter default in `infra/main.bicep` and re-run `deploy.sh`.

### Database size

The database runs all the time on **Burstable B1ms** (1 vCore, 2 GiB RAM, about 171 connections). Only the
app scales. At full scale the app runs at most `maxReplicas` × 16 PHP workers (3 × 16 = 48 at once).

* **Smaller (B1s, 1 GiB, ~half the price):** many regions refuse it with
  `OperationNotSupportedStandardB1s … Please choose other sku`. Where Azure allows it, set
  `MYSQL_SKU=Standard_B1s`. Its ~85 connections should fit the 48 workers above, but TAO hasn't been
  tested on 1 GiB.
* **Larger (B2s, 2 vCores, 4 GiB):** if pages get slow with the database CPU or memory near 100%
  (Azure portal → MySQL server → Monitoring), or with many candidates testing at the same time.

Resize in place (the server restarts, about a minute of downtime):

```bash
az mysql flexible-server update -g rg-tao -n <mysql-name> --sku-name Standard_B2s --tier Burstable
```

Re-run `deploy.sh` afterwards with the same `MYSQL_SKU`; otherwise it sets the default size again.

### Pre-warming

**Before a scheduled exam,** keep one replica warm so the first candidates don't hit a cold start:

```bash
az containerapp update -g rg-tao -n tao-app --min-replicas 1
```

Afterwards, allow it to scale to zero again:

```bash
az containerapp update -g rg-tao -n tao-app --min-replicas 0
```

## Updating

Re-run `deploy.sh` with the same variables. It builds a new image and rolls out a new revision. Data and
config stay in MySQL and on the file shares; the install job sees that TAO is already installed and does
nothing.

**Upgrading TAO to a newer version** also needs TAO's own migrations. After deploying the new image,
send any request so a replica is running, then:

```bash
az containerapp exec -g rg-tao -n tao-app --command "runuser -u www-data -- php tao/scripts/taoUpdate.php"
```

Going from 2022.11 to 2026.11 crosses four years of migrations and is untested here. Rehearse on a copy
first (restore the MySQL backup and both file shares into another resource group). Also install
`taoMediaManager` before running the update:

```bash
az containerapp exec -g rg-tao -n tao-app --command "runuser -u www-data -- php tao/scripts/installExtension.php taoMediaManager"
```

## Operations

Follow the logs:

```bash
az containerapp logs show -g rg-tao -n tao-app --follow
```

Open a shell (a replica must be running):

```bash
az containerapp exec -g rg-tao -n tao-app --command bash
```

List the install job's runs:

```bash
az containerapp job execution list -g rg-tao -n tao-install -o table
```

Show the logs of one run:

```bash
az containerapp job logs show -g rg-tao -n tao-install --execution <execution-name> --container install
```

The database is meant to run all the time. For long breaks (e.g. summer) you can still stop it by hand.
Azure starts it again automatically after 30 days:

```bash
az mysql flexible-server stop -g rg-tao -n <mysql-name>
```

```bash
az mysql flexible-server start -g rg-tao -n <mysql-name>
```

The MySQL server name is in the deployment output `mysqlHost` (the part before the first dot).

**Backups:** MySQL keeps automated backups for 7 days (point-in-time restore). The file shares have
7-day soft delete. For proper backups, enable Azure Backup for Azure Files. TAO content is split between
the database and the `tao-data` share, so always back up and restore both together.

**Custom domain:** add and bind it to the container app (`az containerapp hostname add` and
`az containerapp hostname bind`). Then change `ROOT_URL` in `config/generis.conf.php` on the `tao-config`
share to the new URL.

## Login page and guest access

* **Guest access is off by default.** The install job runs TAO's `ToggleGuestAccess` action on every
  deployment: it removes the "Guest access" link and revokes anonymous access to the guest page (which
  then redirects to the login page). To turn it on, re-run `deploy.sh` with `TAO_GUEST_ACCESS=on`.
* **Translation files are generated when the image is built.** TAO's installer writes
  `tao/views/locales/<lang>/messages.json` into the code folder. In Azure the install runs in a separate
  job container, so the web app never got those files, and the login page then shows no login form (only
  the guest link). The Dockerfile now generates them with TAO's
  `tao/scripts/tools/GenerateTranslationBundles.php`.

## Removing everything

This permanently deletes TAO, the database and all content:

```bash
az group delete -n rg-tao
```

## Design notes

* **MySQL TLS is not enforced.** TAO's installer can't pass TLS options to PHP's database driver. The
  server has public access disabled and is reachable only inside the VNet.
* **The web installer `/tao/install` is blocked** in nginx; installation only runs through the job.
* **Sessions are on Azure Files**, so logins survive scale-to-zero and work across replicas.
* **Azure Files is SMB.** It's fine for TAO's files, but not for database files (see
  [hosting-options.md](hosting-options.md)).
