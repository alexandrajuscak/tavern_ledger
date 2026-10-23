# Armor Class

AC is calculated by `get_character_derived_stats` ([DERIVED_CHARACTER_STATS.md](DERIVED_CHARACTER_STATS.md)) from
what the character has equipped. Rules: D&D 5e 2014 / SRD 5.1.

## Calculation

Exactly one base formula, then additive bonuses:

| `base_formula` | When | Base |
|---|---|---|
| `unarmored` | nothing in the `armor` slot, or the armor has no `armor_stats` | 10 + DEX modifier |
| `light_armor` | `dex_modifier_mode = full` | armor `base_ac` + DEX modifier |
| `medium_armor` | `dex_modifier_mode = capped` | armor `base_ac` + min(DEX modifier, `dex_cap`) (2 in the catalog) |
| `heavy_armor` | `dex_modifier_mode = none` | armor `base_ac` |
| `natural_armor` | the lineage has natural armor and it is the best applicable formula | lineage base (+ DEX if the trait says so) |

Lineage natural armor ([LINEAGES.md](LINEAGES.md)) comes in two modes: `best_of` (Lizardfolk 13 + DEX, Locathah 12 + DEX)
is used instead of worn armor when it gives a higher AC; `replaces_armor` (Tortle 17, DEX ignored) is always used and worn
armor gives no benefit (warning `lineage_armor_no_benefit`). A shield and AC bonuses still apply. The unused formulas are
listed in `alternatives`.

Then, added on top:

- the shield in the `shield` slot: its `ac_bonus` (+2 for a plain Shield);
- every applied global `ac_bonus` effect: catalog `item_effects` (Ring/Cloak of Protection, Bracers of Defense) and
  instance modifiers (`armor-plus-1`, `shield-plus-2` …), subject to activation, conditions and stacking.

Armor stats come from the item itself, or else from its `base_item_id` (so a homebrew or magic variant of Chain Mail
uses Chain Mail's numbers). The DEX modifier uses the derived DEX score, after ability overrides and bonuses.

Examples (DEX 18, modifier +4):

| Equipment | AC |
|---|---|
| none | 10 + 4 = 14 |
| Leather | 11 + 4 = 15 |
| Half Plate | 15 + 2 (capped) = 17 |
| Chain Mail + Shield | 16 + 2 = 18 |
| Chain Mail +1, Shield, Ring of Protection (attuned) | 16 + 1 + 2 + 1 = 20 |
| Bracers of Defense (attuned), no armor | 10 + 4 + 2 = 16; with armor or shield the bracers show as inactive |

## Value shown on the sheet

`armor_class.value = ac_override ?? calculated`.

| Field | Meaning |
|---|---|
| `calculated` | the result of the rules above |
| `override` | `characters.ac_override` (nullable, 0–50): an explicit manual AC for sources the app does not model (Unarmored Defense, natural armor, Mage Armor …). Set and cleared in the AC breakdown dialog. |
| `source` | `override` or `calculated` |
| `legacy_stored` | the old `characters.ac` column. It is kept but no longer used; the dialog shows it as "Previously entered AC" when it differs. |
| `breakdown[]` | one entry per part: `source_type` (`rule`, `ability`, `armor`, `shield`, `item_effect`, `modifier`), `source_name`, `effect`, `value` |
| `alternatives[]` | formulas that were considered and not used, e.g. unarmored while armor is worn |
| `inactive_effects[]` | AC effects that exist but don't apply, with `inactive_reason` |

Not proficient with the armor or shield? It still counts for AC. The consequences are reported separately in
`armor_consequences` and `warnings` (disadvantage on STR/DEX checks, saves and attacks; no spellcasting).

## UI

The AC tile in the Combat tab is a button. It opens the breakdown dialog: the formula, each part with its source
(linked to the item in the inventory), inactive effects, grouped warnings and the manual override. A short warning
line appears on the tile when the armor causes a problem.

## Known gaps

- 62 named magic armors and shields (Sentinel Shield, Mithral Armor …) have no `armor_stats` and no `base_item_id`.
  They produce `armor_stats_unknown` and AC falls back to unarmored. Use the override until the data is filled in.
- Class features, feats and spells that change the base formula are not modeled.
