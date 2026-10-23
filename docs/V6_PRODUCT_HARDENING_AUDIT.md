# V6 product hardening: audit (2026-10-22)

The audit is based on use of the running app, not only on the source. Tools used:

- A read-only audit probe (local demo player and DM): 6 viewports (1920, 1366, 1024, 820, 390, 360), 8 characters × 6 tabs and
  all 8 DM sections. It recorded console errors, failed and external requests, page overflow, heading order, unnamed
  controls, broken images, raw enum-like text, small touch targets, timings, request counts and Realtime joins and leaves.
  Report: `tavern-ledger-local-backups/v6-hardening-2026-10-22/audit-before/` and `…/audit-after/`.
- Session-length, leak and heap-snapshot probes: up to 100 rounds of switching characters and tabs and opening and closing
  dialogs.
- Synthetic scenario tests with mutations: `v6_product_hardening_ui_test.py` and the existing feature suites.

Severity: BLOCKER · SERIOUS · MODERATE · POLISH · FUTURE.

## Summary

| Severity | Found | Fixed | Deferred / documented |
|---|---|---|---|
| Blocker | 0 | – | – |
| Serious | 8 | 8 | 0 |
| Moderate | 8 | 6 | 2 (V6-15 deferred, V6-16 documented) |
| Polish | 3 | 1 | 2 checked, no defect (V6-17, V6-18) |
| Future | 6 | – | 6 |

## Issues

| ID | Screen / area | Role, viewport | Current behaviour (before) | Expected | Sev. | Root cause | Files | Correction | Test | Status |
|---|---|---|---|---|---|---|---|---|---|---|
| V6-01 | Home: character cards | player, all | Cards first show the stored legacy AC (10 for every character, including an armoured Paladin with AC 19) and the base maximum HP; the authoritative values replace them ~2.7 s later | Never show a wrong number | SERIOUS | Card used `c.ac` / `c.hp_max` until the per-card derived read returned | `js/app.js` | Loading marks ("…", accessible "loading") until the authoritative values arrive; on failure "—" with a hint | H3, H1, H2 | Fixed |
| V6-02 | Autosave | player, all | A write the server can never accept (constraint, permission, validation) was retried forever: "Save failed — retrying", no reason | Tell the player, stop retrying, show the stored value | SERIOUS | `saver.flush` re-queued every non-governance error | `js/store.js` | Permanent SQLSTATE / PostgREST codes are dropped with "Not saved: …" and the sheet reloads the stored values | Z7, Z7b | Fixed |
| V6-03 | Error messages (feats, DM Space, governance, classes) | player, DM | Raw database text could reach the UI (constraint names, "violates row-level security", "Could not find the function …", JWT errors) | Plain words: what happened, that nothing changed, what to do | SERIOUS | Wrappers passed `error.message` through | `js/utils.js`, `js/feat-api.js`, `js/dm-api.js`, `js/governance-api.js`, `js/class-api.js` | `friendlyError()`: server-written messages stay; technical ones are mapped; details go to the console | Z7 (+ docs/ERROR_MESSAGE_REVIEW.md) | Fixed |
| V6-04 | Test reliability | — | `local_demo_smoke_test` assumed the seeded slot state and changed the demo characters (rest, slots, arrows): later runs failed (fixture drift) | Deterministic, self-restoring | SERIOUS | Mutable runtime state assumed | `supabase/tests/browser/local_demo_smoke_test.py` | Snapshot of every row of the touched demo characters, explicit slot state, exact restore (triggers off, identity override), residue check | its own check 23 | Fixed |
| V6-05 | Network | all | Every load fetched supabase-js from jsDelivr (108 CDN requests in the audit run): an external dependency, no offline use, a third party sees usage | No runtime CDN | SERIOUS | ESM import from `cdn.jsdelivr.net` | `index.html`, `js/supabase.js`, `vendor/supabase-js/` | The same version (2.117.2, UMD build, MIT) self-hosted | NET1, L1, local smoke tests | Fixed |
| V6-06 | Play, Build, Wild Shape, DM Space | screen reader, all | Heading levels skipped (h2→h4 action cards, h3→h5 background parts, h4→h6 Wild Shape, h1→h3 DM cards) | No skipped level | SERIOUS | Card titles used h4/h5/h6; DM sections had no h2 | `js/sheet.js`, `js/derived-ui.js`, `js/background-ui.js`, `js/lineage-ui.js`, `js/wild-shape-ui.js`, `js/dm-space.js`, `css/styles.css` | h3 card titles, h4 background parts, h5 Wild Shape parts, a section h2 in DM Space | X1, X1b–d, DM2 | Fixed |
| V6-07 | Abilities, vitals | touch, 390 | Skill and save marks 20 px, collapse handle 22 px tall, the collapsed AC button ~22 px | ≥ 24 × 24 px (WCAG 2.2 AA) | SERIOUS | Small visual controls without a larger hit area | `css/styles.css` | Marks keep their look with a 32 px hit area; handle 28 px on phones; AC button min 28 × 36 | X6a, X6b | Fixed |
| V6-08 | Dialogs | keyboard, screen reader | A confirmation without a field (Revert, Remove …) left focus on the page behind it | Focus moves into the dialog | SERIOUS | Initial focus only looked for inputs | `js/utils.js` | Falls back to the dialog element (`tabindex="-1"`) | X3 | Fixed |
| V6-09 | Character open | all | Each open read derived stats ×2, proficiencies ×2 and the spellbook ×3 | One read each | MODERATE | The inventory's first load and every derived render scheduled more reads | `js/sheet.js` | The first inventory load is not a change; a spellbook read started after the derived read is not repeated | audit-after (40 → 36 requests per open) | Fixed |
| V6-10 | Home | player | All 35 cards were authoritative only after ~2.7 s | Faster | MODERATE | 3 parallel reads | `js/app.js` | 6 parallel reads (~1.6 s) | home probe | Fixed |
| V6-11 | Vitals | player | Current HP could be typed above the maximum; hit dice above the level | Bounded | MODERATE | Bounds 0–9999 | `js/sheet.js` | Current HP ≤ authoritative maximum (after the derived load), hit dice ≤ level | V4 | Fixed |
| V6-12 | DM Space: Campaign rules | DM, 360 | "Download DM backup (includes hidden data)" pushed the page 14 px sideways | No page overflow | MODERATE | `.btn` is `nowrap` | `css/styles.css` | Buttons may wrap below 420 px | DM3, R1 | Fixed |
| V6-13 | Toasts | all | Errors vanished after 3.2 s; identical toasts stacked | Readable errors, one message per operation | MODERATE | Fixed duration, no dedupe | `js/utils.js` | Errors ≥ 6.5 s, identical visible toast not repeated, at most 3 | (manual) | Fixed |
| V6-14 | Test suites | — | Seven suites allowed CDN and Google hosts, so external requests passed silently | Any external host fails | MODERATE | Old allowlists | 7 browser test files, 2 smoke tests | Allowlists removed | full suite | Fixed |
| V6-15 | Reference reads | all | `damage_types` and `class_versions` are read once by two modules each (first sheet of a session) | One read | MODERATE | Separate module caches | `js/inventory-api.js`, `js/feat-api.js`, `js/class-api.js` | Not changed: tiny, once per session; a shared cache would be a refactor | — | Deferred |
| V6-16 | Realtime | — | In 1 of 5 hardening runs the vitals AC followed an API equip after > 15 s (I2) | ≤ 2 s | MODERATE | Not reproduced: 10 / 10 equip / unequip rounds updated in ~1.5 s with events after ~0.5 s | — | Monitored; documented | I2 | Documented |
| V6-17 | Session length | — | Heap appeared to grow ~0.2 MB per round in a 100-round probe | Stable | POLISH | Proven test-harness artefact: Playwright handles retain elements; with an in-page session, a heap snapshot after 24 sheet mounts holds 0 old sheet roots | — | No app change | leak probe | No defect |
| V6-18 | DM Overview | DM | Zero counters visible beside urgent ones | Urgent first | POLISH | — | — | Already muted (`.is-zero`), "Needs you" first | DM1 | Confirmed OK |
| V6-19 | Build lock wording | player | A build lock shows the level-up reason "Your DM has paused progression" | Name the lock that applies | POLISH | One sentence for all lock modes | `js/sheet.js` | See the review: wording per lock mode | L2 | Fixed (the hardening and UX suites were run again afterwards) |

## Areas audited without findings above POLISH

- Authentication and sign-in, both demo accounts.
- Character switching: rapid switching ends on the last character; a slot request in flight while switching changes only
  its own character.
- Realtime cleanup: joins minus leaves = 2 open channels after any number of switches.
- Raw enums: none in visible text (regex sweep of every tab and DM section).
- Unnamed controls: none. Broken images: none. Console errors: none.
- Hidden data: unidentified item true name and curse are absent from the DOM, browser storage, every player REST response,
  Realtime frames and the exported file.
- Locks: runtime actions keep working, permanent ones are disabled with a reason.
- Inventory metrics update after mutations; coins update without re-rendering the list.
- School-only spell icons. Modals: topmost Escape, focus trap, focus return, body scroll lock.
- Reduced motion; skip link; toast live region.

## FUTURE (needs a future engine, not part of this pass)

- Multiclass hit-dice pools (one pool today).
- Carrying capacity and encumbrance.
- Conditions and concentration engine.
- Companion gameplay sheet.
- Guided level-up wizard.
- A shared picker framework.
