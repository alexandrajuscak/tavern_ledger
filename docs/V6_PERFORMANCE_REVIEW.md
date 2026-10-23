# V6 performance review (local measurements, 2026-10-22)

All numbers come from this machine: the static dev server `scripts/local/serve_frontend.py` and local Supabase in Docker,
measured with Microsoft Edge driven by Playwright (median of 3 repetitions unless noted). They do not describe a hosted
deployment.

## Measured paths (after the fixes)

| Path | Median | Notes |
|---|---|---|
| Initial load: document response → DOMContentLoaded | 85–100 ms | App work only. The wall time in a fresh test context is 0.2–0.9 s; the rest is the browser's connection setup before the first request (`requestStart` at ~710 ms in reused-browser contexts), not the app |
| Requests for the initial load | 49 | All local. Before: the same plus ~12 requests to `cdn.jsdelivr.net` per load (108 in the audit run) |
| Sign-in → home cards shown | 0.28 s | Cards appear with loading marks |
| Home: all 35 cards authoritative | **1.24–1.34 s** | Before: **2.68 s** (3 parallel derived reads) |
| Character open (authoritative AC shown) | 0.44 s | |
| Character switch | 0.23 s | |
| Spells ready (slot tracker) | 0.06 s | After the sheet is loaded |
| Inventory ready (metric cards) | 0.06 s | |
| Build ready (class card) | 0.09 s | |
| Export preparation (download ready) | 0.42 s | |
| Wild Shape picker open (forms listed) | 0.07 s | Wild Shape Druid 4 |
| DM Overview ready | 0.23 s | |
| DM Content library ready | 0.07 s | |

## Changes and before / after

| Change | Before | After | Evidence |
|---|---|---|---|
| No repeated reads on character open: the inventory's first load no longer schedules another derived read; a spellbook read already newer than the derived read is not repeated | 40 REST requests per open (62 on the first); derived stats ×2, proficiencies ×2, spellbook ×3 | 36 per open (58 on the first); one read each | `audit-before/` vs `audit-after/` `audit_report.json` |
| Home card stats: 6 parallel reads instead of 3 | 2.68 s for 35 cards | 1.6 s, then 1.24–1.34 s in the median runs | home probe, perf probe |
| supabase-js self-hosted (deferred classic script) | ~12 CDN requests per load, a third-party dependency | 0 external requests; the same 218 KB library from `vendor/` | NET1, audit-after `external: {}` |

## Checked, no change needed

- **Realtime subscriptions:**
  - one channel per open sheet and one for its requests; joins minus leaves = 2 after any number of switches
    (16 joins / 14 leaves after 8 characters);
  - DM Space: one channel, re-created only when its route mounts again;
  - an equip made elsewhere reaches the sheet in ~0.5 s and is applied in ~1.5 s (the inventory and derived debounces).
- **Memory over a long session:** a heap snapshot after 24 sheet mounts driven inside the page, all tabs and a dialog each
  time, holds **0** old sheet roots. Growth seen in Playwright-driven loops comes from Playwright's own element handles
  (retainer path "(Global handles) → DevTools console"), not from the app.
- **DOM size:** at most ~3,300 elements on the largest sheet (multiclass caster), stable across switches.
- **Large picker search:** the spell and feat pickers filter in memory on input. The first-click-after-search fix of the
  earlier tasks is kept.

## Not changed (documented)

- `damage_types` and `class_versions` are read once by two modules each (first sheet of a session, a few KB). A shared
  cache would be a refactor with little gain.
- The derived-stats read stays one RPC per character on Home. A batch RPC would be a backend change, out of scope.
