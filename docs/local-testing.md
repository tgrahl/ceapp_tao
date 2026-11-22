# Testing locally

Runs the **same image** that is deployed to Azure, with MySQL 8.0 in a second container.

## Prerequisites

* Docker Desktop (Windows/macOS) or Docker Engine + the Compose plugin (Linux).
* About 4 GB of free RAM and 5 GB of disk.
* Internet access during the build (Debian packages, Packagist, GitHub, npm).
* On Apple Silicon (M1/M2/…), builds work natively (arm64). The Azure build in ACR produces amd64.

## 1. Build and start

From the repository root:

```bash
docker compose up -d --build
```

The first build takes about 10–15 minutes (Composer downloads all TAO extensions). Later builds reuse
Docker's cache.

## 2. Install TAO (once)

```bash
docker compose run --rm install
```

This waits until MySQL is healthy, then runs `tao/scripts/taoInstall.php` (1–3 minutes). It ends with
`TAO installation finished.` Running it again is harmless: it exits immediately if TAO is already installed.

## 3. Open TAO

http://localhost:8080. Log in with `admin` / `admin`.

## Testing a newer TAO version

Set the version variables on **both** commands, starting from an empty stack (see *Reset* below):

```bash
PHP_VERSION=8.3 TAO_COMMUNITY_VERSION=2026.11 docker compose up -d --build
```

```bash
TAO_EXTENSIONS=taoCe,taoMediaManager docker compose run --rm install
```

See [tao-versions.md](tao-versions.md) for which versions exist and why `taoMediaManager` is needed.

## Useful commands

Follow the web container's logs (nginx + PHP errors):

```bash
docker compose logs -f tao
```

Open a shell in the web container:

```bash
docker compose exec tao bash
```

Stop everything but keep the data:

```bash
docker compose down
```

## Reset

This deletes the database, TAO config and all content in the local stack:

```bash
docker compose down -v
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Login page shows no login form (only a title, maybe a guest link) | `tao/views/locales/en-US/messages.json` is missing (404 in the browser's network tab). The image generates it during the build; rebuild with `docker compose build --no-cache tao`. |
| Browser redirects to `/tao/install` and gets 404 | TAO isn't installed yet. Run step 2. |
| `install` fails with `could not find driver` or a connection error | MySQL wasn't ready, or the `db` container crashed. Check `docker compose logs db`. |
| `install` fails with `non-existent service "taoMediaManager/fileManager"` | TAO ≥ 2026.x: add `TAO_EXTENSIONS=taoCe,taoMediaManager`, then reset and install again. |
| Port 8080 already in use | Change `"8080:8080"` in `docker-compose.yml` to e.g. `"8081:8080"` **and** `TAO_URL` to match, before installing. |
| You switched versions and things break | Config and DB belong to the old version. Run `docker compose down -v`, then install again. |
