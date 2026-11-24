# Deploying TAO on a single VPS

Everything on one Linux server: TAO (nginx + PHP 8.3), MySQL 8.4 on the server's own disk, and Caddy
in front for HTTPS with an automatic Let's Encrypt certificate. It uses the same TAO image and install
logic as the Azure deployment.

```
Internet ──80/443──► Caddy ──► TAO (nginx + php-fpm) ──► MySQL 8.4
                     (HTTPS)        │                       │
                                    └ volume tao_config     └ volume tao_db
                                      volume tao_data
```

Only Caddy is reachable from outside; TAO and MySQL listen only inside Docker's private network.

## What you need

* **A VPS with Ubuntu 24.04** (in the provider's OS list: "Ubuntu 24"). Ubuntu 22.04 also works. Other
  systems (AlmaLinux, CentOS, Rocky, Debian) aren't supported by the setup script.
* **Size:** 2 vCPU / 4 GB RAM for a pilot or up to ~30 people at once; **4 vCPU / 8 GB** for exams with a
  full class. These are estimates; run a load test with your real test before relying on a size.
  Disk: 40 GB or more (the image is a few GB, plus content, results and backups).
* **SSH access as root** (or a user with `sudo`).
* **Optional but recommended: a domain name**, e.g. `tao.yourschool.co.za`, with a DNS **A record**
  pointing to the VPS's IP address. Without a domain TAO runs on plain HTTP on the IP address (no
  certificate is possible for a bare IP); you can switch to a domain later.

## Install (about 20–30 minutes)

Log in to the VPS:

```bash
ssh root@<vps-ip>
```

**1. Get the repository** into `/opt/tao`:

```bash
apt-get update && apt-get install -y git
```

```bash
git clone https://github.com/tgrahl/ceapp_tao.git /opt/tao && cd /opt/tao
```

If the repository is private, GitHub asks for a username and a password: use your GitHub username and a
[personal access token](https://github.com/settings/tokens) (read-only access to this repository is
enough) as the password.

**2. Prepare the server** (Docker, firewall, automatic security updates, swap, nightly backup):

```bash
./scripts/vps-setup.sh
```

**3. Create the configuration** with your domain, or the VPS's IP address:

```bash
./scripts/vps-configure.sh tao.yourschool.co.za
```

This writes `vps/.env` with random passwords and prints the TAO admin password. **Save a copy of
`vps/.env` in your password manager**; you need it to restore backups onto another server.

```bash
cat vps/.env
```

**4. Install TAO:**

```bash
./scripts/vps-deploy.sh
```

The first run builds the TAO image (10–15 minutes), starts MySQL, installs TAO and starts everything.
It ends with `Done: https://…`. Open that address and log in as `admin` with the password from step 3.

With a domain, the first page load can take a few seconds while Caddy gets the certificate. If HTTPS
doesn't work, check that the DNS A record points to the VPS and look at Caddy's log (see below).

## Updates and changes

After pulling a new version of this repository, or after editing `vps/.env`:

```bash
cd /opt/tao && git pull && ./scripts/vps-deploy.sh
```

Data is kept; only the image and settings change. TAO is briefly unavailable while its container restarts.

| Change in `vps/.env` | Effect on the next `vps-deploy.sh` |
|---|---|
| `TAO_SITE` + `TAO_URL` (e.g. IP → domain) | Caddy serves the new address; TAO's stored web address is updated |
| `DB_PASSWORD` | MySQL and TAO both switch to the new password |
| `TAO_GUEST_ACCESS`, `TAO_LOG_LEVEL` | Applied |
| `TAO_ADMIN_PASSWORD` | Only applied with `RESET_ADMIN_PASSWORD=yes ./scripts/vps-deploy.sh` |
| `TAO_COMMUNITY_VERSION` / `PHP_VERSION` | New image; a TAO upgrade also needs TAO's own update step, so test first |
| `TAO_NAMESPACE`, `DB_ROOT_PASSWORD` | **Never change** after the first install |

Moving from the IP address to a domain:

1. Create the DNS A record for the domain, pointing to the VPS.
2. In `vps/.env`, set `TAO_SITE=tao.yourschool.co.za` and `TAO_URL=https://tao.yourschool.co.za`.
3. Run `./scripts/vps-deploy.sh`.

## Backups

`vps-setup.sh` schedules a backup every night at 02:30 (server time) into `/var/backups/tao/<date-time>/`:

* `db.sql.gz`: the full TAO database,
* `files.tar.gz`: TAO's config and data folders (items, tests, media, results),
* `SHA256SUMS`, `backup-info.txt`.

Local backups older than 14 days are deleted (`BACKUP_KEEP_DAYS` in `vps/.env`). Log:
`/var/log/tao-backup.log`.

Run a backup by hand, e.g. right before an exam:

```bash
./scripts/vps-backup.sh
```

**Keep a copy off the server.** A backup on the same VPS is lost together with the VPS. Options:

* Install [rclone](https://rclone.org/) (`apt-get install -y rclone`), set up a remote with `rclone config`
  (e.g. Backblaze B2, Google Drive, Azure Blob, another server via SFTP), and set
  `BACKUP_RCLONE_REMOTE=remote:folder` in `vps/.env`. Each backup is then copied there automatically.
* Or download the backups regularly, e.g. from your PC:
  ```bash
  scp -r root@<vps-ip>:/var/backups/tao ./tao-backups
  ```

## Restore

On the same server, or on a new one prepared with steps 1–4 above (use the old `vps/.env` there, or a new
one), run:

```bash
./scripts/vps-restore.sh /var/backups/tao/20261124-023000
```

It asks you to type `RESTORE`, then replaces TAO's database, config and data with the backup, re-applies
the settings from `vps/.env` (database password, web address) and restarts TAO. Log in with the admin
password that was valid when the backup was made.

Test a restore now and then (e.g. on a cheap second VPS), so you know it works before you need it.

## Day-to-day commands

Run these from `/opt/tao`. The shorter form needs `alias dc='docker compose -f vps/docker-compose.yml --env-file vps/.env'`.

Status of the containers:

```bash
docker compose -f vps/docker-compose.yml --env-file vps/.env ps
```

Live logs (TAO errors appear as `tao.ERROR`):

```bash
docker compose -f vps/docker-compose.yml --env-file vps/.env logs -f tao
```

HTTPS / certificate problems:

```bash
docker compose -f vps/docker-compose.yml --env-file vps/.env logs caddy
```

Restart everything (e.g. after a reboot, which happens automatically anyway):

```bash
docker compose -f vps/docker-compose.yml --env-file vps/.env restart
```

Disk space:

```bash
df -h / && docker system df
```

## Security notes

* The firewall (`ufw`) allows only SSH, HTTP and HTTPS. MySQL and TAO aren't published.
* Security updates install automatically. Some (e.g. kernel updates) need a reboot. Plan one now and
  then outside exam times (`reboot`); everything restarts on its own.
* Use SSH keys and disable SSH password logins (`PasswordAuthentication no` in `/etc/ssh/sshd_config`) once
  your key works.
* `vps/.env` contains all passwords (readable only by root). It's excluded from git.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `PHP Warning: Constant ROOT_URL already defined` during the first install | Harmless; comes from TAO's installer. |
| Browser can't reach the domain, Caddy log shows certificate errors | DNS A record doesn't point to the VPS yet, or ports 80/443 are blocked by the provider's firewall. Fix that; Caddy retries by itself. |
| `MySQL did not become ready` | Check `logs db`. If `DB_ROOT_PASSWORD` in `vps/.env` was changed after the first start, put the original value back. |
| Importing a large test keeps one CPU core at 100% | Normal: TAO imports in one PHP process. Requests may run up to 30 minutes (`max_execution_time` in `docker/php.ini`, `fastcgi_read_timeout` in `docker/nginx.conf`); a longer import is cut off with an error or a 504. |
| "Something unexpected happened" in TAO | Look for `tao.ERROR` in `logs tao`. |
| Build fails with "no space left on device" | `docker system prune` removes old images and build cache; check `df -h /`. |

## What was tested

Run in a test environment with the scripts in this repo, TAO 2026.11 / PHP 8.3 and the official `mysql:8.4`
and `caddy:2` images. The TAO image was a stand-in with the same configs and scripts on Ubuntu 24.04's
PHP 8.3, because Debian's package mirrors weren't reachable there:

* `vps-configure.sh` (IP mode), first `vps-deploy.sh`, then through Caddy on port 80: login page with form
  and without guest link, admin login, all back-office sections, item editor;
* `vps-backup.sh`, then **everything wiped** (`down -v`), fresh `vps-deploy.sh`, `vps-restore.sh`: the item
  created before the backup was back;
* changing the address and `DB_PASSWORD` in `vps/.env` plus `vps-deploy.sh`: both applied, login at the new
  address works, and TAO's permanent namespace is unchanged.

Not tested: `vps-setup.sh` on a real Ubuntu VPS (firewall, swap, cron), Let's Encrypt with a real domain,
rclone off-server copies, and the real image build from `docker/Dockerfile` (that build works in Azure).

## Limits compared with Azure

* **One server, no failover:** if the VPS or the provider has an outage, TAO is down until it's back, or
  until you restore a backup on another server. Take a manual backup before important exams.
* **No automatic scaling:** size the VPS for your largest exam.
* You're responsible for backups being copied off the server, and for occasional reboots.
