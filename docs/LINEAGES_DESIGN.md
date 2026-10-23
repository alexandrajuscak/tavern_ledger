# Character lineages: analysis and design

Status: implemented in migration `20261015001500_character_lineages.sql` (this was the Phase 1 design; the sections still describe the result). Coverage per lineage:
[LINEAGE_COVERAGE.md](LINEAGE_COVERAGE.md). User and developer guide: [LINEAGES.md](LINEAGES.md).

## 1. Existing architecture (what lineages plug into)

| Concern | Today |
|---|---|
| Race | `characters.race` free text (Bio tab "Race" field). Nothing reads it except the sheet subtitle and JSON export. |
| Ability scores | `characters.strength … charisma` (1–30), entered by the user. `get_character_derived_stats` already derives effective scores (item overrides/bonuses) without writing them back; the browser still computes modifiers from the stored scores. |
| Size, senses, languages, resistances | Not modeled. Languages live in the free text `characters.proficiencies`. |
| Speed | `characters.speed` (base, user-entered). Derived speed = base + item effects − armor Strength penalty. |
| Skills / saves | `skill_proficiencies` / `save_proficiencies` jsonb, calculated in the browser; the server adds item bonuses and (dis)advantage flags. |
| Weapon/armor/tool proficiencies | `character_proficiencies` (group or item, `source_type`), the only write path is `set_character_proficiency`; mirrored into the legacy `equipment_proficiencies` flags by triggers. |
| Effects | `item_effects` (catalog) and `item_modifier_effects` (instances), resolved by `_character_effects` with activation and stacking. |
| Derived stats | `get_character_derived_stats(character)` (SECURITY INVOKER, RLS) returns one jsonb; the sheet re-reads it after relevant changes and on Realtime. |
| Level | `characters.level` (1–20), used for the proficiency bonus: reliable enough to gate lineage traits. |
| Seeds | Hand-maintained or generated SQL in `supabase/seed/`, loaded by `config.toml [db.seed]`; data pipeline = JSON in `data/` + stdlib Python generator (`scripts/data-migration/`), byte-identical, idempotent. |
| Security | Catalog tables: `select` for anon/authenticated. Character data: `can_access_character` (owner, campaign DM, admin). Writes through SECURITY DEFINER RPCs with explicit checks. |
| Local workflow | `start-local.bat` → `scripts/start-local.ps1` (Docker + Supabase CLI + frontend on 127.0.0.1:5173); tests in `supabase/tests/run_*.sh`. |

## 2. Data model

Catalog (read-only for users, written only by the seed):

```
lineage_categories   standard | exotic | monstrous | custom                     (rows created by the migration)
lineages             id (slug), category_id, name, source_url, summary
lineage_versions     id, lineage_id, parent_version_id (null = base version), kind base|subrace|variant,
                     name, source_book_id, source_label, source_url, status current|legacy,
                     setting (null | Eberron | Wildemount | Ravnica | Theros), is_optional,
                     superseded_by_version_id, requires_child, replaces_all_parent_traits,
                     creature_type, summary, interpretation_note
lineage_traits       id, version_id, slug, name, summary (own words), automation, min_level,
                     uses ('pb' | n | null), recharge, sort_order, interpretation_note
lineage_trait_replacements   (trait_id, replaced_trait_id)      child or option replaces a parent trait
lineage_choices      id, version_id, trait_id, kind, label, pick_count, required, min_level,
                     parent_option (choice_id, option_id) for sub-choices, config jsonb, changeable
lineage_choice_options       (choice_id, option_id), label, summary, data jsonb, sort_order
lineage_option_replacements  (choice_id, option_id, replaced_trait_id)
lineage_trait_effects        (trait_id, seq), effect_type, target, value, value_text, min_level,
                     choice_id (value comes from a choice), option (choice_id, option_id) (only if chosen),
                     conditions jsonb, data jsonb
skills, languages    lookups (skills by the migration, languages by the seed)
```

Character state (normalized selections, nothing resolved is stored):

```
character_lineages        character_id (PK), lineage_id, version_id, subversion_id,
                          ability_bonuses_included, updated_at, updated_by
character_lineage_choices (character_id, choice_id, pick) -> value text
```

## 3. Versions and sources

Every published stat block is its own `lineage_versions` row with its own source book, label and URL. Nothing is
merged across books. `status`:

- `current`: the latest official stat block of that line (PHB 2014 races; Monsters of the Multiverse; Fizban's
  dragonborn; single-source lineages).
- `legacy`: an older official stat block that a later book replaced (Volo's, Tome of Foes, Elemental Evil, SCAG,
  Witchlight, The Tortle Package where MotM reprints the lineage). `superseded_by_version_id` points at the MotM version.

`setting` marks setting-specific versions on in-scope pages (Eberron dragonmarks, Wildemount, Ravnica, Theros);
`is_optional` marks DM-permission options (SCAG Variant Tiefling, Extra Life supplements). There is no
"newest wins" rule: the user picks a version; the picker shows current versions first and labels the rest.

Out of scope (recorded in the coverage matrix, not seeded): Plane Shift sections, Unearthed Arcana sections, the
Spelljammer Astral Elf on the Elf page, and all separately listed setting-specific lineages.

## 4. Parents, subraces, variants

A base version may have children (`parent_version_id`). A character selects one base version and at most one child.
`requires_child` forces a choice (PHB Elf, Dwarf, Gnome, Halfling, Volo's Aasimar, Eberron Shifter). Resolution:

1. effective traits = base traits − traits replaced by the child − traits replaced by chosen options + child traits;
2. `replaces_all_parent_traits` (dragonmarks that restate the whole block, e.g. Mark of Finding) drops every base trait;
3. a child cannot be selected without its parent, nor with another parent (checked by the RPC and a trigger).

## 5. Traits and choices

A trait is a named rule with a short own-words summary and an explicit `automation` label:

| Label | Meaning |
|---|---|
| `automatic` | every mechanical part is applied by the engine |
| `partial` | the engine computes something (uses, DC, unlock level, listed advantage) but the rule itself is played at the table |
| `informational` | shown only |
| `unresolved` | shown while a required choice of the trait is missing (computed, not stored) |

Choice kinds: `ability_scores` (patterns like `[[2,1],[1,1,1]]`, allowed/excluded abilities), `size`, `skill`,
`language`, `tool`, `weapon`, `skill_or_tool`, `spellcasting_ability`, `option` (enumerated options carrying effects
and replacements), `spell` and `feat` (free text, externally managed until spell/feat catalogs exist). `pick_count`,
`required`, `min_level` (e.g. MotM Aasimar revelation at 3rd level), sub-choices (an option enables another choice:
Custom Lineage "skill" → which skill) and `changeable` (Eladrin season, Githyanki Astral Knowledge) are data.

## 6. Applied automatically now

Ability score increases; size (fixed, chosen, level-gated: Verdan); walking/climbing/swimming/flying/burrowing speed
(including "equal to walking speed" and "not in medium or heavy armor"); dwarven "not slowed by heavy armor";
darkvision and other senses (best range wins); skill, weapon, armor, tool proficiencies; languages; damage
resistances and immunities; condition immunities; natural armor (both rules: "use if better than armor" and "armor
gives no benefit"); natural weapons (to-hit and damage); initiative bonus (Harengon); creature type.

## 7. Displayed, partly computed or informational

Partial: innate spells (unlock level, uses, recharge, ability, cast level are shown; casting is not automated),
limited-use actions (uses = number or proficiency bonus, recharge, save DC and level-scaled damage are computed:
breath weapons, Healing Hands …), saving-throw and check advantages (listed with their scope), hit point bonus per
level (Hill Dwarf: computed and shown, `hp_max` stays user-entered), Powerful Build (shown; no carrying system yet).
Informational: rerolls (Lucky), movement rules (Nimble), telepathy, breathing, trance, d4 dragonmark bonuses,
reach, shapechanging, "Spells of the Mark" lists, and everything else that needs table judgment.

## 8. Integration with derived stats

`get_character_derived_stats` stays the single entry point. A new resolver `_lineage_resolved(character)` returns
the effective traits, choices and effects; the derived function folds them in:

| Property | Rule |
|---|---|
| Ability score | `stored base` → `+ lineage bonus` (not above 20, never lowers; skipped when `ability_bonuses_included`) → item override (highest, never lowers) → item bonuses → max 30 |
| AC | best applicable base formula: unarmored, worn armor, natural armor (`best_of`), or natural armor alone (`replaces_armor`, armor ignored + warning); then shield and AC bonuses; manual override last |
| Walking speed | lineage walking speed (highest applicable) replaces `characters.speed` when a lineage is selected; then item bonuses/penalties and the armor Strength penalty (skipped for heavy armor when the lineage says so) |
| Other speeds | highest of each mode; "equal to walking speed" uses the final walking speed; armor conditions make a mode inactive with a reason |
| Size | chosen or fixed; a higher `min_level` size replaces a lower one (Verdan) |
| Senses | highest range per sense |
| Proficiencies, languages, resistances | union of all origins, each entry lists its sources |
| Advantages, spells, actions | lists with sources, unlock level and status |

## 9. Lineage and inventory effects together

They are separate layers with one fixed order (section 8), so equipping or attuning items never changes lineage
results and vice versa, except where the rules connect them (armor vs natural armor, armor vs flight, heavy armor vs
dwarven speed, ability scores feeding AC and attacks). Future class, feat and spell effects get their own layer between
lineage and items, using the same effect vocabulary.

## 10. Characters without a lineage

No `character_lineages` row = exactly today's behaviour: stored speed, no size/senses, no lineage effects. The
`race` free text is kept and shown as "Legacy race text" until a lineage is chosen. All existing derived-stats tests
must still pass unchanged.

## 11. Custom Lineage

A normal `lineage_versions` row (category `custom`) whose traits are all choices: size (Small/Medium), +2 to one
ability (`ability_scores` pattern `[[2]]`), feat (free text, unresolved until filled, ready for a future feat
catalog), variable trait (`option`: darkvision 60 ft, or skill proficiency → sub-choice of a skill), language (one
besides Common). Walking speed 30 and creature type Humanoid are fixed. The sheet lists every missing choice.

## 12. Migration and rollback

One forward migration, `20261015001500_character_lineages.sql`: tables, lookups needed by the migration itself
(categories, skills) inserted with `on conflict do nothing`, no reference to seeded rows, triggers, RLS, RPCs,
resolver, and new versions of `get_character_derived_stats` and `_proficiency_match`. Runners expect 16 migrations.
`supabase/rollback/rollback_lineages.sql` removes only this feature and restores the 20261015001400 function
bodies; `rollback_inventory.sql` runs the same drops first. Rollback deletes lineage selections only.

## 13. Seed

`data/lineages/*.json` (one file per lineage, plus `_reference.json` for languages and source books), generated into
`supabase/seed/lineages.sql` by `scripts/data-migration/generate_lineage_seed.py`, which validates every reference and
label before writing. The SQL upserts by stable ids and deletes stale catalog rows that no character uses. Running it
twice changes nothing (checked by an md5 of the catalog tables in the runner).

## 14. API

| Call | Purpose |
|---|---|
| `v_lineage_catalog` (view) | browse/search: lineage, category, version count, sources |
| `get_lineage_detail(lineage)` | versions, children, traits, effects, choices and options in one call |
| `set_character_lineage(character, version, subversion, choices, ability_bonuses_included, require_complete)` | validated replace of the whole selection; incomplete is allowed unless `require_complete` |
| `clear_character_lineage(character)` | remove the lineage and its choices only |
| `get_character_lineage(character)` | resolved traits with automation labels, choices with status |
| `get_character_derived_stats(character)` | now includes lineage results |

## 15. UI

Bio tab: a Lineage card replaces the free-text Race field (the old text stays visible until replaced). "Choose
lineage…" opens a guided dialog: category chips + search → lineage → version cards (source, status, setting) → child
(if any) → choices → summary. The card shows traits grouped with automation badges, unresolved choices, Change and
Remove. Stats, Combat and Spells show what the lineage adds (size, senses, speeds, languages, resistances, skill
dots, natural weapons, innate spells). One generic renderer per choice kind; no lineage-specific code.

## 16. Tests

SQL (`supabase/tests/lineage_tests.sql`): catalog integrity, inheritance, replacement, choice validation, assignment,
change, removal, multiple proficiency origins, derived values, no double ability bonuses, RLS. API: lineage section
in `api_contract_test.py`. Browser: `lineage_ui_test.py`. Runners: seed twice (md5), rollback of the feature, full
rollback, clean reset, legacy path. All existing suites re-run.

## 17. Risks and ambiguities

- Dragonmarks that restate a full block (Mark of Finding) are modeled as replacing all parent traits; other marks
  replace only the Ability Score Increase (and what they restate). Interpretation, recorded per version.
- Wildemount Draconblood/Ravenite replace Draconic Ancestry, Breath Weapon and Damage Resistance (the page lists
  only the new traits).
- SCAG Duergar is a dwarf subrace in print but a full stat block on the page; the page structure is followed.
- The source page has typos (Lizardfolk MotM bite listed as slashing); values follow the page and are flagged.
- Existing characters' scores usually already include racial bonuses: the `ability_bonuses_included` switch (asked
  in the picker) prevents double counting.
- "Language you and your DM agree on": chosen from the languages lookup; nothing is enforced beyond that.
- Breath weapon area/save details and other prose stay informational.
