# Migrating tests from an old TAO

Move tests (with their items and media) from an old TAO installation to the new one as **QTI packages**,
exported and imported **from the command line**. That avoids the browser's request time limit, and you
don't have to click through every test.

Tested path: **TAO 2022.11 (old) → command-line export → zip files → command-line import → TAO 2026.11
(new)**, with TAO's own sample tests: a 15-item test (seconds) and the 17-item "QTI Interactions" demo
test with media (about 3 minutes of one busy CPU core). All items arrived.

## What moves and what doesn't

| Moves with the QTI test package | Doesn't move, so redo or archive it |
|---|---|
| The test: sections, order, settings | **Results:** export them from the old Results section as CSV and keep them as an archive; TAO can't import results |
| All its items, with response processing (scoring) | **Test-takers and groups:** re-import (Test-takers → Import supports CSV) or recreate |
| Images/media used by the items, item stylesheets | **Deliveries:** create and publish again; their links (including LTI links) change |
| | **Folder structure:** each test's items land in a folder named after the test |

Check before migrating everything:
* **Custom interactions (PCIs)** only work if the same interaction exists in the new TAO.
* **Maths formulas** need MathJax, which the image doesn't include yet.
* **Very old TAO-specific item types** (from before QTI) can't be migrated.

Start with a pilot: migrate 2–3 typical tests, preview them in the new TAO, and compare scoring with the
old system before moving everything.

## 1. On the old server: list and export the tests

Paths below assume the manual install (`/var/www/html/tao`, database `tao`, user `tao`); adjust them to
your old server.

Copy [`scripts/migration/list-tests.sql`](../scripts/migration/list-tests.sql) to the old server, then
list all tests with their internal ID (URI):

```bash
mysql -u tao -p tao < list-tests.sql > tests.tsv && cat tests.tsv
```

Export all of them (the first line of `tests.tsv` is the header, hence `tail -n +2`):

```bash
cd /var/www/html/tao
```

```bash
tail -n +2 ~/tests.tsv | cut -f1 | xargs sudo -u www-data php index.php 'oat\taoQtiTest\scripts\cli\exportMultipleQtiTestsToDir'
```

For only some tests, pass their URIs instead:
`sudo -u www-data php index.php 'oat\taoQtiTest\scripts\cli\exportMultipleQtiTestsToDir' '<uri-1>' '<uri-2>'`.
Each export prints `Export successful for the test "…"`. The zip files are written to
`data/testExports/` in the TAO folder (`/var/www/html/tao/data/testExports/`).

If the command fails with `Class "…QtiTestExporter22" not found`, that TAO version's command-line
exporter is broken (it is in TAO 2026.11, for example). Export in the browser instead: Tests → select a
test → Export → QTI test package.

## 2. Copy the zips to the new server

Directly from the old server (or via your PC with two `scp` steps):

```bash
scp /var/www/html/tao/data/testExports/*.zip root@<new-vps-ip>:/root/exports/
```

## 3. On the new server: import

Take a backup first; if anything goes wrong, restore it and try again:

```bash
cd /opt/tao && ./scripts/vps-backup.sh
```

```bash
alias dc='docker compose -f /opt/tao/vps/docker-compose.yml --env-file /opt/tao/vps/.env'
```

```bash
dc exec tao mkdir -p /var/www/html/data/fileUploadDirectory/testImport /var/www/html/data/imported
```

```bash
dc cp /root/exports/. tao:/var/www/html/data/fileUploadDirectory/testImport/
```

```bash
dc exec tao chown -R www-data:www-data /var/www/html/data/fileUploadDirectory
```

```bash
dc exec -u www-data tao php index.php 'oat\taoQtiTest\scripts\cli\importMultipleTestsFromDir'
```

Each package prints `… imported.`, or `Error on package …` with the reason. A large package keeps one CPU
core at 100% for minutes; that's normal.

**Then move the zips out of the import folder.** The script imports everything in that folder every
time, so leaving them would create duplicates:

```bash
dc exec tao sh -c 'mv /var/www/html/data/fileUploadDirectory/testImport/*.zip /var/www/html/data/imported/'
```

## 4. Check in the new TAO

* Tests land in the top-level **Tests** folder; their items in a folder per test under **Items**.
* Delete any empty **"in progress"** test or item folder: the 2026.11 importer can leave one behind.
* Preview each test, and compare a few answers' scoring with the old system.
* Recreate deliveries, and import or recreate test-takers and groups.
* Keep the old system (read-only) until the first exams on the new one have gone well.
