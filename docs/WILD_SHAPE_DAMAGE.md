# Wild Shape damage and overflow (2026-11-07)

Migration `20261107000200_combat_initiative_wild_shape.sql` (rollback `rollback_combat_initiative_wild_shape.sql`).
Tests: `supabase/tests/wild_shape_damage_tests.sql` (39 checks; 13 of them fail against the previous functions),
`supabase/tests/lock_order_concurrency_test.sh` and `combat_concurrency_test.sh` (parallel form damage),
`supabase/tests/browser/combined_followup_ui_test.py` W1–W4.

## Rules model by version

| Class version | Form HP model | What ends the form | Excess damage |
|---|---|---|---|
| Druid 2014 (`druid-phb`, Circle of the Moon `druid-moon-phb`) — the only Druid in the catalog | separate pool: the form's own HP and its own temporary HP; normal HP and normal temporary HP are protected | form HP 0, Revert (bonus action / manual), the duration (half the Druid level in hours, tracked by wall clock), incapacitation is a manual Revert | carries over once: `excess = max(0, damage − form temporary HP − form HP)`, applied to the normal temporary HP first, then the normal HP |
| Druid 2024 | temporary HP instead of a separate pool | — | **not in the catalog.** `start_transformation` only offers forms to class versions with `transform_form` data, so a 2024 interpretation cannot be applied by mistake; a 2024 Druid would be a separate class version with its own model and tests |

Instant death from massive damage, concentration and resistances of the form are **not automated** (reminders; the
Combat Builder still creates its concentration-save reminder from the incoming damage). Concentration is not ended by the
form ending.

## The defect (root cause)

The formula was already right: a 20 HP form taking 21 damage left normal HP 30 → 29 (reproduced). The real failure was the
**wall-clock duration**: every Wild Shape mutation first ended a form whose `expires_at` had passed, and
`apply_character_hp` (used by the Combat Builder, the sheet's Damage button and the API) then applied the **whole** amount
to the normal HP. The UI still showed the form with its HP. Local evidence: 2026-11-07 19:53:50, Brown Bear form shown with
19 HP, 20 damage from the Combat Builder, normal HP 17 → 0 (expected 16); the combat history recorded `form_ended: true,
carryover: null`. Heals and manual corrections fell through the same way (a correction of the form overwrote the normal HP).
The sheet's own form buttons called `damage_active_transformation` directly and applied the damage nowhere, so the two
screens behaved differently.

## One authoritative policy

| Operation on a form | Duration still running | Duration already over (wall clock) |
|---|---|---|
| damage | form temp HP, then form HP; at 0 the form ends and only the excess reaches normal temp HP, then HP | **the same** (the form the user saw takes it); if the form survives, it then ends because of its duration and normal HP is untouched |
| heal | the form, up to its maximum | nothing is applied; the form ends; result `applied: false` with a clear message ("apply it again to the normal form") |
| temporary HP / manual correction | the form (correction needs a reason) | nothing is applied; the form ends |

All paths use the same server functions in one transaction: the character row is locked first (`_ws_lock`, same lock as
before minus the early expiry), then the form row. Result fields: `amount`, `temp_absorbed`, `form_hp_before`,
`form_hp_after`, `form_hp_used`, `ended`, `reason` (`zero_hp` | `expired`), `carryover`, `normal_hp_before`,
`normal_hp_after`, `normal_temp_absorbed`, `unconscious`, `applied`, `expired`.

Examples (form 20 HP, normal 30): damage 1 → form 19; 19 → form 1; 20 → form ends, normal 30; 21 → normal 29; 25 → 25;
40 → 10; 80 → 0 (unconscious, never negative). With normal temp 4: 23 damage → temp 1, HP 30. Form temp 5: 26 damage → 1 excess.

## Combat Builder

The detail panel shows the form, its HP, the protected normal HP and, when the duration is over, a "Duration over" note. The
damage preview says "the form ends; only the excess 1 reaches normal HP (30 → 29)". After the change: "Brown Bear form took
21 damage. The form ended, and 1 excess damage was applied to Elara (30 → 29 HP)." The history event stores the incoming
damage, form HP used, the excess, the form name, why it ended and the resulting normal HP. Undo of a damage that ended the
form is refused ("The Wild Shape form changed or ended since"); damage the form survived is undone exactly. A heal on an
expired form records no HP event (nothing to undo). Hidden numbers stay DM-only (the player view is unchanged).

## Sheet

The sheet applies the server's `normal_hp_after` immediately (no wait for Realtime, so a later autosave cannot write the old
value back) and announces the same sentence.

## Production

No stored row changes. Read-only reconciliation count for the release: forms present but past their wall-clock duration
(`select count(*) from character_transformations where expires_at < now()`; locally 3 of 4). They stay as they are; the
next damage hits them as shown, the next heal / correction / revert ends them.
