# Wild Shape rules (2014 Druid and Circle of the Moon)

These are the rules the engine applies. It implements one rules version only: the 2014-aligned Druid (`druid-phb`) and
the Circle of the Moon (`druid-moon-phb`). The 2024 Wild Shape (known forms, temporary HP instead of a separate pool, PB
uses) is not mixed in. A 2024 Druid would be a separate class version with its own `transform_form` data.

**Sources:**
- Rules: the dnd5e.wikidot.com Druid page.
- Creature mechanics: the SRD 5.1 (CC-BY-4.0).
- Discovery of beast names, CR and book: the RPGBOT Wild Shape guide, for review only. Its ratings are never stored.

Everything below is a project-authored summary.

Implementation:
- `supabase/migrations/20261017001300_wild_shape_engine.sql`;
- the `transform_form` effects in `data/classes/features/druid.json`.

See also [TRANSFORMATION_ENGINE.md](TRANSFORMATION_ENGINE.md) and [WILD_SHAPE_UI.md](WILD_SHAPE_UI.md).

## Uses and duration

| Rule | Engine |
|---|---|
| Wild Shape starts at Druid level 2 with 2 uses | resource `druid-wild-shape-phb-uses`, by Druid **class** level (never total level) |
| Uses return on a short or long rest | resource recharge `short_or_long_rest` |
| Duration: half the Druid level in hours | `duration_hours: "half_class_level"`. The form stores `max_duration_minutes` and `expires_at` |
| Elemental Wild Shape (Moon 10) costs 2 uses | `cost: 2` on the elemental rule. The cost is spent atomically, never half |
| Archdruid (Druid 20): unlimited uses | the resource is `unlimited`, and spending is a no-op |
| Reverting is free | `end_transformation` never spends or refunds a use |
| Duration over | Checked on every read and mutation. The expired form ends, and the mutation returns `result.expired` instead of failing |

## Which forms

Eligibility is decided on the server only (`_form_options`), by Druid class level.

| Druid | Normal Druid max CR | Moon Druid max CR | Swim | Fly |
|---|---|---|---|---|
| 2–3 | 1/4 | 1 (Combat Wild Shape) | no | no |
| 4–7 | 1/2 | 1 (level 6+: Druid level ÷ 3 = 2) | yes | no |
| 8+ | 1 | Druid level ÷ 3 (rounded down) | yes | yes |
| Moon 10+ | — | plus air, earth, fire and water elementals (2 uses) | | |

- Only beasts (and, for Moon 10+, the four elementals) with **complete** structured mechanics can be taken. A form whose
  data is missing is never invented: it is listed as unavailable in [WILD_SHAPE_COVERAGE.md](WILD_SHAPE_COVERAGE.md).
- Every option returns all its reasons at once, for example "CR 2 is above your limit (1/2)", "flying forms from Druid 8"
  or "not marked as seen".

**Seen forms** (the 2014 rule "a beast you have seen"), configured per character:

| Mode | Effect | Who can choose it |
|---|---|---|
| `enforce` | unseen forms are locked | player or DM |
| `warn` (default) | unseen forms are allowed, with a warning in the review | player or DM |
| `unrestricted` | the seen rule is off | **DM only** (an admin, the campaign DM, or the owner of a character outside any campaign) |

**DM grants:**
- A DM can grant a form as an exception (`dm_grant`), which overrides CR, movement and seen limits.
- The player cannot create or remove a grant.
- An import never restores a grant as a grant. It comes back as an ordinary seen form with a note.

## Statistics in a form

The 2014 rule: the form replaces your game statistics, but you keep your alignment, personality, mental abilities,
proficiencies and class features. `_wild_shape_sheet` computes the transformed sheet, and `get_character_derived_stats`
applies it to the whole sheet.

| Statistic | Rule |
|---|---|
| STR, DEX, CON | from the form (substituted in `_derived_stats_core`). The character's scores are never overwritten |
| INT, WIS, CHA | yours |
| Saving throws, skills | The **highest** of three candidates (each is listed): your own bonus (the form's ability modifier + your proficiency); a proficiency printed in the form's stat block, gained with your PB (form mod + your PB); and the form's printed bonus. Expertise counts. Advantage traits (Keen Smell…) are named on the skill |
| Hit points | the form's HP, in a separate pool (below) |
| Armor Class | the form's natural AC. Class `ac_formula` alternatives (for example Unarmored Defense) are listed as alternatives "if the form can use it". Worn armor counts only in **wear** mode, and a worn shield adds +2 |
| Speed, senses | the form's. Passive Perception is recomputed from the form's Perception |
| Size, space | the form's (with a short note on squeezing and carrying) |
| Resistances, immunities, vulnerabilities, condition immunities | the form's, plus yours from features that still apply |
| Attacks | the form's actions with printed bonuses and damage, exactly as the SRD prints them. Primal Strike (Moon 6) marks them magical |
| Spellcasting | cannot cast. Exceptions: Beast Spells (Druid 18) allows spells without costly material components, and Archdruid (Druid 20) ignores V/S and non-costly M components |
| Concentration | continues. The sheet shows a reminder and an "End concentration" button |

**Retained features** are classified and shown, never auto-resolved:

| Status | Meaning |
|---|---|
| `retained` | keeps working (for example a feature with attack or damage riders that a form can use) |
| `retained_if_capable` | AC formulas and similar: only if the form can physically use it |
| `needs_dm` | ambiguous (for example item-like AC bonuses): **not applied**, ask the DM |
| `not_retained` | replaced by the form (for example your senses) |
| `informational` | a reminder only |

## Equipment

The review asks once, with a default from the settings, and allows a choice per item.

| Mode | Effect |
|---|---|
| `merge` (default) | the item merges into the form and has **no** effect until you revert |
| `drop` | the item is unequipped through `unequip_item`. It stays in the inventory and is not re-equipped automatically |
| `wear` | the form wears the item (only if it fits: a DM decision), and its effects apply |

Merged item effects are never applied (`_item_active_in_form` in `_character_effects`). The mode can be changed per
item during the form (`set_transformation_equipment`).

## Hit points

- Form HP is a separate pool with its own temporary HP. Your normal HP is protected and untouched while transformed.
- **Damage:** form temporary HP first, then form HP.
- **At 0 form HP:** the form ends. The excess carries over once, to your normal temporary HP first and then to your HP.
  The history records the events `reverted_zero_hp` and `excess_damage`. Example: Brown Bear at 24 HP takes 30
  damage, so 6 carries over and normal HP goes from 40 to 34.
- **Healing** never exceeds the form maximum. `set_transformation_hp` requires a reason, is limited to 1..max, and is
  recorded in the history.
- **Combat Wild Shape (Moon 2+, beast forms only):** as a bonus action, spend a spell slot to regain 1d8 per slot level.
  The server rolls, or validates a player roll (1..8×level). An impossible roll spends nothing. Pact slots are offered
  only as a table option.
- **Lethal damage:** the UI shows what will happen before applying it (the carry-over and the normal HP after). This
  confirmation can be turned off in the settings.

## Form abilities

- **Recharge on roll** (for example Giant Spider Web, recharge 5–6): Use → used; "Roll recharge (d6)" restores it on
  5–6. The server rolls or validates the roll.
- **Once per rest:** Use → used until a rest.
- **Restore:** a manual correction.
- State is kept per form in `action_state` and cleared when the form ends.
- Nothing is applied to a target automatically: the app shows the hit, DC and conditions.

## Not modeled (by design)

- Forms outside the SRD 5.1. Thirteen discovered forms (dinosaurs, Cow, Cranium Rat…) have no licensed mechanics.
- Swarms.
- Size-based grappling math.
- Automatic target effects.
- Mounting rules.
- Optional or alternative Wild Shape variants (2024, UA, Tasha's Wild Companion as a form). Wild Companion stays the
  existing companion feature, not a transformation.

<!-- 20261019 governance/feats/content -->
## Campaign creatures and governance (20261019)

* A DM-authored creature is a Wild Shape option only after a DM grant (`set_seen_forms(..., 'dm_grant')`); a player can
  never mark a campaign creature as seen ([CUSTOM_CREATURES.md](CUSTOM_CREATURES.md)).
* In a campaign, marking a beast as seen is governed (`runtime.mark_seen_form`, Standard / Strict: approval); loosening the
  seen-form setting from enforce to warn is governed too. Taking, leaving and damaging a form are runtime and stay the
  player's in every preset (unless the character is fully locked).
