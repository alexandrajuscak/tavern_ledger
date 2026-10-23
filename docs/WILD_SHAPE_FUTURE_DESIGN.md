# Wild Shape: future design (historical)

**Superseded (2026-10-17):** Wild Shape is implemented by migration `20261017000800_creatures_and_transformations.sql`
(creature catalog, transformation rules `transform_form`, form hit points with carry-over) and the Druid data; see
[CLASS_ENGINE_REVIEW.md](CLASS_ENGINE_REVIEW.md). The text below is the earlier design note, kept for history.

Nothing here was implemented at the time of writing. This note checks that the resource engine of migration
`20261015001700` can carry Wild Shape later without a rewrite, and sketches the pieces that are still missing.
Rule references: the Druid page on dnd5e.wikidot.com (2014 PHB version, the current `druid-phb`) and the RPGBot Wild
Shape guide (used only as background, never as mechanics).

## 1. The uses: `character_resources` (ready now)

| Wild Shape rule (druid-phb) | Representation |
|---|---|
| Starts at Druid level 2 | `unlock_level = 2`, `character_class_id` = the Druid row (class level, not total level) |
| Two uses | `max_formula = {"table": [[2, 2], [20, null]], "level": "class"}` |
| Regained on a short or long rest | `recharge = 'short_or_long_rest'` |
| Unlimited uses at 20th level (Archdruid) | the `null` table value → `unlimited: true` |
| Source | `source_type = 'class'`, `source_id = 'druid-phb:wild-shape'` |

This exact row is created and exercised by `supabase/tests/class_slot_tests.sql` (G1-G6): locked at Druid 1, 2 uses at
Druid 2, spent and restored by a short rest, unlimited at Druid 20. Other versions (e.g. a 2024 Druid with
PB-scaled uses) would be a separate class version with its own formula
(`{"terms": [{"of": "proficiency_bonus"}]}`), never a changed formula on the existing one.

## 2. The creature catalog (future)

A versioned `creatures` / `creature_versions` catalog (beasts first) with size, type, CR, speeds (walk / swim / fly /
climb / burrow), AC, HP, ability scores, senses, attacks and source, imported like the spell catalog (cached pages,
deterministic generator, coverage report). No prose is stored.

## 3. Form eligibility (future)

Rules as data on the class (and subclass) version, evaluated on read:

- maximum CR by Druid level (1/4 at 2, 1/2 at 4, 1 at 8; Circle of the Moon overrides: CR 1 at 2, level / 3 from 6),
- movement limits (no swim speed before 4, no fly speed before 8),
- "beasts you have seen" as an optional per-character list.

Output: eligible forms with the reason for each ineligible one, like the spell eligibility checks.

## 4. Transformation state (future)

A separate `character_transformations` row (form version, started at, duration, transformed HP and temp HP, ends on 0
HP / bonus action / duration), independent of the use counter: spending a use and being transformed are two facts.
Derived stats would read the active form (physical abilities, AC, speeds, attacks) while keeping mental scores,
proficiencies and features, in the same layered way lineage effects are applied today.

## 5. What stays out until then

No form list, no CR or movement checks, no transformed HP, no UI. Rests already restore the use counter correctly.
