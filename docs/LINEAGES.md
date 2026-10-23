# Character lineages

Lineages (races) are a versioned, source-aware catalog plus a normalized selection per character. Every effect is
resolved on read, so nothing derived is stored on the character and removing a lineage leaves no residue.
Design and rationale: [LINEAGES_DESIGN.md](LINEAGES_DESIGN.md). Per-lineage coverage: [LINEAGE_COVERAGE.md](LINEAGE_COVERAGE.md).
Migration: `supabase/migrations/20261015001500_character_lineages.sql`.

## Catalog

| Count | |
|---|---|
| Lineages | 47: Standard 9, Custom 1, Exotic 26, Monstrous 11 |
| Versions | 133: 88 base versions + 45 sub-lineages/variants; 89 current, 44 legacy; 30 setting-specific |
| Traits | 839: 570 applied automatically, 154 partly automated, 115 informational |
| Choices / options / effects | 169 / 134 / 1042 |

Numbers come from `data/reports/lineage_seed_summary.json` (written by the generator).

### Versions and sources

Each published stat block is a `lineage_versions` row: source book (`source_books`), source label, source URL, `status`
`current` or `legacy` (with `superseded_by_version_id`), `setting` (Eberron, Wildemount, Ravnica, Theros) and
`is_optional` (DM-permission options such as Variant Human, SCAG Variant Tiefling, Extra Life supplements). Nothing
newer silently wins; the picker lists current versions first and labels legacy, setting and optional versions.

### Sub-lineages and inheritance

A base version can have children (`kind` `subrace` or `variant`); `requires_child` forces one. The effective traits are:

1. all base traits,
2. minus traits a child replaces (`lineage_trait_replacements`; `replaces_all_parent_traits` drops every base trait),
3. minus traits a chosen option replaces (`lineage_option_replacements`, e.g. Feral replaces CHA +2),
4. plus the child's traits.

### Traits, effects and choices

A trait has a short own-words summary, `automation` (`automatic`, `partial`, `informational`), optional `min_level`,
`uses` (`pb`, a number, `at_will`) and `recharge`. Effects (`lineage_trait_effects`) are typed rows:

| Effect | Applied as |
|---|---|
| `ability_bonus` | added to the stored base score (never above 20, never lowers; skipped when "already included") |
| `size` | the size; the highest `min_level` wins (Verdan: Small, Medium from 5th) |
| `speed` | `walk` replaces the stored base speed; other modes take the best value; `value_text = 'walk'` = equal to walking speed; `conditions.not_armor` disables a mode in that armor |
| `ignore_heavy_armor_speed_penalty` | heavy armor with an unmet Strength requirement does not slow you |
| `sense` | darkvision etc.; the best range wins |
| `proficiency` | skill, weapon, armor, tool or group; matched by `_proficiency_match` as origin `lineage` |
| `language`, `resistance`, `immunity`, `condition_immunity` | lists with sources |
| `natural_armor` | `best_of` (Lizardfolk, Locathah) or `replaces_armor` (Tortle) base AC formula |
| `natural_weapon` | unarmed strike: STR + proficiency bonus to hit, dice + STR damage |
| `initiative_bonus` | number or proficiency bonus (Harengon) |
| `save_advantage`, `check_advantage` | listed with their scope (roll them yourself) |
| `spell` | name, stable slug, unlock level, uses, recharge, cast level, ability (fixed or chosen), `spell_version_id` (catalog link; 137/137 linked): shown in the Spellbook with DC and attack bonus |
| `limited_use` | uses (number or PB), recharge, save DC, level-scaled dice, damage type from a chosen option |
| `hp_per_level`, `carrying_capacity` | reported, not applied to stored values |

An effect can take its value from a choice (`choice_id`: chosen skills, languages, ability increases, size) or apply only
when an option is chosen (`option_choice_id`/`option_id`). Choice kinds: `ability_scores` (patterns such as
`[[2,1],[1,1,1]]`, excluded abilities), `size`, `skill`, `language`, `tool`, `weapon`, `skill_or_tool`,
`spellcasting_ability`, `option`, `spell` and `feat` (free text until catalogs exist). Choices have `pick_count`,
`required`, `min_level`, `changeable` and can be sub-choices of an option.

### Automation labels on the sheet

`Applied automatically`, `Partly automated`, `Information only`, and `Choice needed` when a required choice of the trait
is missing (or `From level N` while locked). Nothing is hidden: informational traits are listed with their summary.

## Calculation order (derived stats)

1. stored character values (base ability scores, base speed);
2. lineage: ability increases, walking speed, size, senses, speeds, natural armor, proficiencies, languages, resistances;
3. items: ability overrides and bonuses, armor and shield, AC/speed effects (unchanged from before);
4. manual overrides: the AC override.

Future class, feat and spell effects go between 2 and 3 with the same effect vocabulary.

### Ability scores (no double counting)

The stored scores are **base** scores and are never changed by a lineage. The effective score is
`base + lineage increase` (capped at 20, never lowered) and then the item layer. Characters whose entered scores already
include their racial bonuses tick **"My entered ability scores already include this lineage's increases"** in the
picker (`ability_bonuses_included`); the bonuses are then shown but not added. The Stats tab shows `+2 lineage = 16`
under each affected score.

### Proficiencies and origins

Lineage proficiencies are not copied into `character_proficiencies` (that would also flip the legacy sheet checkboxes).
They are resolved from the selection and merged in `_proficiency_match` and the derived `proficiencies` list with
`source_type = 'lineage'`. Consequences: changing or removing a lineage removes exactly its grants; a manual
proficiency of the same group or item stays effective; with both origins the manual row is reported first. Skill
proficiencies from the lineage show as a dashed proficiency dot ("Proficient (from your lineage)") and count in the
skill bonus; the manual dots stay what the user set.

## Custom Lineage

Size Small or Medium, walking speed 30, +2 to one ability, a feat (free text, shown as open until filled),
a variable trait (darkvision 60 ft, or a skill as a sub-choice) and Common + one language. Missing choices are listed
on the card and in the picker; saving with open choices is allowed after a confirmation.

## API

| Call | Notes |
|---|---|
| `v_lineage_catalog` | id, name, category, version/sub-lineage counts, sources, `search_text` (includes sub-lineage names) |
| `get_lineage_detail(p_lineage)` | all versions, children, traits, effects, choices, options, replacements |
| `get_character_lineage(p_character)` | resolved selection: traits with automation and status, choices with status (`complete`, `missing`, `later`, `optional`, `disabled`), replaced traits, effects |
| `set_character_lineage(p_character, p_version, p_subversion, p_choices, p_ability_bonuses_included, p_require_complete)` | replaces the whole selection; invalid values → 22023 with a readable message; incomplete is saved unless `p_require_complete` |
| `clear_character_lineage(p_character)` | removes the lineage and its choices only |
| `get_character_derived_stats(p_character)` | new keys: `lineage`, `size`, `creature_type`, `senses`, `languages`, `resistances`, `immunities`, `condition_immunities`, `advantages`, `natural_weapons`, `lineage_spells`, `lineage_actions`, `initiative`, `hit_points`, `carrying_capacity`, `speed.movement`, `speed.base_source`, per-ability `lineage_bonus/lineage_applied/lineage_sources`, per-skill `lineage_proficient` |

Frontend: `js/lineage-api.js` (data access) and `js/lineage-ui.js` (card, picker, Stats/Spells summaries).
Security: the catalog is readable by everyone and written only by the seed; selections are readable through
`can_access_character` (owner, campaign DM, admin) and written only by the two SECURITY DEFINER RPCs.

## UI

- **Bio tab → Lineage card**: lineage, version and source links, badges (current/legacy, setting, creature type),
  open choices with **Complete choices…**, chosen values, traits grouped by automation, **Change…** and **Remove**. Without
  a lineage the old free-text race stays visible and editable.
- **Picker** (modal; bottom sheet on phones): category chips with counts, search (also by sub-lineage name) →
  published version cards (source, status, setting, "Replaced by …") → sub-lineage cards → choices (one renderer per
  choice kind) → trait preview with automation badges and replaced traits struck through → save.
- **Stats tab**: "From your lineage" (size, creature type, speeds, senses, languages, resistances, immunities,
  initiative, HP bonus, carrying capacity, advantages), ability notes, lineage skill dots.
- **Combat tab**: the speed tile notes lineage speed and other movement modes; natural weapons appear under
  "Equipped weapons".
- **Spells tab**: lineage spells appear in the Spellbook as an innate source (unlock level, uses, recharge, DC and attack
  bonus, see [SPELLS.md](SPELLS.md)); the lineage card lists the remaining abilities and actions.
- **JSON export/import**: `race` holds the lineage name and `lineage` the structured selection; import re-applies it
  (an unknown version keeps only the race text).

## Seed format and adding a lineage

Data: `data/lineages/<lineage-id>.json` (one per lineage), `data/lineages/_reference.json` (languages, missing source
books, shared trait templates such as `@asi-flexible`, `@languages-plus-one`, `@darkvision:60`, `@spell-ability:<trait>`),
`data/lineages/_coverage.json` (research notes for the matrix). Effects use a compact notation, e.g.
`"ability:dex:2"`, `"ability:choice:asi"`, `"speed:fly:walk"`, `"sense:darkvision:60"`, `"prof:skill:perception"`,
`"prof:group:light-armor"`, `"lang:common"`, `"resist:fire"`, `"save_adv:poison"`, `"init:pb"`, `"size:medium@5"`;
objects for `spell`, `limited_use`, `natural_armor`, `natural_weapon` and conditional speeds.

To add a lineage (or a version):

1. add or edit `data/lineages/<id>.json` (stable ids: `<lineage>-<book>` for versions, `<version>:<slug>` for traits
   and choices are derived automatically; never rename an id that characters may use);
2. `python scripts/data-migration/generate_lineage_seed.py` (validates every reference; writes `supabase/seed/lineages.sql`
   and the summary); `--check` validates and fails if the SQL is stale;
3. `python scripts/data-migration/lineage_coverage.py` (regenerates the coverage matrix);
4. load it locally: `Get-Content supabase\seed\lineages.sql -Raw | docker exec -i supabase_db_tavern_ledger psql -U postgres -q`
   (idempotent) or `reset-local`;
5. run the tests (below). No frontend change is needed.

Stale catalog rows are deleted by the seed unless a character still uses them.

## Testing

| Layer | File | Checks |
|---|---|---|
| SQL | `supabase/tests/lineage_tests.sql` | catalog integrity, inheritance, replacement, choices, assignment, change/removal, proficiency origins, derived values, ability caps, RLS, representative lineages, whole-catalog sweep |
| Seed | runners | lineage seed loaded twice → identical checksum (`supabase/tests/lineage_catalog_checksum.sql`) |
| API | `supabase/tests/api/api_contract_test.py` (`lineage_section`) | catalog, search, detail, assign, invalid combos, choices, strict mode, DM access, RLS, direct writes, removal |
| Browser | `supabase/tests/browser/lineage_ui_test.py` | browse, search, versions/sources, required sub-lineage, incomplete choices, sub-choices, derived values, refresh, export, phone width, removal |

Runners: `run_supabase_local.sh` (also the feature-only rollback → derived tests on the restored functions → re-apply),
`run_local.sh` (plain PostgreSQL), `run_browser_local.sh`.

## Rollback

`supabase/rollback/rollback_lineages.sql` removes only this feature: it restores `get_character_derived_stats` and
`_proficiency_match` exactly as migration 20261015001400 defined them and drops every lineage table, view, function,
trigger and policy (lineage selections are deleted; all other data stays; source books added by the seed stay).
`rollback_inventory.sql` drops the same objects first.

## Known limitations

- No class or feat engine: feats and chosen cantrips are free text. Lineage spells are linked to the spell catalog and
  listed in the Spellbook, not cast or tracked.
- Situational rules (Lucky, Nimble, Savage Attacks, shifting benefits, Shell Defense, temporary flight) are informational.
- Rotating proficiencies (MotM Trance, Githyanki Astral Knowledge) are not tracked.
- Hit point bonuses (Dwarven Toughness) and carrying capacity are reported, not applied to stored values.
- Save/check advantages are listed, not applied to rolls (the app does not roll dice).
- Strength penalties (Volo's kobold) are not representable (only +1 to +3) and are noted in the coverage matrix.
- Out of scope: separately listed setting lineages, Plane Shift and Unearthed Arcana sections.

<!-- 20261019 governance/feats/content -->
## Feats and governance (20261019)

A lineage feat choice (Variant Human, Custom Lineage) uses the feat picker; the value `feat:<version>` becomes a feat grant
`lin:<choice>:<pick>` with the lineage as source. Changing the lineage removes only that feat. In a campaign, setting or
clearing a lineage is governed (`build.lineage`); DMs can author campaign lineages
([CUSTOM_CONTENT_LIFECYCLE.md](CUSTOM_CONTENT_LIFECYCLE.md)).

## New characters and legacy race (2026-10-22)

- New characters choose their lineage in the new-character dialog (step 2 and 3), with the same picker and RPC as Build. There
  is no free-text Race field any more. The picker can be embedded (`openLineagePicker({ host, saveButton, onStep })`), opened
  on a given lineage (`open`), shows the campaign content policy for each version (`campaignId`; legacy, setting-specific and
  custom versions are marked and disabled for players when the campaign excludes them; the server enforces it) and opens the
  first result on Enter in the search.
- Old characters with race text and no lineage show "Legacy race has not been mapped to a Lineage". When the text equals one
  catalog lineage name exactly, **Review <lineage>…** opens the picker on it; otherwise the player chooses. The text is kept in
  a folded "Legacy race text" detail and never grants mechanics. Details: `docs/CHARACTER_CREATION_AUDIT.md`.
- Export: `lineage` has `lineageId`, exact `version`, `subversion`, `choices`, `name`, `versionLabel`; `race` only when the
  character has real legacy text. Import applies the exact version; anything it cannot apply is kept as legacy text with a
  warning.
