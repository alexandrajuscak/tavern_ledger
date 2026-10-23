# Creature catalog

The `public.creatures` table holds 334 SRD 5.1 creatures, of which 87 are beasts (rows from
`supabase/seed/creatures.sql`). They are used for:
- Wild Shape forms ([WILD_SHAPE_RULES.md](WILD_SHAPE_RULES.md));
- companions and familiars.

The data model is in [CREATURE_DATA_MODEL.md](CREATURE_DATA_MODEL.md), and per-form coverage is in
[WILD_SHAPE_COVERAGE.md](WILD_SHAPE_COVERAGE.md).

## Sources and licensing

| Source | Use |
|---|---|
| SRD 5.1 via dnd5eapi.co (`data/raw/creatures_srd/`, CC-BY-4.0) | the only source of mechanics: size, type, AC, HP, speeds, abilities, saves, skills, senses, defenses, CR, traits and actions |
| `data/creatures/wild_shape_mechanics.json` (project-authored) | short summaries of traits and special actions, trait groups, and curated action effects (Swallow, Web, Whirlwind, Whelm, Ink Cloud…) |
| RPGBOT Wild Shape guide (cached) | discovery only: which beast names exist, their CR section and book. Ratings and opinions are never copied |
| Fandom Beast_Shapes | discovery only; blocked (HTTP 403 / 402), recorded in the fetch manifest |

**Stored:**
- structured mechanics;
- a project-written summary per trait and action.

**Never stored:** the full SRD prose, or any non-SRD text.

Each row carries `source_label`, `source_url` and `license`.

## Pipeline

1. `scripts/data-migration/creatures_fetch.py` fetches the raw SRD JSON (polite and cached).
2. `scripts/data-migration/generate_creature_seed.py` normalizes it into `data/normalized/creatures.json` and
   `supabase/seed/creatures.sql`:
   - attacks: kind, bonus (only on real attacks), reach / range, targets, damage dice and type;
   - save DCs and escape DCs, size limits and conditions;
   - usage: recharge on a roll, or once per rest;
   - multiattack;
   - trait group and summary, plus automation;
   - `mechanics_status` (`complete` / `partial`) with notes for anything unresolved.
3. `scripts/data-migration/wild_shape_coverage.py` writes `data/reports/wild_shape_coverage.json` and
   `docs/WILD_SHAPE_COVERAGE.md`. These cover discovered forms vs the catalog, CR / size / movement / sense
   breakdowns, unavailable non-SRD forms, source conflicts, and printed attack bonuses to check.

The seed is an idempotent upsert. A creature that is referenced by a companion or a transformation is never deleted.

## Coverage summary

| | Count |
|---|---|
| SRD beasts CR 0–6 | 85, all with **complete** mechanics |
| Elementals for Elemental Wild Shape | 4, complete |
| Discovered forms not in the SRD | 13 (unavailable: never fabricated) |
| All creatures with complete mechanics | 146 of 334 |
