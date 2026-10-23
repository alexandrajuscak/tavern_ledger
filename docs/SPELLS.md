# Spells

The spell catalog is a normalized, versioned, source-aware list of every spell on dnd5e.wikidot.com, plus a spellbook per
character that is resolved on read from its spellcasting sources. Nothing derived (DC, attack bonus, ritual castability,
lineage spells) is stored on the character.

- Data model: [SPELL_DATA_MODEL.md](SPELL_DATA_MODEL.md)
- Spellcasting sources, DC / attack, known and prepared: [SPELLCASTING_SOURCES.md](SPELLCASTING_SOURCES.md)
- Classes, class versions and class spell lists: [CLASS_FOUNDATION.md](CLASS_FOUNDATION.md)
- Class levels, slots, Pact Magic, rests: [CLASS_LEVELS.md](CLASS_LEVELS.md), [SPELL_SLOTS.md](SPELL_SLOTS.md),
  [RESOURCES_AND_RESTS.md](RESOURCES_AND_RESTS.md)
- Counts and source conflicts: [SPELL_COVERAGE.md](SPELL_COVERAGE.md) (generated)
- Audit before the build: [SPELL_ENGINE_AUDIT.md](SPELL_ENGINE_AUDIT.md)
- Migration: `supabase/migrations/20261015001600_spell_catalog.sql`; seed: `supabase/seed/spells.sql`; rollback:
  `supabase/rollback/rollback_spells.sql`.

## Catalog at a glance

| Count | |
|---|---|
| Canonical spells | 567 |
| Spell versions | 574: 524 official, 50 playtest (Unearthed Arcana); 567 current, 7 legacy |
| Cantrips / levels 1-9 | 49 / 525 |
| Ritual / concentration | 37 / 262 |
| Structured damage / healing / temp HP | 191 / 5 / 5 spells (239 effect rows, 230 damage-type links) |
| Automation | 199 partially automated, 375 informational, 0 automated, 0 unresolved |
| Class spell lists | 9 lists, 1543 entries (Artificer 103) |
| Lineage spell grants linked to the catalog | 137 of 137 |

## Data pipeline (local, offline after the first fetch)

```
python scripts/data-migration/spells_fetch.py          # 1. cache list, ritual, class, school and 574 spell pages in data/raw/spells_html/ (git-ignored)
python scripts/data-migration/spells_normalize.py      # 2. -> data/normalized/spells/{spells,class_lists}.json + data/reports/spell_coverage.json
python scripts/data-migration/generate_spell_seed.py   # 3. -> supabase/seed/spells.sql + data/reports/spell_seed_summary.json (--check: validate only)
python scripts/data-migration/generate_lineage_seed.py # 4. re-link lineage spell grants to spell versions
python scripts/data-migration/spell_coverage.py        # 5. -> docs/SPELL_COVERAGE.md
```

The fetcher is polite (one request at a time, pause, descriptive user agent, cache with resume, stops on throttling) and
never re-downloads a cached page unless `--refresh` is given. Steps 2-5 read only local files and are byte-identical on
re-run. Manual source metadata (books, aliases, settings, the 9 class versions) lives in `data/spells/_reference.json`.

**No rules prose is stored.** A spell keeps its mechanics (level, school, casting time, range, area, components, duration,
concentration, ritual, attack/save, structured dice) and a link to its source page. The UI shows the link for the full text.

## Seed order

`config.toml` loads `reference_data.sql`, `item_effects.sql`, `spells.sql`, then `lineages.sql`. The lineage seed writes
`lineage_trait_effects.spell_version_id`, so the spell seed must load first. Both seeds are idempotent (checksums are
compared by the runners: `supabase/tests/spell_catalog_checksum.sql`, `lineage_catalog_checksum.sql`). The spell seed
upserts by stable id and deletes catalog rows no longer in the data unless a character still uses them.

## Ids

`<slug>-<book>` for official versions (`fireball-phb`, `antagonize-bomt`) and `<slug>-ua` for playtest versions.
The canonical spell (`catalog_spells.id`) is the slug. A UA version superseded by an official printing is `legacy`
with `superseded_by_version_id`; the picker shows current versions first and labels legacy and playtest versions.

## Spells tab

- **Spellcasting** card: one row per source (class preview, subclass, feat, item, manual, other, and the lineage), with
  casting ability, Spell Save DC, Spell Attack Bonus and the breakdown, plus known / prepared / always-prepared counters.
  A class source belongs to a class on the Bio tab (created automatically) and shows its class level, highest spell
  level and cantrip / known / prepared counts with over-limit warnings. A class source that is not linked to a class is
  a *Class Foundation Preview* (no class rules checked).
- **Spellbook** card: filters (search, level, school, source, prepared, ritual, concentration, damage type) and spell
  cards with level, school, components, concentration / ritual markers, grants, DC / attack of the granting source,
  structured damage and the source link. A spell from two sources is one card with both grants.
- **Add Spell**: search the catalog, pick a version, choose the source, known / prepared / always prepared, optional
  casting ability. For a class source the spell level is checked against that class's own level (a multiclass
  character's higher slots never unlock higher class spells).
- **Spell slots**: standard slots and Pact Magic from the classes, with Use / Restore, rests and manual adjust
  ([SPELL_SLOTS.md](SPELL_SLOTS.md)).
- **Free-text spells and slots**: the old manual list stays; its manual slot tracker is shown only for characters
  without class slots.
- **Lineage** card: shows lineage abilities and actions; lineage spells now appear in the Spellbook.

## Export / import

`js/transfer.js` exports `spellcasting.sources` (all stored sources) and `catalogSpells` (each grant with its spell
version id, source key and flags). Import recreates the sources and grants; a spell id that does not exist in the target
catalog becomes a free-text spell so nothing is lost. Lineage grants are not exported (they follow from the lineage).
Schema: `docs/character.schema.json`.

## Supported / not supported in this phase

Supported: catalog with filters, structured damage/healing, class spell lists, sources with per-source DC and attack,
known / prepared / always prepared, ritual castability per source ritual mode, lineage spells in the spellbook,
export/import, read access for the campaign DM, homebrew-ready visibility (`owner_id`, `campaign_id`).

Since migration 1700: class levels, slot progression (single class, multiclass, Artificer, one-third foundation), Pact
Magic, slot use and rests, spell level eligibility per class, the prepared limit (enforced) and cantrips / known limits
(warnings).

Not supported yet: casting automation (slots are used by hand, no rolled damage applied), concentration, subclass
expanded lists, feats as a catalog, Mystic Arcanum, homebrew spell editor (the schema and RLS support it; there is no
write RPC).

<!-- 20261019 governance/feats/content -->
## Campaign spells, feat spells and governance (20261019)

* DM-authored campaign spells are normal `spell_versions` rows visible to campaign members only ([CUSTOM_SPELLS.md](CUSTOM_SPELLS.md)).
* Feat spells (Magic Initiate, Fey Touched …) are materialized into a feat spellcasting source by `_sync_character_feats`.
* In a campaign, learning, removing, spellbook additions, always-prepared and source changes are governed (`spell.*`);
  preparing and unpreparing stay the player's in every preset.
