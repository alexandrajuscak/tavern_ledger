# V6 product hardening: review (2026-10-22)

This is a local-only pass. No backend, migration, RLS, governance or calculation code changed. Issues are listed in
docs/V6_PRODUCT_HARDENING_AUDIT.md, and measurements in docs/V6_PERFORMANCE_REVIEW.md.

## Outcome

- **Issues:** 20 audited in total (0 blockers, 8 serious, 8 moderate, 3 polish, plus 6 future items).
  - Fixed: all 8 serious, 6 moderate and 1 polish.
  - Not fixed: one moderate is deferred and one is documented; two polish items turned out to be correct already.
- **Visual design:** the restored original look (Cinzel, gold headings, vitals, ability cards, metric cards) is unchanged.
- **Main improvements:**
  - no wrong numbers on Home;
  - plain-language errors, and no endless retries;
  - no external request at all;
  - correct heading order everywhere;
  - touch targets ≥ 24 px;
  - dialogs take focus;
  - fewer reads on every character open and a faster Home;
  - a deterministic demo smoke test;
  - a cross-feature hardening suite (51 checks).

## Player experience

- **Home:** cards never flash the stored legacy AC or base maximum. They show "…" until the authoritative values arrive
  (35 cards complete in ~1.3 s instead of 2.7 s). Urgent states (Wild Shape, Locked, waiting / returned requests) stay on
  the cards; search appears with more than six characters.
- **Vitals:** current HP cannot be typed above the authoritative maximum; hit dice are limited to the level. "Down",
  "Critical" and "Bloodied" are written in words. Damage and Heal are double-click safe. The collapse handle and the AC
  shield are easy targets on phones.
- **Abilities:** skill and save marks keep their look with a 32 px hit area. Inspiration, passives and the six cards are
  unchanged and tested again.
- **Play and Spells:** action-card titles are h3 under their section h2. A double click on Use spends one slot.
  Switching characters while a slot request is in flight changes only the original character.
- **Inventory:** equipping armour elsewhere updates the AC through Realtime.
- **Build:** a build lock now says "Your DM has locked the build: levels and other permanent changes wait until it is
  unlocked." Runtime play keeps working. Next steps appear once each.
- **Bio:** the export holds no hidden DM data (verified with an unidentified, cursed item).
- **Wild Shape:** form HP primary, form abilities, Revert (its confirmation now takes focus).
- **Approvals:** "Request level up" for governed characters, and an open request is shown as waiting. The full
  submit / return / revise / approve round trip stays covered by `dm_space_ui_test.py`.
- **Mobile:** no page-level overflow on any tab at 1366, 820, 390 or 360. Long button labels wrap below 420 px.

## DM experience

- Every DM Space section has a section h2 above its cards (the selected tab's name), so card headings never skip a level.
- Campaign rules fits a 360 px phone.
- "Needs you" lists the pending request first, and zero counters stay muted.
- Party, Content, Assign, Hidden and Audit behave as before (covered by the DM Space suite, 50 checks).

## Visual consistency

- **Headings:** card titles in Play, Build (background, lineage) and Wild Shape now sit at the correct level and keep their
  look.
- **Typography, gold rule and surfaces:** unchanged from the restoration.
- **Toasts:** at most three; identical messages are not stacked; errors stay longer.
- **Loading:** Home cards show loading marks instead of wrong numbers.

## Accessibility

- **Keyboard:** collapse, skill marks, Inspiration, dialogs and Escape (topmost only) verified by the suites (A11, A27,
  X3, V15).
- **Focus:** confirmation dialogs take focus; focus returns to the opener.
- **Headings:** no skipped level on any tab or DM section at any tested width (X1, X1b–d, DM2).
- **Labels:** every visible control has an accessible name (X2).
- **Touch targets:** ≥ 24 px on phones (X6a, X6b).
- **Reduced motion:** transitions off (X5).
- **Contrast:** gold `#d4a64a` is 7.9 : 1 on the section surface and 6.9 : 1 on cards. Secondary text is ≥ 6.5 : 1 and tertiary text ≥ 4.7 : 1 on every surface.

## Reliability

- **Stale responses:** sequence guards hold under rapid switching (Z2) and a switch during a pending slot request (Z1).
- **Duplicate actions:** a double click on Heal or Use applies once (V3, S2).
- **Permanent save errors:** reported once, not retried (Z7, Z7b).
- **Realtime cleanup:** open channels = 2 after many switches (Z6).
- **Session length:** no leaked sheet DOM after 24 in-page mounts (heap snapshot).
- **Fixture drift:** `local_demo_smoke_test.py` sets its own state and restores the exact rows (24 / 24, and the
  fingerprints are identical afterwards).
- **Test allowlists:** nine test files no longer allow CDN or Google hosts.

## Security

- **Hidden data:** an unidentified ring with a curse. The player's DOM, local and session storage, every REST response,
  every Realtime frame and the exported file contain neither the true name nor the curse (SEC1–SEC3, plus DM Space DS15).
- **No backend change:** no RLS or read-model change was needed.
- **Hosted services:** never contacted. With supabase-js self-hosted, the browser makes no external request at all (NET1).

## Manual scenarios

| Scenario | Executed as | Result |
|---|---|---|
| Player (sign in, vitals, damage / heal, Inspiration, abilities, skill source, Play resource, prepare spell, slot, equip, coins, feat, request, Druid transform / damage / heal / revert, export, sign out) | `v6_product_hardening_ui_test.py`, `original_ui_test.py`, `spell_ui_test.py`, `wild_shape_ui_test.py`, `dm_space_ui_test.py`, plus the read-only audit probe | all steps pass |
| DM (Needs you, party, return a request, approve a request, custom spell draft → validate → preview → publish → assign, hidden item reveal, campaign rule, audit log, archive with the assignment kept) | `dm_space_ui_test.py` (50) and DM steps of the hardening suite | all steps pass |
| Mobile (390 / 360) | hardening suite R1, X6b, DM3; `original_ui_test.py` phone section | pass |
| Two-session Realtime | hardening I2 (API change → open sheet), `dm_space_ui_test.py` (player ↔ DM), `wild_shape_ui_test.py` Realtime | pass (I2 once slow, see limitations) |

## Data incident during this pass (resolved)

The first run of the reworked `local_demo_smoke_test.py` failed in its restore step. Some tables have
`GENERATED ALWAYS` identity columns, so a plain insert is refused. Three demo characters (Local Hero, Local Wizard, Local
Warlock) were left with the test's changes: a long and a short rest, slot changes, and two Arrows events.

Recovery, using the task-start backup (checksum verified):
1. Their rows were loaded from the dump into a scratch schema and swapped back in one transaction.
2. The two test inventory events were deleted.
3. The scratch schema was dropped.

All 42 fingerprint rows were identical again, and no table holds rows newer than the backup. The helper now uses
`OVERRIDING SYSTEM VALUE`, also covers inventory-keyed tables, and is dry-run with a rollback before use. Every later run
left the fingerprints identical.

## Test results

- `v6_product_hardening_ui_test.py`: 51 / 51.
  - Of the 5 runs with its final fixtures, one had a single I2 Realtime timeout: not reproducible, 10 / 10 in a dedicated
    loop.
  - Final run, after the lock-wording change: 51 / 51.
- Complete browser suite (once, sequential): **27 suites, 844 checks, 0 failed**. Afterwards the hardening suite (51) and
  the UX suite (29) were run again for the lock-wording change.
- Separately run changed files: `local_demo_smoke_test.py` 24 / 24 and `local_dev_smoke_test.py` 21 / 21.
- After the last code change (`defer` on the vendored script in `index.html`): the hardening suite 51 / 51 and
  `original_ui_test.py` 116 / 116 were run again. The fingerprints were identical afterwards.
- Backend suites: not run (no backend change).
- Persistence: a synthetic character's HP 23 and temp 7 survived `supabase stop` / `start` (volumes kept). It was removed
  afterwards.
