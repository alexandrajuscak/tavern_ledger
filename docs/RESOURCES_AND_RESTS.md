# Resources and rests

Migration `20261015001700_class_levels_and_slots.sql`. A generic resource foundation for future class features, plus
explicit short and long rests that restore slots and resources in one transaction.

## Generic resources (`character_resources`)

| Field | |
|---|---|
| `resource_key`, `name` | unique per character |
| `source_type`, `source_id`, `character_class_id` | class, subclass, lineage, feat, item, manual, other; a class resource is removed with its class |
| `max_formula` | `{"fixed": n}`, or `{"table": [[level, value or null = unlimited], ...], "level": "class" or "total"}`, or `{"terms": [...]}` with `fixed`, `proficiency_bonus`, `ability` (modifier), `class_level`, `total_level`, each with optional `multiplier`, `divisor`, `rounding`; plus `minimum` |
| `die` | e.g. `d6` (Bardic Inspiration, Superiority Dice) |
| `recharge` | `short_rest`, `long_rest`, `short_or_long_rest`, `dawn`, `manual`, `none` |
| `unlock_level` | below it the resource is locked (class level for class resources, else total level) |
| `spell_version_id`, `cast_level` | free casts of a specific spell (Mystic Arcanum, Signature Spells, lineage casts) |
| `expended`, `active`, `notes` | runtime usage; maximums are always derived |

RPCs: `save_character_resource(character, resource)` (known fields only; a forged `character_id` is refused; the formula
is validated), `change_character_resource(resource, delta, reason)` (never below zero remaining; locked or inactive
resources refused; event logged), `delete_character_resource(resource)`. Resources appear in
`get_character_class_summary().resources` with `max`, `unlimited`, `remaining` and `unlocked`.

Tested shapes: Wild Shape (`table` 2 at Druid 2, unlimited at 20; short or long rest), a PB-based count, an ability-based
count with a die, a "5 × class level" pool, a fixed dawn resource. **No class feature uses the engine yet**; there is
no resource UI besides the summary (the existing Resources tab trackers keep working).

The older `feature_trackers` (free-form trackers on the Resources tab) stay as they are and are restored by the rests.

## Rests

`short_rest_character(character, rest_id)` and `long_rest_character(character, rest_id)`: one transaction, character
row locked, one `short_rest` / `long_rest` event with the details. A `rest_id` makes a retried request safe: the same id
is applied once (the second call returns `already_applied: true`).

| | Short rest | Long rest |
|---|---|---|
| Pact Magic slots | restored | restored |
| Standard spell slots | — | restored |
| Resources `short_rest`, `short_or_long_rest` | restored | restored |
| Resources `long_rest` | — | restored |
| Resources `dawn`, `manual`, `none` | — | — (left to the player) |
| Trackers (`feature_trackers`) | `reset_on = short` | `short` and `long` |
| Manual (legacy) spell slots | — | restored |
| Temporary spell slots | those expiring on a short rest are removed | all expiring on a rest are removed |
| HP, temp HP, death saves, hit dice | — | the app's existing long-rest step (unchanged): HP to max, temp HP 0, death saves reset, half the hit dice back |
| Conditions, prepared spells, concentration | — | not changed |

The confirmation dialog lists exactly this before the rest is taken.

## Not in this phase

Spending hit dice on a short rest, exhaustion, conditions, concentration, Arcane Recovery, Natural Recovery, Font of
Magic, preparing spells during a long rest, dawn recharge automation.

## Class resources and rests (20261015001800)

Class resources are defined in the feature catalog (`class_feature_resources`) and their state lives in
`character_resources` rows with `feature_resource_id`; see [CLASS_RESOURCES.md](CLASS_RESOURCES.md). `_rest` restores them
by their catalog recharge (`short_rest`, `long_rest`, `short_or_long_rest`, partial short-rest recovery; `dawn`, `manual`,
`none` and inactive resources are not restored) and returns `breakdown.restored` / `breakdown.not_restored` next to the
1700 keys. Manual `character_resources` rows keep working as before and are now visible on the Resources tab ("Class
resources" card) with Use / Restore. New RPCs: `get_character_resources`, `expend_character_resource`,
`restore_character_resource`, `set_character_resource_state`. (This file is the "REST_AND_RESOURCES" document.)

## Wild Shape (20261017001300)

- **Spending:** `start_transformation` spends the form's cost through `expend_character_resource` inside the same locked
  transaction: 1 use for a beast, 2 for an elemental, nothing at Archdruid (unlimited).
- **Reverting:** this never spends or refunds a use.
- **Rests:** short and long rests restore the uses as before. They do not end an active form; the duration does.
- **Combat Wild Shape:** spends one spell slot through `_slot_change`. An impossible player roll spends nothing.
- **Once-per-rest form abilities** are kept per form in `action_state` and cleared when the form ends.

See [WILD_SHAPE_RULES.md](WILD_SHAPE_RULES.md).
