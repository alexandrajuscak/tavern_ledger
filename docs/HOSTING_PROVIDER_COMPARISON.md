# Hosting provider comparison (checked 2026-10-30)

Prices are **estimates, not quotes**. Region: EU (West Europe / Germany). Currency: EUR; USD list prices converted at an
assumed **€0.90 per USD**. "Verified" = read on the provider's own page or API on 2026-10-30 (sources at the end);
"unverified" = third-party or not rendered, stated as such. Ranking and weights: `docs/HOSTING_AND_ARCHITECTURE_SCORECARD.md`.

Key point for every option: **a database alone is not enough.** Leaving Supabase also means providing Auth (Google
OAuth for 6 of 8 users), an API (PostgREST replacement) and change events (Realtime replacement). The portable API from
POC B covers API + events; Auth is the hard part (`docs/SUPABASE_DEPENDENCY_INVENTORY.md`).

## 1. Supabase Free (current)

| Item | Value | Source |
|---|---|---|
| Compute | **Nano**: shared CPU, up to 0.5 GB RAM; 60 direct connections, 200 pooler clients | verified (compute docs) |
| Database size limit | 500 MB (we use 30 MB, 6 %) | verified |
| Backups | **not included** on Free; Supabase recommends regular `db dump` exports kept off-site | verified (backups docs) |
| Pausing | paused after **1 week of inactivity**; restore from the dashboard | verified (pricing) |
| Log retention | 1 day | verified |
| Realtime | 200 concurrent connections, 2 M messages/month | verified |
| Egress | 5 GB/month | verified |
| Cost | €0 | |
| Measured | derived-stats core ~260 ms server time at idle, stable (±5 %); REST round trip 75-110 ms warm, 140-630 ms new connection | `docs/LIVE_DATABASE_ARCHITECTURE_EVIDENCE.md` |

Answers to the brief:
- **Can architecture alone make it fluent?** **Single opens: yes; session-start bursts: only with the build snapshot.** Bundles
  drop one open from ~10 core evaluations to 1-2 (≈ 0.3-0.7 s of server CPU instead of 2.8-4 s; projected open 0.5-0.9 s).
  On a production-like CPU, 5 simultaneous opens of heavy characters still took ~4.5 s with bundles (0 timeouts, vs 19 today).
  The revisioned snapshot (no rules evaluation on ordinary reads, €0) or more CPU closes that gap
  (`docs/FLUENCY_POC_RESULTS.md` §3, §5).
- **Within size limits?** Yes, by a factor of ~16.
- **Shared-compute variability visible?** Not at idle (5 calls within ±5 %). Under concurrency the cost multiplies, which
  is what users felt; that is an architecture effect on a small CPU, not jitter.
- **Is Realtime necessary?** Change notification is; 64 database bindings per sheet are not.
- **Still the best package?** Yes: Auth with Google, hosted PostgreSQL, zero administration, €0. Its two real gaps are
  **no backups** and the **7-day pause**; both have cheap mitigations (scheduled off-site dump; sessions are weekly).
- **Would eliminating repeated RPCs solve most of it?** Yes; measured on the same database: usable 1.6-3.3×, bursts 3.2-4.2×,
  switches 5.4-7.3× faster, statement timeouts eliminated (§3 of the POC doc). The remainder on Free is the one evaluation per open.

## 2. Supabase Pro

| Item | Value | Source |
|---|---|---|
| Price | from **$25/month (≈ €22.5)** per organization, includes **$10 compute credits** = one Micro instance | verified |
| Micro | shared CPU, **1 GB RAM**, 60 direct / 200 pooler connections, max DB 10 GB, ~$10/month (covered by credits) | verified |
| Backups | daily, **7 days** retention (physical; restore via dashboard; not stated as downloadable → keep own `pg_dump` too) | verified |
| PITR | +$100/month per 7 days (not needed) | verified |
| Pausing | never | verified |
| Logs | 7 days | verified |
| Realtime | 500 concurrent, 5 M messages included | verified |
| Spend cap | on by default | verified |
| Annual / 3-year | ≈ €270 / €810 | computed |

Expected effect: Micro has **the same "shared" CPU class** as Nano, with twice the RAM. The database already fits in RAM
(100 % cache hit), so the RAM doubling buys little for this workload. CPU share per evaluation is not documented;
improvement is **unknown and probably modest** (estimate, not measured: we cannot benchmark Micro without upgrading,
which this task forbids). What Pro reliably buys: **backups, no pause, longer logs**. It does **not** fix 35 requests
per open.

| Scenario | Fluency | Cost |
|---|---|---|
| Rearchitecture only (Free) | opens good (projected 0.5-0.9 s); bursts ~2-4.5 s until the snapshot (Phase 1b) is added | €0 |
| Rearchitecture + snapshot (Free) | opens ~0.2-0.35 s, bursts < 1 s (estimates) | €0 |
| Upgrade only (Pro Micro) | still multi-second bursts and timeouts possible (same request model, similar CPU class) | €270/yr |
| Rearchitecture + upgrade | likely best managed option; Micro gain unmeasured | €270/yr |

## 3. Neon

| Item | Value | Source |
|---|---|---|
| Free | 100 CU-hours/project/month, autoscale to 2 CU, 1 GB storage/project (some FAQ pages say 0.5 GB), 5 GB transfer; no card | verified (pricing/FAQ) |
| Scale to zero | after **5 min idle; cannot be disabled on Free** | verified |
| Free overrun | compute **suspended until next month** (no overage billing) | verified |
| Launch (pay-as-you-go) | $0.106/CU-hour, $0.35/GB-month, scale-to-zero can be disabled | verified |
| Always-on 0.25 CU on Launch | 730 h × 0.25 × $0.106 ≈ $19.3 ≈ **€17.4/month** + storage | computed |
| Branching | yes (useful for migration rehearsals) | verified |
| Supplies Auth / API / Realtime? | No (Neon Auth exists as a product; not evaluated here, unverified) → portable API + external Auth required | |

Fit: PostgreSQL-compatible; the POC B shim applies unchanged. **Cold start after 5 min idle conflicts with fluency** at the
first open of every session lull (the wake time was not measured here; treat as unknown). The 1 GB storage
is enough. Free compute suspension at 100 CU-hours is a reliability risk only if kept awake. **Verdict: viable database
for a portable stack, but on Free it adds a cold start and still needs API + Auth + events hosting. Not preferred.**

## 4. Aiven

| Item | Value | Source |
|---|---|---|
| Free | 1 CPU, 1 GB RAM, **1 GB storage** (reduced from 5 GB on 2025-05-15), single node, no time limit | verified |
| Free behaviour | may be **powered off after inactivity** (e-mail notice first); `max_connections` 20; no pooling, no static IP, no SLA | verified |
| Developer tier | **$5/month (≈ €4.5)**: 1 CPU, 1 GB RAM, 8 GB storage, runs 24/7 | verified |
| Backups | not checked on the fetched pages (unverified) | |

Fit: the Developer tier is the cheapest always-on managed PostgreSQL found. Still needs API host + Auth + events.
**Verdict: credible database for option G (≈ €4.5 + API host), but every Supabase service must be replaced.**

## 5. Azure (details in `docs/AZURE_HOSTING_REVIEW.md`)

| Item | EUR, West Europe (Retail Prices API, 2026-10-30) |
|---|---|
| PostgreSQL Flexible Server Burstable **B1ms** (1 vCore, 2 GiB) | €0.0175/h → **€12.78/month** |
| Flexible Server storage | €0.1205 per GB-month (32 GB ≈ €3.86) |
| Backup storage LRS | €0.0906 per GB-month beyond the included amount |
| Free account (new customers only) | 750 h B1ms + 32 GB storage + 32 GB backup per month **for 12 months** (Microsoft pages; table not rendered, wording verified) |
| VM B2pts v2 (ARM, 2 vCPU, 1 GiB) | €0.0084/h → €6.13/month |
| VM B2ats v2 (x86, 2 vCPU, 1 GiB) | €0.0095/h → €6.94/month |
| VM B1s (1 vCPU, 1 GiB) | €0.0106/h → €7.74/month |
| Standard SSD E4 (32 GiB) | €2.11/month |
| Static public IPv4 (Standard) | €0.0044/h → €3.21/month |
| Container Apps | consumption: per vCPU-s / GiB-s with a monthly free grant (grant size not verified here); requests €0.49 per million |

## 6. Low-cost VPS (Hetzner as the reference)

| Item | Value | Source |
|---|---|---|
| CAX11 (ARM, 2 vCPU, 4 GB, 40 GB) | ≈ **€5.99-6.49/month incl. IPv4** (after the 2026 price rises) | unverified (third-party, Oct 2026) |
| CX23 (x86, 2 vCPU, 4 GB) | ≈ €5.49-5.99/month | unverified |
| Backups | +20 % of server price (7 slots) | unverified |

Fit: by far the most RAM/CPU per euro; a 4 GB box runs PostgreSQL + API + Caddy comfortably. Full system
administration falls on the user (`docs/AZURE_HOSTING_REVIEW.md` §3 lists the duties; same for any VPS).

## 7. Cloudflare as the edge

| Item | Value | Source |
|---|---|---|
| Workers Free | 100,000 requests/day, **10 ms CPU per request**, 128 MB | verified |
| Hyperdrive | included in Free and Paid Workers; **100,000 queries/day on Free** | verified |
| Tunnel | free on all plans (outbound-only connector) | verified (Cloudflare blog/community; docs page silent on price) |
| Zero Trust / Access | free for **up to 50 users** | verified (Cloudflare product pages via search) |
| Pages Free | 500 builds/month, 1 concurrent build, 100 projects, 20,000 files/site | verified |

Can Workers be the API? Bundles are computed in PostgreSQL, so the Worker would mostly wait on I/O (wall time is not CPU
time); 10 ms CPU is enough for JWT verification + forwarding + JSON pass-through of < 100 KB. But: Worker → database
needs Hyperdrive or a TCP-capable driver, the rules still run on the database, and Workers add a third platform. **Useful
only as a cache/gateway in front of a small API, not as a replacement for it.** Tunnel is the right tool for a home server.

## 8. Rejected or not worth listing

| Provider | Reason |
|---|---|
| Render / Railway / Koyeb free Postgres | free databases on these platforms have historically been time-limited or usage-capped; **not verified for 2026 in this review**, so not recommended on assumption |
| Prisma Postgres | not verified; serverless model with the same API/Auth gaps as Neon |
| DigitalOcean managed PostgreSQL | not verified; managed PG typically ≥ €13-15/month, no advantage over Supabase Pro which includes Auth |

## 9. Frontend hosting

GitHub Pages: measured 51 static requests, ~480 KB, first paint **1.06 s cold / 0.10 s warm**, `Cache-Control: max-age=600`,
CDN hit. That is not the bottleneck. **Keep GitHub Pages.** Move to Cloudflare Pages only if the API moves behind
Cloudflare (same-origin API, custom security headers, preview deployments). Azure Static Web Apps / Netlify / Vercel
offer nothing this app needs that Pages lacks.

## Sources (read 2026-10-30)

- Supabase: [compute and disk](https://supabase.com/docs/guides/platform/compute-and-disk), [pricing](https://supabase.com/pricing), [backups](https://supabase.com/docs/guides/platform/backups), [compute usage](https://supabase.com/docs/guides/platform/manage-your-usage/compute), [database-only cost FAQ](https://supabase.com/kb/faqs/platform/database-only-cost)
- Neon: [pricing](https://neon.com/pricing), [Free plan limits FAQ](https://neon.com/faqs/free-plan-limits-and-quotas)
- Aiven: [free tier docs](https://aiven.io/docs/products/postgresql/concepts/pg-free-tier), [free PostgreSQL](https://aiven.io/free-postgresql-database), [free storage change](https://aiven.io/changelog/6ad6c429-6c1c-4418-abfb-2ca82f927414), [developer tier](https://aiven.io/developer-tier-pg-mysql)
- Azure: Retail Prices API `https://prices.azure.com/api/retail/prices` (EUR, westeurope), [PostgreSQL Flexible Server pricing](https://azure.microsoft.com/en-us/pricing/details/postgresql/flexible-server/), [free account PostgreSQL quickstart](https://learn.microsoft.com/en-us/azure/postgresql/configure-maintain/how-to-deploy-on-azure-free-account), [free services](https://azure.microsoft.com/en-us/pricing/free-services)
- Cloudflare: [Workers limits](https://developers.cloudflare.com/workers/platform/limits/), [Workers pricing (Hyperdrive)](https://developers.cloudflare.com/workers/platform/pricing/), [free tunnels](https://blog.cloudflare.com/tunnel-for-everyone), [Access](https://www.cloudflare.com/zero-trust/products/access/), [Pages limits](https://developers.cloudflare.com/pages/platform/limits/)
- Hetzner (third-party, unverified): [vpsfor.dev CX22/CX23](https://vpsfor.dev/posts/hetzner-cx22-pricing-2026/), [costgoat calculator](https://costgoat.com/pricing/hetzner)
- Raspberry Pi: [Raspberry Pi 5 product page](https://www.raspberrypi.com/products/raspberry-pi-5/), [Tom's Hardware price rises](https://www.tomshardware.com/raspberry-pi/component-shortages-drive-raspberry-pi-prices-up-by-up-to-23-percent-escalating-lpddr4-lpddr5-costs-trigger-the-third-price-hike-of-the-year)
