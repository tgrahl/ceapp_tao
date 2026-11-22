# Hosting options and costs

Prices are rough pay-as-you-go list prices for West Europe, per month, excluding VAT. Check them for your
region with the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/).

## Summary

| Option | Fixed cost / month | Autoscaling | Effort | Good for |
|---|---|---|---|---|
| **A. Container Apps + MySQL Flexible Server B1ms** (this repo) | ~€27–33 | yes, 0 → N | done | Production, irregular use, exam peaks |
| **A′. Same, with MySQL stopped between exam periods** | ~€8–10 while stopped | yes | manual or scheduled start/stop | Use only a few weeks per term |
| **B. One small VM with everything (docker compose)** | ~€17–40 always on; less with auto-shutdown | no | low | Small, steady use; simplest to understand |
| **C. Container Apps with MySQL in the same container** | ~€8–10 | no (max 1 replica) | medium | Demos only — **not recommended** |

## A. Container Apps + MySQL Flexible Server (current setup)

The app scales 0 → N; the database runs all the time on the smallest size.

| Resource | ~€ / month |
|---|---|
| MySQL Flexible Server, Burstable B1ms (1 vCore, 2 GiB), always on — default | 12–15 |
| *(B1s, 1 GiB, if your region allows it)* | *(6–7)* |
| MySQL storage, 20 GB | 2–3 |
| Container Registry, Basic | 5 |
| Storage account, Azure Files (pay per GB used) | 1–3 |
| Log Analytics | < 1 when idle (pay per GB ingested) |
| 2 × Standard static public IP (Container Apps environment on a custom VNet: one for inbound, one for outbound traffic) | ~7 |
| Load balancer in the `ME_…` resource group (created by Container Apps) | not billed separately per Microsoft's docs (check your bill) |
| Private DNS zone for MySQL | ~0.50 |
| Container Apps | **0 while idle.** Each month's free grant (180,000 vCPU-seconds, 360,000 GiB-seconds, 2M requests) covers about 25 hours of one 1-vCPU/2 GiB replica (memory runs out first). Beyond that, a running replica costs roughly €0.10 per hour. |

Example: the app is used ~2 hours a day (about 68 replica-hours/month, partly covered by the free
grant) → **~€28–34/month in total**, of which ~€2 is the app itself.

Ways to make it cheaper:
* **Drop the custom VNet (−€7):** give MySQL public access with the "allow Azure services" firewall rule
  and let Container Apps use its default managed network. The public IPs then go away. The catch is that
  database traffic then crosses public endpoints, so it must be encrypted. TAO's installer can't set
  TLS options, so `config/generis/persistences.conf.php` would need patching after the install to use
  TLS. Not implemented.
* **Stop MySQL when TAO isn't used** (holidays, between exam sessions): compute stops being billed, storage
  is still billed. Azure restarts a stopped server after 30 days. You can automate start/stop on a schedule
  with an Azure Automation runbook or a Logic App.
* **Drop the Container Registry** (€5) and use GitHub Container Registry (free for public images).
  This needs changes to `deploy.sh` and the registry settings in `main.bicep`.
* **Smaller replicas:** `cpu: '0.5'`, `memory: '1Gi'` halves the cost per active hour. Test that TAO stays
  responsive.

## B. One VM with everything ("DB on the same machine")

The repository's `docker-compose.yml` already *is* an all-in-one setup: web container + MySQL with local
disk. On a single Linux VM:

| Resource | ~€ / month |
|---|---|
| VM B1ms (1 vCPU, 2 GiB) / B2s (2 vCPU, 4 GiB) | 15 / 35 |
| OS disk, Standard SSD 32–64 GB | 2–5 |
| Public IP (Standard) | 3 |

* **Pros:** simplest architecture. The database sits on a real local disk, matching your original manual
  setup. Lowest cost when it runs all the time.
* **Cons:** no autoscaling (sized for your peak); you patch the OS yourself; you handle HTTPS yourself
  (e.g. a Caddy reverse proxy with Let's Encrypt); and backups are your job (VM backup or a nightly
  `mysqldump` plus a copy of the volumes).
* **Saving money:** Azure's VM *auto-shutdown* stops it every evening. Start it in the portal or with
  `az vm start`, or on a schedule. A stopped (deallocated) VM costs only its disk. There's no automatic
  start when a user visits, so someone must start it.

Rough steps (not scripted in this repo yet):
1. Create an Ubuntu 24.04 VM (B2s recommended for TAO), and open ports 80 and 443.
2. Install Docker Engine and the Compose plugin.
3. Clone this repository. Change all passwords in `docker-compose.yml`, and set `TAO_URL` to the public
   `https://` address.
4. Add a reverse proxy with HTTPS in front of port 8080.
5. Run `docker compose up -d --build`, then `docker compose run --rm install`.

## C. Container Apps with the database in the same container — why not

It's possible to run MySQL/MariaDB as a second container in the same Container App and remove the €15
database, but:

* **Database files would have to live on Azure Files.** Container storage is wiped every time the app
  scales to zero. Azure Files mounts in Container Apps use SMB, and Microsoft advises against running
  databases on SMB shares: file locking and `fsync` behave differently, which risks corruption and is slow.
  The NFS variant needs Premium Files (min. 100 GiB ≈ €16 / month), which costs as much as the managed
  database it replaces.
* **Only one replica allowed.** Two replicas would start two database servers on the same files. So you lose
  the scale-out under load.
* **Every scale-to-zero shuts the database down**, and every cold start must start it again (slower first
  request, crash recovery after an unclean stop).
* **No managed backups / point-in-time restore.**

Use this only for throwaway demos. For low cost *with* a local database, choose **B**. For low cost
*with* autoscaling, choose **A** and stop MySQL between exam periods (**A′**).

## Other Azure options considered

| Option | Why not used |
|---|---|
| Azure SQL Database serverless (auto-pauses, so the DB itself scales to zero) | TAO lists `pdo_sqlsrv` as a driver, but it's rarely used and untested with current TAO. Worth a separate experiment if the €15/month DB matters. |
| App Service (Web App for Containers) | No scale to zero: the smallest Linux plan (B1) costs ~€12/month all the time. It still needs a database. |
| Azure Container Instances | No HTTP autoscaling or scale-to-zero; you start and stop it yourself. |
