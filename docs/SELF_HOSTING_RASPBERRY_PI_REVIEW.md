# Self-hosting review: Raspberry Pi 4 / 5 and home mini PC (2026-10-30)

No Raspberry Pi hardware was available to this review. ARM findings are **compatibility evidence** (arm64 images built
and started under QEMU emulation on x86) plus **estimates**; they are not Pi performance measurements.
Measured inputs: production per-evaluation cost and payloads (`docs/LIVE_DATABASE_ARCHITECTURE_EVIDENCE.md`),
CPU-limited benchmarks of POC B (`docs/FLUENCY_POC_RESULTS.md`).

## 1. Is a Pi fast enough?

With the **bundled read path**, one sheet open costs 1-2 rules-core evaluations. On POC B, a 3-class level-9 character's
combat view needs ≈ 0.35-0.4 s of database time at 2 x86 CPUs (laptop cores), and the shell alone ≈ 0.06-0.15 s.

| Host | Single-core speed vs the benchmark laptop core (estimate) | Expected view time (3-class char) | SMALL TABLE | LARGE TABLE |
|---|---|---|---|---|
| Pi 4 (Cortex-A72 1.8 GHz, 4 GB) | ~25-35 % | ~1-1.6 s | adequate, not fluent | no |
| Pi 5 (Cortex-A76 2.4 GHz, 8 GB) | ~45-60 % | ~0.6-0.9 s | **adequate** | borderline at session-start bursts |
| Used mini PC (Intel 8th-10th gen i5, 8-16 GB) | ~70-90 % | ~0.4-0.5 s | yes | yes |
| Supabase Free (measured ≈ 0.5-1 benchmark CPU) | — | ~0.6-1.2 s (projected) | yes after rearchitecture | borderline |

So **a Pi 5 is roughly comparable to Supabase Free per evaluation** (estimate), and only the rearchitecture makes either
fluent. With the **current** 35-request model a Pi would reproduce the incident (4 cores at half speed, ~10 core runs per
open, 5 players at once).

## 2. Hardware (if self-hosting anyway)

| Part | Pi 5 build | Note |
|---|---|---|
| Board | Raspberry Pi 5 **8 GB** | 2026 memory-price rises: 8 GB list price reported at **$130-175** (sources disagree), 16 GB $305 (official page) |
| Storage | **NVMe SSD 256-512 GB on an M.2 HAT+** (or a USB 3 SSD) | **never a microSD card as the PostgreSQL data disk**; SD only for boot if at all (prefer NVMe boot) |
| Power | official 27 W USB-C supply | under-voltage corrupts disks |
| Cooling | Active Cooler or a case with a fan | sustained load throttles without it |
| UPS | small line-interactive UPS (also for the router) | survives short outages; clean shutdown on long ones |
| Network | wired Ethernet | |
| Backup target | second device (NAS/USB disk) **and** encrypted cloud copy | no single-copy backups |
| Estimated upfront | **€250-330** (board €120-160 + HAT/NVMe €45-55 + PSU/case/cooler €25-30 + UPS €60-90) | estimates, not quotes |

**Mini PC alternative:** a used business mini PC (e.g. Lenovo ThinkCentre Tiny / Dell OptiPlex Micro / HP EliteDesk Mini,
8th-10th gen i5, 8-16 GB RAM, SATA/NVMe SSD) typically sells used for **€100-180** (estimate, prices not verified), idles at
8-12 W, is x86 (every image works), has more RAM and a real SSD slot, and is faster. With 2026 Pi prices **the mini PC is
the better value** for a database host. A Pi 4 that the user already owns is fine for rehearsal only.

Electricity: Pi 5 ≈ 4-6 W average → ~45 kWh/year ≈ **€11/year** at €0.25/kWh; mini PC ≈ 10 W → ~€22/year.
Domain: Cloudflare Tunnel needs a domain on Cloudflare ≈ **€10-15/year**.

## 3. Deployment architecture (if chosen)

```
Phone/browser ── HTTPS ──> Cloudflare edge (TLS, DDoS, optional Access) ── Tunnel (outbound only) ──> home box
                                                                             cloudflared ──> API :8787 ──> PostgreSQL (docker network only)
GitHub Pages (static frontend, unchanged)   Supabase Auth (Google) kept, API verifies its JWTs (JWKS)
```

| Layer | Choice |
|---|---|
| OS | Raspberry Pi OS Lite 64-bit or Ubuntu Server 24.04 arm64; unattended security upgrades |
| Runtime | Docker Compose; `restart: unless-stopped`; health checks (`poc/portable-api/docker-compose.yml`) |
| Database | `postgres:17-alpine` (arm64), **`jit=off`**, data on the SSD, **no published port** (only the API container reaches it) |
| API | POC B portable API (Node 22 + Fastify + pg, pure JS → arm64 without native builds), 256 MB limit |
| Edge | `cloudflared` container; no inbound port on the router (works behind CGNAT and changing IPs) |
| Auth | keep Supabase Auth (Google + e-mail) and verify its tokens; or Cloudflare Access (free ≤ 50 users) as an *additional* gate |
| Firewall | ufw: deny inbound, allow SSH from LAN only (key-only) |
| Monitoring | external uptime check on `/health` (free tier of an uptime service), local disk/SMART check, backup-age check |

PostgreSQL is **never** exposed; port 5432 is never forwarded. Browser traffic reaches only the authenticated API.
Cloudflare Tunnel can be used safely as the only ingress; it terminates TLS at Cloudflare, so Cloudflare can see traffic
(acceptable for game data; state it to the players).

## 4. Failure modes

| Event | Effect | Mitigation | Recovery time |
|---|---|---|---|
| Home power outage | app down | UPS for minutes; auto-start on power return | minutes after power returns |
| Router / ISP outage | app down for everyone outside | none at home; announce; fallback = read-only export | duration of outage |
| CGNAT / changing IP | none with Tunnel | outbound tunnel | — |
| SSD failure | data since last backup lost | nightly off-device dump; SMART monitoring | 1-2 h (new disk, restore) |
| SD boot failure | down | NVMe boot; spare SD image | 30 min |
| Database corruption | down / wrong data | `pg_dump` nightly + checksums; restore rehearsal | 1 h |
| Theft / fire | box gone | encrypted off-site copy | 2-4 h on any other machine (Docker image is portable) |
| Bad update | down | pinned image tags, rollback by tag | 15 min |
| Security incident | data exposure | no open ports, updates, least-privilege DB role, secrets rotation | hours |

**A home server goes down when the home goes down.** For a weekly game this is acceptable only if the user accepts it.

## 5. Backups for a home server

- Nightly `pg_dump -Fc` → local backup disk + **encrypted** copy off-site (e.g. `age`/`gpg` + a free cloud folder or a second
  location), SHA-256 file, keep 14 daily + 8 weekly + 6 monthly.
- Pre-migration and pre-upgrade dumps kept separately.
- Monthly **restore rehearsal** into a scratch database with row-count and golden-value checks
  (`poc/portable-api/backup.sh` restores and verifies automatically).
- The server disk is never its own backup.

## 6. Maintenance

OS + Docker + PostgreSQL image updates, tunnel, backups, restore test, SMART/disk check: **~1-1.5 h/month** routine
(same list as `docs/AZURE_HOSTING_REVIEW.md` §3) + hardware failures.

## 7. Migration back to managed hosting

The data is plain PostgreSQL (`public` schema + shim). `pg_dump` from the box → `pg_restore` into Supabase (or any
managed PG) restores the same objects; Auth stays on Supabase if it was kept there, so no user migration. Expected: 1-2 h.

## 8. Verdict

| Question | Answer |
|---|---|
| Is a Raspberry Pi appropriate for Tavern Ledger? | Technically yes after rearchitecture (SMALL TABLE); not as the first move |
| Model / RAM | Pi 5, 8 GB (16 GB unnecessary); Pi 4 4 GB only for rehearsal |
| SSD/NVMe | **required** (NVMe via M.2 HAT+ preferred) |
| Capacity | SMALL TABLE comfortably with bundles; LARGE TABLE borderline in bursts |
| Pi 4 sufficient? | Not for fluent use |
| Pi 5 preferable? | Yes, over Pi 4 |
| Mini PC better value? | **Yes**, at 2026 Pi prices and for x86 compatibility, RAM and SSD |
| Outage behaviour | down with home power/Internet; UPS helps only short outages |
| Backups | nightly dump, off-device + encrypted off-site, monthly restore test |
| Remote access | Cloudflare Tunnel (no open ports, works behind CGNAT) |
| API protection | Supabase Auth JWT verification + RLS in PostgreSQL; optional Cloudflare Access |
| PostgreSQL private? | Always |
| Maintenance | ~1-1.5 h/month |
| Way back | `pg_dump` → managed PG, ~1-2 h |

**Raspberry Pi: NOT RECOMMENDED as Tavern Ledger's primary host today.** It removes €0 of cost (Supabase Free is already
€0), adds €250-330 of hardware, ~1 h/month of administration and home-outage risk, and it is not faster than Supabase Free
per evaluation. **If the user wants to self-host for its own sake, prefer a used mini PC (recommended with conditions:
SSD, UPS, off-site encrypted backups, Tunnel, Supabase Auth kept).**
