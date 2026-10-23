# Class resources

Part of the class feature engine ([CLASS_FEATURE_ENGINE.md](CLASS_FEATURE_ENGINE.md)). Generic limited-use resources for
future class features: Second Wind, Action Surge, Indomitable, Rage, Bardic Inspiration, Channel Divinity, Ki / Focus,
Sorcery Points, Wild Shape uses, Lay on Hands, Superiority Dice, Arcane Recovery, limited feature spells.

## Definition (`class_feature_resources`)

| Column | Meaning |
|---|---|
| `feature_version_id` | the granting feature (active feature → resource active) |
| `name`, `resource_type` | `uses`, `points`, `dice`, `pool` |
| `max_formula` | structured formula (below); `null` = not calculable (must not be `automated`) |
| `die`, `die_by_level` | fixed die or `[[level, "d8"], ...]` |
| `recharge` | `short_rest`, `long_rest`, `short_or_long_rest`, `dawn`, `manual`, `none` |
| `short_rest_recovery` | partial recovery on a short rest for a long-rest resource (formula) |
| `min_level` | class level at which the resource starts (the feature may come earlier) |
| `option_choice_id` / `option_id` | only while an option is chosen ("select a resource option") |
| `activation_note`, `automation`, `notes` | |

## Maximum formulas (no executable expressions)

The 1700 formula language (`_resource_max`), validated when a definition is written:

- `{"fixed": n}`
- `{"table": [[level, value | null], ...], "level": "class" | "total"}` — counts that grow at given levels; `null` =
  unlimited from that level
- `{"terms": [{"of": "fixed", "value": n} | {"of": "proficiency_bonus"} | {"of": "ability", "ability": "cha"} |
  {"of": "class_level" | "total_level", "multiplier": m, "divisor": d, "rounding": "up"}], "minimum": n}` — class level,
  half class level, PB, ability modifier (minimum 1), class level × 5

A formula that is not supported cannot be stored; such a feature stays informational / partially automated.

## State

Stored per class row in `character_resources` (`feature_resource_id`, `character_class_id`): `expended`,
`temporary_bonus` (extra uses until the next long rest), `max_adjustment` (−20 … 20, e.g. a DM ruling),
`last_recovered_at`. The maximum is derived on read:

```
max       = max(base maximum + max_adjustment, 0) + temporary_bonus
remaining = max(max - expended, 0)
```

A level increase exposes the new capacity at once; after a level decrease the stored expended value is kept and the
remaining value is clamped at 0. A state row exists only after the first change.

## Operations

| RPC | Effect |
|---|---|
| `get_character_resources(character)` | class resources (active + inactive with state) and manual resources, with keys |
| `expend_character_resource(character, key, amount = 1, reason)` | refuses when inactive, not granted, or not enough left |
| `restore_character_resource(character, key, amount = 1, reason)` | refuses below 0 used |
| `set_character_resource_state(character, key, expended, reason, temporary_bonus?, max_adjustment?)` | manual correction; reason required; event `manual_set` |

Keys: `f:<class row id>:<resource id>` (class) or `r:<resource uuid>` (manual). Every operation authorizes with
`auth.uid()`, locks the character row (two simultaneous requests for the last use: one succeeds, the other waits and is
refused), writes `character_resource_events` (with `feature_resource_id`) and returns the new state. The old
manual-resource RPCs refuse to change class resource rows; direct table writes are not granted.

## Rests

Same RPCs as before (`short_rest_character`, `long_rest_character`, idempotent by rest id):

- **Short rest**: `short_rest` and `short_or_long_rest` resources; the `short_rest_recovery` part of long-rest resources.
- **Long rest**: `short_rest`, `long_rest`, `short_or_long_rest`; temporary bonuses end.
- `dawn`, `manual`, `none` and inactive resources are not restored and are listed.

The result keeps the 1700 keys and adds `breakdown.restored` (`Pact Magic: 2 slots`, `Test Surge: 1`, partial flags) and
`breakdown.not_restored` (`Standard spell slots` on a short rest, long-rest resources, dawn / manual resources). Hit points
are handled by the app's existing long-rest step, unchanged.

## UI

Resources tab → "Class resources": one generic component per resource (name, source feature, remaining / max with pips,
die, recovery rule, automation, inactive reason, "maximum cannot be calculated" warning, Use / Restore). Buttons are
disabled while a request runs and when nothing is left. Active class resources also appear in the resource strip under
the header. The rest dialog lists which class resources a rest restores.
