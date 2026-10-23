# Transformation engine

**Implementation:**
- Migration: `supabase/migrations/20261017001300_wild_shape_engine.sql`.
- Rollback: `supabase/rollback/rollback_wild_shape_engine.sql`. It restores the earlier transformation RPCs, keeps
  characters and form rows, and drops the new tables and columns.

**Related docs:** rules in [WILD_SHAPE_RULES.md](WILD_SHAPE_RULES.md), data in
[CREATURE_DATA_MODEL.md](CREATURE_DATA_MODEL.md), UI in [WILD_SHAPE_UI.md](WILD_SHAPE_UI.md).

## Principles

- **Server-authoritative.** Every mutation:
  - is SECURITY DEFINER with `search_path = public, pg_temp`;
  - checks `auth.uid()` through `can_access_character`, the project-wide rule: owner, admin or campaign DM (and `_acts_as_dm`
    for DM-only actions);
  - locks the character row (`_lock_for_wild_shape`).
- **The client never supplies trusted values.** Form max HP, ability scores, attack bonuses, carry-over, eligibility,
  cost and duration all come from the catalog and the class data. Unknown `p_options` keys are ignored.
- **Character scores are never overwritten.** The form is a layer that is computed on read.
- **Expiry is durable.** `_lock_for_wild_shape` returns `true` when it has just ended an expired form. The mutation then
  returns the state with `result.expired` instead of raising, so the ending is not rolled back.
- **Every change writes a history event** (`_wild_shape_event`).

## Read path

```
get_character_derived_stats(c) = _wild_shape_layer(c, _derived_stats_full(c))
  _derived_stats_core: STR/DEX/CON := form scores when _active_form(c) is set (form_score, form_name keys)
  _character_effects: item effects only when _item_active_in_form (worn in the form, or no form)
  _wild_shape_layer: AC, speed, senses, saves/skills form_total, form weapons only, resistances, + wild_shape sheet
get_character_transformation(c) → { active (+ sheet), druid_level, total_level, moon, settings, resources, rules,
                                    options[] (status, allowed, reasons, cost, elemental, favorite, last_used, duration), events }
```

- `_form_options(c)` decides eligibility (per creature: CR, type, swim, fly, mechanics, seen, DM grant, status, reasons).
- `_wild_shape_sheet(c, d)` builds the transformed sheet:
  - hp, duration, abilities with their source;
  - saves and skills with their candidates;
  - AC options, speed, senses, size;
  - defenses, actions (with `available`), traits;
  - retained features, equipment, spellcasting, concentration, Primal Strike.

## Mutations (RPCs)

| RPC | Effect |
|---|---|
| `start_transformation(c, creature, options)` | Validates `allowed` and that no form is active. Applies the equipment mode (drop → `unequip_item`). Spends the cost via `expend_character_resource` (unlimited = no-op). Snapshots normal HP, sets the duration and writes `transformed` |
| `damage_active_transformation(c, amount, note)` | Form temporary HP, then form HP. At 0 the form ends and the excess carries over once (normal temporary HP, then HP). Writes `damaged`, plus `reverted_zero_hp` and `excess_damage` when the form ends. Returns `result` |
| `heal_active_transformation(c, amount, note)` | Heals up to the form maximum |
| `set_transformation_hp(c, hp, temp, reason)` | A correction: 1..max, reason required |
| `end_transformation(c, reason)` | Reverts. No use is spent; dropped items are not re-equipped |
| `combat_wild_shape_heal(c, slot_level, pool, roll)` | Moon 2+, beast forms only. Spends the slot through `_slot_change`; the server rolls or validates the roll |
| `use_form_ability(c, ability, use / roll / restore, roll)` | Recharge and once-per-rest state in `action_state` |
| `set_seen_forms`, `set_form_favorite`, `set_wild_shape_settings`, `set_transformation_equipment` | Seen forms, grants (DM only), favorites, settings (unrestricted = DM), equipment merge / wear |
| `change_transformation_hp(c, delta)` | A compatibility wrapper for the earlier API |

## Concurrency

All mutations take the same character lock. `supabase/tests/wild_shape_concurrency_test.sh` checks four races:
1. the final use spent once;
2. concurrent lethal damage carrying over once;
3. revert vs lethal damage, with a single ending;
4. heal vs damage, applied in order with one slot spent.

## Tests

| Suite | Checks |
|---|---|
| `supabase/tests/classes/wild_shape_tests.sql` (SQL) | 52 |
| `supabase/tests/wild_shape_concurrency_test.sh` | 4 |
| `supabase/tests/api/wild_shape_api_test.py` (API / RLS) | 31 |
| `supabase/tests/browser/wild_shape_ui_test.py` | 74 |
| `supabase/tests/browser/class_druid_ui_test.py` | 14 |
