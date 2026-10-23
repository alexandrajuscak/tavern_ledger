# Spell engine: audit (before migration 20261015001600)

Scope: everything that stores, emits, imports, exports or displays spells, and what a spell catalog plus a minimal
class foundation must connect to. Findings only; the result is described in [SPELLS.md](SPELLS.md).

## Tables

| Table | What it holds | Catalog link |
|---|---|---|
| `spells` (base schema) | one free-text row per character spell: `name`, `level`, `school` (text), `casting_time`, `range`, `components` (text), `duration`, `concentration`, `ritual`, `attack_type`, `save_ability`, `damage` (text), `damage_type` (text), `description`, `prepared`, `source` (text) | **none**: no catalog id, no version, the school and damage type are free text |
| `spell_slots` (base schema) | per character and slot level `total` / `used`; created for levels 1–9 with every character; set by hand or by the level-up dialog | no progression; a manual counter that already works |
| `characters.spellcasting_ability` | one global ability for the whole character | a single DC/attack for all spells |
| `lineage_trait_effects` (`effect_type = 'spell'`) | lineage grants: `value_text` = spell name, `data.slug`, `uses`, `recharge`, `cast_level`, `ability` or `ability_choice`, `notes`, `min_level` | **slug only** (no foreign key); 130 rows across 47 lineages |
| `damage_types` | 13 normalized damage types | reusable for spell damage |
| `source_books`, `data_sources` | publication and dataset provenance (item catalog + lineage seed) | reusable for spells |
| `feature_trackers`, `features` | generic resources / free-text features | not spell-aware |

No class table exists: `characters.class_name` / `subclass` / `level` are free text and a number. `profBonus(level)`
in the browser and `(level - 1) / 4 + 2` in `get_character_derived_stats` agree. Effective ability scores (lineage +
items) come from `get_character_derived_stats -> abilities` (the browser adds the same delta to the stored score).

## Frontend

| Module | Spell behaviour |
|---|---|
| `js/sheet.js` | Spells tab: global spellcasting ability select, one Spell save DC / Spell attack tile (`8 + PB + mod`, `PB + mod`), slot manager, free-text spell cards grouped by level (`spellViewHTML`, `spellEditHTML`, `addSpell`), spell notes; Combat tab lists free-text spells by casting time; attacks with ability `spell` use the global ability |
| `js/lineage-ui.js` | `lineageSpellsHTML(derived)`: "Lineage spells & abilities" card from `derived.lineage_spells` (name, uses, recharge, DC, attack) |
| `js/levelup.js` | sets `spell_slots.total` by hand |
| `js/transfer.js` | export `spellcasting: {ability, slots}` and `spells: [...]` (free-text fields); import inserts free-text `spells` rows and slot totals |
| `docs/character.schema.json` | `spells` items with free-text fields; no catalog ids |

## Lineage integration today

`get_character_derived_stats` returns `lineage_spells` with unlock level, uses, recharge, cast level and the
spellcasting ability (fixed or chosen), and computes DC / attack from that ability. The spell itself is only a name and
a slug; nothing checks that it exists. A catalog must give these grants a real reference while keeping the lineage
metadata (unlock level, uses, recharge, ability, free casts, "can also use slots" notes).

## Legacy data

Free-text `spells` rows stay valid: they are user data without catalog identity (names may be misspelled, homebrew or
from other sources). They are kept as "Other spells (free text)" and are never deleted or silently matched.

## Minimum class dependency

Class spell lists need a class identity and an explicit class version (same philosophy as lineage versions); a
character spellcasting source needs a casting ability, preparation mode, ritual mode and an optional spell-list
reference. No class progression, features or subclasses are required for that.

## Migration requirements

- new tables only, plus a nullable `spell_version_id` on `lineage_trait_effects` (set by the lineage seed);
- the spell seed must load **before** the lineage seed (foreign key), and neither seed may be required by the migration;
- `get_character_derived_stats` stays unchanged (its `lineage_spells` keeps working); the new spellbook RPC is separate;
- rollback must drop only the spell objects and the new lineage column.

## Content-source ambiguities (found before import)

- The index marks UA spells with "(UA)" in the name and Dunamancy/Graviturgy/Chronurgy/Technomagic with a letter after
  the school (D, DG, DC, T); these are source markers, not schools.
- Ritual status comes from a `R` marker on the index, a separate ritual page and the "(ritual)" note on the spell page.
- Class membership is on separate class pages and again in the "Spell Lists" line of each spell page; they can differ.
- Spell pages contain the full copyrighted rules text. Decision: the application stores mechanics, short structured
  values and the source link, not the prose (same as lineages and items); snapshots stay in a local, git-ignored cache.

## Recommended scope

Catalog (canonical spell + version), schools, rituals, concentration, components, casting time, range/area, duration,
reliably parsed damage/healing/save/attack data with an automation status, class identities + versions + spell lists
(all nine class pages if they validate), character spellcasting sources, character spell grants, lineage grants linked to
the catalog, one spellbook RPC with per-source DC and attack bonus, a slot-progression schema without speculative data,
a Spells tab with catalog browsing, and JSON export/import of the new data. No casting, slot consumption, class
progression, Pact Magic, multiclass slots or full homebrew editor.
