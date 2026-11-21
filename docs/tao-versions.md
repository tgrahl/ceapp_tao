# TAO versions

## Where to find them

TAO is published on Packagist as the Composer package **`oat-sa/tao-community`**:

* Web: https://packagist.org/packages/oat-sa/tao-community
* With Composer:
  ```bash
  composer show oat-sa/tao-community --all
  ```
* Without Composer:
  ```bash
  curl -s https://repo.packagist.org/p2/oat-sa/tao-community.json | python3 -c "import json,sys; [print(v['version'], v['time'][:10]) for v in json.load(sys.stdin)['packages']['oat-sa/tao-community'][:20]]"
  ```

Don't go by the GitHub releases of `oat-sa/package-tao`: they are years out of date, and its
`composer.lock` still pins 2022.11.6.

Monthly releases (`2026.10`) get patch releases (`2026.10.1` …). TAO shows "LTS" in the page title for
long-term-support releases (e.g. "TAO 2026.11 LTS"); Packagist doesn't mark them. Always pin an exact
version: each release fixes the versions of all its extensions, so the build is reproducible.

## Choosing the version in this repo

| | `PHP_VERSION` | `TAO_COMMUNITY_VERSION` | `TAO_EXTENSIONS` | Result |
|---|---|---|---|---|
| Default (known-good) | `8.1` | *(empty)* | `taoCe` | package-tao `composer.lock` → TAO 2022.11.6 |
| Current LTS (recommended for new installs) | `8.3` | `2026.11` | `taoCe,taoMediaManager` | TAO 2026.11 LTS |

* **2022.11.6 requires PHP 8.1**: its lock file pins `laminas/laminas-code`, which needs PHP < 8.2.
  PHP 8.1 no longer receives security fixes.
* **2026.11 needs `taoMediaManager`**: `taoItems` registers a service that depends on
  `taoMediaManager/fileManager`, but `taoCe` doesn't install that extension. Without it the install fails
  with `… has a dependency on a non-existent service "taoMediaManager/fileManager"`. `deploy.sh` adds it
  automatically when `TAO_COMMUNITY_VERSION` is set.
* **Pick the version before the first install.** Changing it later is a TAO upgrade, not a rebuild
  (see [azure-deployment.md](azure-deployment.md#updating)).

Test any other version locally first (see [local-testing.md](local-testing.md)).

## Build details

* **npm:** the image fetches each extension's `views/node_modules` at build time; they are needed at
  runtime (e.g. `select2.js`). The composer npm plugin is switched off: in 2022.11,
  `tao/views/package-lock.json` doesn't match its `package.json` (it has a `git+ssh` GitHub entry), so
  `npm ci` fails without GitHub SSH keys. The build falls back to
  `npm install --legacy-peer-deps`, which uses the exact versions in `package.json`. In 2026.11 the lock
  files are clean and plain `npm ci` works. Node is removed from the final image.
* **MathJax** (maths formulas in items) is not bundled; TAO doesn't ship it for licensing reasons. To add
  it, run `taoQtiItem/scripts/installMathJax.sh` in the Dockerfile.
* **`mcrypt` and `soap`** are not installed: nothing in TAO's dependency tree requires them.

## What has been tested

| Check | 2022.11.6 / PHP 8.1 | 2026.11 / PHP 8.3 |
|---|---|---|
| Composer + npm steps | passes (with the npm fallback) | passes |
| `tao-install.sh` against MySQL 8.0 (passwords containing `$` and `!`) | 17 extensions installed | 18 extensions installed (with `taoMediaManager`) |
| Browser: login, all back-office sections, create an item, QTI item editor | no failed requests, no JS errors (except MathJax 404) | same |
| Taking a test as a test-taker | not tested | not tested |
| Upgrade 2022.11 → 2026.11 | not tested | not tested |
| Full `docker build`, Bicep compile, Azure deployment | not run yet | not run yet |
