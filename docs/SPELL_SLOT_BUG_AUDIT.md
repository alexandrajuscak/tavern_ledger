# Spell slot Use / Restore: bug audit (2026-10-17)

Reported: Use and Restore on standard spell slots and Pact Magic "glitch". Reproduced in Microsoft Edge (Playwright, `msedge`)
against local Supabase, on throwaway users. Every slot RPC, every Realtime frame for the slot tables and the rendered count every
10 to 50 ms after each action were recorded. Scripts and logs are under the session scratchpad (`slots/repro*.py`); the
regression test is `supabase/tests/browser/class_slot_regression_ui_test.py`.

## What the server did

The server was correct throughout:

- `_slot_change` locks the character row, so changes are serialized.
- Every change checks the maximum and the floor, and is logged in `character_resource_events`.
- The event log of the manual session (Showcase Paladin and Local Wizard, clicks 1 to 2 s apart) shows clean, sequential
  before/after values with no double spends.

The visible glitches came from the client, plus one wrong rest result.

## Reproduction (before the fix)

Test characters:

- "Slot Repro": Warlock 2 / Wizard 3, with standard slots 4 × 1st and 2 × 2nd, and Pact Magic 2 × 1st.
- "Slot Repro Pace": Wizard 9.
- "Slot Repro Paladin": Paladin 6 / Warlock 2.

| Scenario | Request / response | Realtime | Rendered | Result |
|---|---|---|---|---|
| single Use, 1st level (4 / 4) | `expend_standard_spell_slot {p_slot_level: 1}` → 200, remaining 3 | INSERT + UPDATE `character_spell_slot_state` | 4 → 3 after ~350 ms; a full class reload (9 RPCs, ~1 s) follows | correct, but no feedback while pending |
| Restore, Pact Use, Pact Restore | correct pool, level and RPC each time | one UPDATE each | correct | correct |
| double click Use | **two** `expend_standard_spell_slot` requests | two UPDATEs | 4 → 3 → 2 | **double spend** |
| three clicks 80 ms apart | three requests; the third → 400 "No level 1 slot left" | | 2 → 1 → 0, error toast | **triple spend, error toast** |
| four Use clicks 400 / 700 / 900 ms apart | 4 correct responses | 4 UPDATEs | `4 → 3 → 2 → 1 → 3 → 0`, `4 → 3 → 2 → 3 → 1 → 2 → 0`, `… 0 → 1 → 0` | **count jumps backwards** |
| same, 1100 ms and more apart | | | monotonic | correct (timing dependent) |
| Restore to the maximum with the keyboard | correct | | Restore becomes disabled | **focus lost to `<body>`** |
| any Use / Restore while "Manual adjust" is open | | | the panel closes, page shrinks by 175 px | **layout jump** |
| Short Rest with 2 expended Pact slots | `short_rest_character` → `restored.pact_slots: 0`, `breakdown.restored: []` | UPDATE pact → 0 | Pact 0 → 2 | **slots restored, but the toast said "Nothing to restore"** |
| Long Rest | `restored.standard_slots: [{restored: 0}]` | | slots back | **summary amounts 0** |
| second open session | | both sessions get the UPDATE | session B follows in ~0.6 s | correct |
| reload, 390 px viewport | | | correct | correct |
| console / network | | | | no errors; only local requests |

## Confirmed root causes

1. **Stale read overwrote a confirmed result.** This caused the backwards jumps.
   - Each slot change sends a Realtime event, which started a full `loadClasses`: 9 RPCs, about 1 s.
   - The Use / Restore action wrote the RPC result into `slotState` but did not invalidate a class reload already in flight.
   - That reload had read the slots before the newer change, finished later, and replaced the newer state with the older one.
   - At a click pace of 0.4 to 0.9 s this happens on every run.
2. **No in-flight guard on slot buttons.** This caused the double and triple spend and the "No level 1 slot left" toast. The
   Use / Restore buttons stayed active while their request ran, and each click sent its own RPC. Class resources (`feature-ui`)
   already had a guard; the slot actions in `sheet.js` did not.
3. **A response for another character was applied.** `slotState = await expend…(C().id)` assigned the result even if the
   player had switched characters meanwhile, so the new sheet showed the previous character's slots until the next refresh.
   This was confirmed with a held response in the regression test (SR13).
4. **Focus loss.** The re-render restored focus only by `data-focus-key`. When Restore became disabled at the maximum, nothing
   received focus.
5. **Re-render closed open panels.** `innerHTML` replacement reset `<details>`, so "Manual adjust" closed after every slot change.
6. **Rest result reported 0.** This is a server bug in `_rest`: `update … set expended = 0 … returning expended` returns the
   value *after* the update. Pact Magic and standard slots were restored correctly but reported as 0, so the rest toast said
   "Nothing to restore". The not-restored list also named class resources that had nothing spent.

## Ruled out

- **Server and data:** wrong pool, wrong slot level, a standard operation hitting Pact Magic, RPC signature mismatch, missing
  state row (it is created on demand), clamping errors, restoring above the maximum (refused by the server).
- **Event handling:** duplicate click handlers or stale DOM handlers (one delegated listener on the sheet root), nested form
  submission, buttons defaulting to submit (all `type="button"`), event bubbling, retries creating duplicates.

## Fixes

### Frontend (`js/sheet.js`, `js/class-ui.js`, `js/feature-ui.js`, `css/styles.css`)

- **One request per slot line.** `slotMutation(key, …)` sends one request per slot line at a time ("standard:1", "pact",
  "temporary:<id>").
  - While it runs, that line's buttons are marked busy with `aria-busy` / `aria-disabled` and `.is-pending`, and further clicks
    are ignored.
  - The buttons are not natively disabled, so keyboard focus stays on them.
  - Other lines stay usable.
- **Server result first.** The RPC result is the new authoritative state. A response is ignored if the character changed or
  a newer response was already applied.
- **`slotEpoch`.** Every slot change bumps the epoch when it is sent and when it is answered. A read (class reload or slots
  reload) that started before, or overlapped, a change keeps the newer slots and schedules a fresh slots-only read.
- **Lighter Realtime refresh.** Events for `character_spell_slot_state` and `character_temporary_spell_slots` re-read only the
  slots (`loadSlots`), not the whole class page. This cuts the race window from about 1 s to one RPC.
- **Shared render helper `putHTML`.** It replaces the two copies of `put()` and:
  - keeps focus on the same `data-focus-key`, or on its `data-focus-alt` when that button is now disabled (Restore at the
    maximum moves focus to Use);
  - keeps `details[data-open-key]` open.
- **Feedback.** A `role="status"` / `aria-live="polite"` line under the tracker announces each confirmed change, for example
  "1st-level slot used. 3 of 4 left." or "Pact Magic slot restored. 2 of 2 left (1st level)".
- **Friendly errors.** Failures show a friendly message, keep the previous authoritative value, and re-read the slots.
- **Rest summary dialog.** After a rest, a "Short Rest completed" or "Long Rest completed" dialog lists:
  - **Restored:** for example "Pact Magic: 2 slots", "Spell slots: 3 slots (2 × level 1, 1 × level 2)", "Second Wind: 1 use",
    and hit points / hit dice on a long rest;
  - **Not restored:** each item with its amount and reason, for example "Standard spell slots: 1 slot still used (only on a
    long rest)";
  - **Ended:** states such as Rage.

### Server: `20261017001000_rest_report_fix.sql`

- `_rest` reads the expended count before the update, so `restored.pact_slots`, `restored.standard_slots[].restored` and the
  breakdown amounts are correct.
- `not_restored` lists a class resource only when some of it is spent, with the amount.
- What a rest restores is unchanged.
- Rollback: `supabase/rollback/rollback_rest_report_fix.sql`, which restores `_rest` from `20261015001800`.

## Regression tests

- **Browser:** `class_slot_regression_ui_test.py`, 20 checks.
  - Basic actions: Use, Restore, the final slot, double click on the final slot (one request), Restore at the maximum (disabled,
    and refused by the server).
  - Pact Magic: Use, Restore, double-spend of the final slot.
  - Rests: Short Rest restores only Pact Magic and the summary lists both lists; Long Rest restores both pools; separate pools
    on a multiclass.
  - Races: a rapid triple click makes one mutation; a late response after a character switch is ignored; Realtime refreshes
    never revert the count and never steal focus; Enter keeps focus.
  - Environment: `type="button"`, a second session, 390 px with no overflow, no browser errors, no remote requests.
- **SQL:** `class_slot_tests.sql` R1b and R3b check the rest result amounts (86 checks). The existing concurrency tests
  (`concurrency_test.sh`, API concurrent spends) are unchanged and pass.
- **Updated tests:** `class_slot_ui_test`, `class_feature_ui_test`, `class_martial_ui_test` and `local_demo_smoke_test` now
  close the rest summary dialog.
