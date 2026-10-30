# Azure hosting review (2026-10-30)

Prices: Azure Retail Prices API, EUR, region **West Europe**, pay-as-you-go, checked 2026-10-30 (estimates; VAT excluded).
Workload: `docs/ARCHITECTURE_PRODUCT_REQUIREMENTS.md`. Comparison with other hosts: `docs/HOSTING_PROVIDER_COMPARISON.md`.

## 1. Azure Database for PostgreSQL Flexible Server + small API (option E)

| Component | Choice | €/month |
|---|---|---|
| Database | Burstable **B1ms** (1 vCore, 2 GiB), PostgreSQL 17, public access with firewall or private endpoint | 12.78 |
| Storage | 32 GB (minimum practical) × €0.1205 | 3.86 |
| Backups | 7-day automatic, included up to provisioned storage; extra LRS €0.0906/GB | ~0 |
| API | Container Apps (consumption; scale to 0 → cold start) **or** App Service B1 (always on, not priced here) **or** a B-series VM | 0-13 |
| Auth | Entra External ID (free tier for small MAU; not verified here) or keep Supabase Auth | 0 |
| Events | SSE from the API (POC B) | 0 |
| **Total after free period** | | **≈ €17-30/month (€200-360/year)** |

Free allowance: the Azure free account gives **750 h/month of B1ms + 32 GB storage + 32 GB backup for 12 months, new
customers only** (Microsoft wording verified; amounts as stated on Microsoft pages). After 12 months billing starts
automatically. A stopped Flexible Server still bills storage, and Azure **auto-starts a stopped server after 7 days**, so
stop/start is not a saving strategy for a weekly game.

What it does well: managed patching, automatic backups with point-in-time restore, monitoring, TLS, private networking, HA
(not needed). Burstable B1ms accumulates CPU credits when idle, which suits bursty sessions.

Fit problems:
- The application still needs **an API host, Auth and events**; Azure Functions add cold starts and per-request
  connection handling (needs a pooler); Container Apps on consumption scale to zero (cold start on the first open of a
  session) unless a minimum replica is paid for.
- Entra External ID would replace Google sign-in flows with a Microsoft identity platform: heavy for 8 players.
- Total cost is in the same range as **Supabase Pro**, which already includes Auth, API, Realtime and backups.

## 2. Azure VM with PostgreSQL + API (option F)

| Component | Choice | €/month |
|---|---|---|
| VM | B2pts v2 (ARM, 2 vCPU, 1 GiB) / B2ats v2 (x86, 2 vCPU, 1 GiB) / B1s (1 vCPU, 1 GiB) | 6.13 / 6.94 / 7.74 |
| OS disk | Standard SSD E4 32 GiB | 2.11 |
| Public IPv4 | Standard static | 3.21 |
| Bandwidth | first 100 GB egress/month free (typical Azure allowance; not re-verified) | 0 |
| Off-VM backup | Blob Storage, a few GB (not priced here, < €0.20) | ~0.2 |
| **Total** | | **≈ €11.5-13/month (€140-160/year)** |

1 GiB RAM is tight for PostgreSQL + Node + OS (POC B idle: PostgreSQL 55 MB, API 20 MB, so it fits, but leaves little
cache headroom). Free account: 750 h of selected B-series VMs for 12 months (amounts not verified in this review).

## 3. Operational duties of any self-managed VM (Azure, Hetzner, home server alike)

| Duty | Frequency | Effort |
|---|---|---|
| OS security updates (unattended-upgrades) + reboot window | weekly automatic, monthly check | 10 min/month |
| PostgreSQL minor updates (container image pin + pull) | monthly | 10 min |
| Major PostgreSQL upgrade (dump/restore) | yearly | 1-2 h |
| Firewall (only 443 / or tunnel; SSH key-only; no 5432) | once + review | 15 min/quarter |
| TLS (Caddy auto-ACME or Cloudflare Tunnel) | automatic | 0-5 min/month |
| Backups: nightly `pg_dump` → off-host + checksum; restore test | daily automatic; restore monthly | 20 min/month |
| Monitoring: health endpoint + external uptime check + disk alert | automatic | 5 min/month |
| Secrets rotation (DB passwords, JWT/OAuth secrets) | yearly or after exposure | 30 min/year |
| Incident handling | rare | unbounded |

Realistic routine: **~1 h/month**, plus occasional incidents. This is what "self-hosting is not free" means.

## 4. Verdicts (the brief's questions)

| Question | Answer |
|---|---|
| Is Azure cost-effective for this private app? | **No.** ≈ €17-30/month for managed PG + API, or ≈ €12/month for a VM that the user must administer. Supabase Pro is similar money with Auth/Realtime/backups included; a Hetzner VPS is half the VM price with 4× the RAM. |
| Is Azure Database for PostgreSQL overkill? | Yes: HA, PITR and enterprise networking solve problems this table does not have; the B1ms tier is the floor. |
| Is an Azure VM cheaper? | Yes (≈ €12 vs ≈ €17+), but it moves all administration to the user. |
| Functions or Container Apps for the API? | Possible; both add cold starts when scaled to zero, which conflicts with the "first open after idle" target. An always-on API is the simpler fit. |
| Durable free option? | **No.** Only the 12-month free account allowance; after it expires billing starts automatically. |
| After free credits expire? | ≈ €200-360/year for option E. |
| Is the complexity justified? | No. Three or more Azure services plus an Auth migration replace one Supabase project. |
| Meaningful advantage over Supabase Pro, Neon or self-hosting? | None for this workload. Familiarity with Microsoft technology is not a reason (brief §10). |

**Verdict: Azure — NOT RECOMMENDED** for Tavern Ledger, neither as managed PostgreSQL nor as a VM. Revisit only if the
user's employer provides free Azure credits *and* the portable API (POC B) is already in place, in which case an Azure VM is
equivalent to any VPS.
