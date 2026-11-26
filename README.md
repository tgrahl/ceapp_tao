# TAO Assessment on Azure – scale to zero

Runs [TAO Community Edition](https://www.taotesting.com/) (open-source assessment platform) on
**Azure Container Apps**. The web tier scales to **zero replicas when idle** and starts on the next
request. The same container image runs locally with Docker Compose.

```
Internet ──HTTPS──► Container App tao-app (0…N replicas)  ──► Azure Files (TAO config + content)
                                                          └──► MySQL Flexible Server (private VNet)
```

## Quick start

**Local test** (Docker), see [docs/local-testing.md](docs/local-testing.md):

```bash
docker compose up -d --build
```

```bash
docker compose run --rm install
```

Then open http://localhost:8080 and log in with `admin` / `admin`.

**Azure** (Azure CLI, logged in), see [docs/azure-deployment.md](docs/azure-deployment.md):

```bash
export MYSQL_ADMIN_PASSWORD='...' TAO_ADMIN_PASSWORD='...'
```

```bash
PHP_VERSION=8.3 TAO_COMMUNITY_VERSION=2026.11 ./scripts/deploy.sh
```

Without the two version variables, the known-good TAO 2022.11.6 on PHP 8.1 is used.

**Single VPS** (Ubuntu 24.04, as root), see [docs/vps-deployment.md](docs/vps-deployment.md):

```bash
git clone https://github.com/tgrahl/ceapp_tao.git /opt/tao && cd /opt/tao
```

```bash
./scripts/vps-setup.sh && ./scripts/vps-configure.sh tao.yourschool.co.za && ./scripts/vps-deploy.sh
```

## Documentation

| Document | Contents |
|---|---|
| [docs/local-testing.md](docs/local-testing.md) | Run and test TAO on your machine; reset; troubleshooting |
| [docs/vps-deployment.md](docs/vps-deployment.md) | Single VPS (e.g. in South Africa): TAO + MySQL + automatic HTTPS, backups, restore |
| [docs/azure-deployment.md](docs/azure-deployment.md) | Step-by-step Azure deployment, autoscaling settings, updates, operations, backups |
| [docs/hosting-options.md](docs/hosting-options.md) | Costs; cheaper alternatives; database on the same machine |
| [docs/migrating-tests.md](docs/migrating-tests.md) | Move tests from an old TAO: command-line QTI export/import, what does and doesn't migrate |
| [docs/tao-versions.md](docs/tao-versions.md) | Where to find TAO versions, which to choose, what has been tested |

## Repository layout

```
docker/Dockerfile        PHP-FPM + nginx + supervisord; TAO installed via Composer (+ npm for front-end libs)
docker/nginx.conf        TAO rewrites, /healthz probe; blocks /tao/install, /data, /config, /vendor
docker/php.ini           PHP sessions on the data share, opcache, upload limits
docker/tao-install.sh    Idempotent CLI install (Container Apps job and local `install` service)
docker-compose.yml       Local stack: TAO + MySQL 8.0
infra/main.bicep         Azure: VNet, MySQL, Storage/Files, Container Apps environment, app, install job
scripts/deploy.sh        Azure: build in ACR, deploy Bicep, run the install job
scripts/vps-*.sh         VPS: setup, configure, deploy, backup, restore
vps/                     VPS: docker-compose.yml (TAO + MySQL 8.4 + Caddy), Caddyfile
```

## Status

The install and the back-office UI were tested for TAO 2022.11.6 (PHP 8.1) and 2026.11 (PHP 8.3) against
MySQL 8.0. **Not yet run end to end:** the full Docker image build, the Bicep compile and an actual Azure
deployment. Taking a test as a candidate hasn't been tested either. Details are in
[docs/tao-versions.md](docs/tao-versions.md#what-has-been-tested).

## License

The scripts and templates in this repository are yours to license. TAO itself is GPL-2.0
([oat-sa/package-tao](https://github.com/oat-sa/package-tao)). The image downloads TAO at build time;
it isn't stored in this repository.
