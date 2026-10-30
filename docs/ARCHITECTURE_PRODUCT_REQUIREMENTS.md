# Architecture product requirements (2026-10-30)

Part of the fluency / hosting review. Index and decision: `docs/FLUENCY_FINAL_RECOMMENDATION.md`.
Facts marked **(prod)** come from the read-only production inspection of 2026-10-30 (`docs/LIVE_DATABASE_ARCHITECTURE_EVIDENCE.md`);
everything else is a stated scenario, not a measurement.

## 1. What production actually holds today (prod)

| Item | Value |
|---|---|
| Users (auth) | 8, all confirmed, all signed in within 30 days |
| Sign-in method | **Google OAuth for 6 identities**, e-mail/password for 3 (one user has both) |
| Campaigns / memberships | 2 / 8 |
| Characters | 7 (5 legacy without class rows; the most complex has 1 class, level 2, 8 spells) |
| Inventory rows | 92 |
| Custom (homebrew) items | 0 of 1,146 items |
| Storage (portraits) | 0 objects, 0 bytes |
| Change requests | 0 |
| Database size | 30 MB total; `public` 10.8 MB (catalog is most of it) |
| Concurrent use observed | 66 Realtime subscription rows during the inspection, consistent with 1 open sheet (64 + 2 request bar; stale rows cannot be excluded) |

The **catalog** (items, spells, classes, feats, lineages, backgrounds, creatures) dominates both storage and per-request
CPU. Player data is tiny and grows slowly.

## 2. Workload scenarios

No exact numbers were given by the user, so the design is checked against two explicit scenarios.

| Dimension | SMALL TABLE (today) | LARGE PRIVATE TABLE (ceiling) |
|---|---|---|
| DMs / players | 1 / 4-6 | 2-3 / 10-20 |
| Campaigns | 1-2 | 3-5 |
| Characters | < 50 (7 today) | ~100 |
| Typical character | level 1-10, 1-2 classes, 10-40 items, 0-40 spells | up to level 20, 3 classes, 100 items, 100 spells |
| Custom content | a few items/feats | a few hundred rows |
| Storage | 30 MB today, < 100 MB in 3 years | < 300 MB (portraits stored externally or small) |
| Active session | 1 per week, 3-5 h | 2-3 per week, 3-5 h |
| Peak during a session | 5-7 browsers (DM often 2 tabs), session-start burst of 5 opens within seconds | 20-25 browsers, 2 sessions overlapping |
| Idle | days between sessions; occasional planning visits | hours |
| Mobile | most players on phones at the table (assumed); DM on a laptop | same |
| Requests/month (bundled design) | ~5-20 k | ~100 k |

Design consequence: the system must be good at a **burst of 5-25 sheet opens within a few seconds after long idle**, not
at throughput. Anything that sleeps (scale-to-zero, free-tier pause) must wake within the time players tolerate, or
must be kept warm.

## 3. Functional requirements that constrain hosting

| Requirement | Today | Needed | Note |
|---|---|---|---|
| Remote access from phones and ordinary browsers | yes (GitHub Pages + hosted Supabase) | **yes** | rules out LAN-only hosting |
| Google sign-in | yes, 6 identities | **yes** (or a migration that re-links 6 users) | strong pull toward keeping Supabase Auth |
| E-mail/password sign-in + reset | yes | yes | |
| Public sign-up | ON (user choice 2026-10-23) | **no** for a private table; invite-only is enough | Supabase setting; not changed in this task |
| MFA | not used (0 factors) | optional | |
| Realtime | 64+2 bindings per sheet | **"someone else changed this"** within a few seconds for HP / slots / Wild Shape / approvals / locks / reveals | DB-level change streams are not required; see `docs/FLUENT_READ_ARCHITECTURE.md` §7 |
| Hidden DM data | RLS (conditions, DM notes, secret items, audit) | **must stay server-enforced** | any API keeps RLS as the last line |
| Authoritative derived stats | SQL rules core | must stay server-side | never in the browser |
| Export / import | JSON in the browser | keep | |
| Storage (portraits) | supported, unused in prod | nice to have | |

## 4. Non-functional targets ("fluent")

Measured over a real hosted connection (phone on Wi-Fi/4G, 50-150 ms RTT):

| Interaction | Target (p50 / p95) | Today (see baseline) |
|---|---|---|
| Home list correct | 400 ms / 800 ms | ~ 1-2 RTT; OK |
| Character open: identity + vitals visible | **300 ms / 600 ms** | ~0.9 s local-at-150 ms; 1.6-4 s estimated on Free (DB-bound) |
| Character open: active tab complete | 600 ms / 1.2 s | 2-5 s estimated on Free |
| Character switch A → B → C (C usable after last click) | 600 ms / 1.2 s | 3.3 s measured at 2 CPUs with today's model |
| Tab change | 150 ms (cached) / 600 ms (cold) | variable |
| Picker list visible | 300 ms / 700 ms | 260-380 ms local; 470 KB payload |
| Session-start burst (5 players at once) | every sheet usable < 1.5 s | 4-7 s measured at 2 CPUs with today's model |
| Wake after idle (cold start) | < 3 s once per session is acceptable; not per request | Free pauses only after 7 days |

## 5. Operating constraints (from the brief)

| Constraint | Accepted value |
|---|---|
| Monthly cost | as close to 0 as practical; a small amount (< ~€25/month) is acceptable if it buys reliability |
| Maintenance | one person, hobby time: target < 1 h/month routine |
| Downtime | a few hours unplanned per quarter is tolerable; **not during a session** |
| Data loss | at most 24 h of edits; never the whole campaign |
| Backups | daily, off-provider, restore rehearsed |
| Recovery time | < 2 h to restore service after a failure |
| Scale | no design for thousands of users |
