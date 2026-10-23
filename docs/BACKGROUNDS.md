# Backgrounds

Versioned background engine (2026-10-17).

- Migration: `20261017001200_backgrounds.sql`, rollback `supabase/rollback/rollback_backgrounds.sql`.
- Data: `data/backgrounds/backgrounds.json`, seed `supabase/seed/backgrounds.sql`.
- UI: `js/background-ui.js`, `js/background-api.js`.
- Tests: `supabase/tests/classes/background_tests.sql` (26 checks) and `supabase/tests/browser/background_ui_test.py` (20 checks).

## Audit (before)

- **Background:** `characters.background` was free text. Nothing derived from it.
- **Abilities:** the stored base scores, plus lineage and item adjustments in the derived stats.
- **Proficiencies:** manual rows, plus class and lineage grants (see [PROFICIENCY_RESOLUTION.md](PROFICIENCY_RESOLUTION.md)).
- **Equipment:** the inventory and the class starting-equipment flow (`20261017000600`).
- **Feats:** only free-text features (category `feat`) and the class ASI / feat choice. There was no feat catalog.

The free-text field stays, labelled "Background (free text)", for characters without a catalog background.

## Rulesets are never mixed

Every background version is a separate row with an explicit `ruleset`:

| | 2024 (`ruleset = '2024'`) | Legacy (`ruleset = '2014'`) |
|---|---|---|
| Ability scores | three listed abilities: +2 / +1 to two different ones, or +1 to all three | none (they come from the lineage) |
| Feat | one Origin feat (a reference) | none, except the playtest Rune Carver, whose feature grants a UA feat |
| Skills | two | as printed (fixed, or a choice from a list) |
| Tools | one fixed tool, or one of a category | as printed |
| Languages | none | as printed (fixed, any, or a restricted list) |
| Equipment | Package A, or B (50 GP) | the printed package, with its coins |
| Feature | none | a narrative feature (informational) |
| Characteristics | none | personality, ideal, bond, flaw, plus the background's own tables |

The same name in two rulesets would be two versions (for example Acolyte 2024 and Acolyte 2014). The player always picks
the version.

## Imported scope

- **16 × 2024 (Player's Handbook 2024):** Acolyte, Artisan, Charlatan, Criminal, Entertainer, Farmer, Guard, Guide, Hermit,
  Merchant, Noble, Sage, Sailor, Scribe, Soldier, Wayfarer. Source pages are `dnd2024.wikidot.com/background:<name>`.
- **13 legacy / additional** (source pages from `dnd-5e.fandom.com/wiki/<Name>`):

  | Background | Source |
  |---|---|
  | Smuggler | Ghosts of Saltmarsh |
  | Urchin, Outlander, Guild Artisan, Folk Hero | Player's Handbook (also reprinted in Descent into Avernus) |
  | Investigator | Van Richten's Guide |
  | Haunted One | Van Richten's Guide and Curse of Strahd (the same mechanics, so one version with both sources) |
  | Gambler | Acquisitions Incorporated |
  | Far Traveler | Sword Coast Adventurer's Guide |
  | Faceless | Descent into Avernus |
  | Archaeologist, Anthropologist | Tomb of Annihilation |
  | Rune Carver | Unearthed Arcana 2022 "Wonders of the Multiverse": `status = playtest`, DM permission required, hidden unless "Show playtest" is ticked |

- **One printed variant:** Guild Artisan (variant: Guild Merchant), linked with `variant_of`. It trades the artisan's tools
  for navigator's tools or a language, and gets a mule and cart instead of the tools.
- **Normalization:** the request's "Fol Hero" was imported as **Folk Hero**. This is recorded in `requested_as` and in
  `data/reports/backgrounds_source_report.json`.
- **Backlog:** 55 more 2024 backgrounds and 75 Fandom backgrounds are listed in `data/reports/backgrounds_backlog.json`. They
  are not imported.

## Pipeline

1. **`scripts/data-migration/backgrounds_fetch.py`** caches the pages in `data/raw/backgrounds_html/`. It makes one request
   at a time with a pause and a descriptive user agent, keeps a manifest, reuses the cache, and stops on throttling.
   Fandom is tried first; a wikidot fallback is recorded if Fandom refuses.
2. **`backgrounds_extract.py`** writes `data/normalized/backgrounds_extract.json`. It keeps only the mechanical lines, the
   table headings and short entry titles. No flavor prose and no trait, bond or flaw sentences.
3. **`data/backgrounds/backgrounds.json`** is the curated catalog: catalog ids for skills, tools, languages and items,
   choices, packages, and short feature summaries written for this project.
4. **`generate_background_seed.py`** checks every version against its page and stops on any difference:
   - ability list, feat name and parameter;
   - skills, tools and language counts;
   - coins in the equipment line;
   - feature names and table dice;
   - item, skill and language ids.

   It then writes the seed (idempotent, so character choices survive a re-run) and three reports:
   `backgrounds_source_report.json`, `backgrounds_backlog.json` and `feats_backlog.json`.

## Data model

**Catalog** (readable by everyone, written only by the seed):

| Table | What it holds |
|---|---|
| `backgrounds` | one row per background name |
| `background_versions` | ruleset, status, source book, page and URL, `also_in`, `variant_of`, relation note, `requested_as`, DM permission, enabled by default, duplicate rule |
| `background_ability_options` | the three listed abilities (2024 only) |
| `background_proficiency_grants` | fixed skill, tool and language grants |
| `background_choices`, `background_choice_options` | choices with their options expanded (a category becomes its catalog items; "any language" becomes the language list); a choice can be mixed tool or language (Guild Merchant) |
| `feats`, `background_feat_grants` | feat references (category, ruleset, status, summary, source URL, `automation = informational`), with a parameter such as Magic Initiate (Cleric) |
| `background_equipment_packages`, `background_equipment_entries` | packages with coins; entries are a catalog item, the item picked in a choice (`from_choice`), a pick from a category (`category_id`), or a label not in the catalog (kept, never dropped) |
| `background_features`, `background_characteristic_tables` | short summaries (informational); table headings, dice and short entry titles only |

**Character state** (read through `can_access_character`, written only through the RPCs):

| Table | What it holds |
|---|---|
| `character_backgrounds` | version, ability mode and allocation, `bonuses_included`, characteristics (the player's own text or a chosen short title), notes |
| `character_background_choices` | the picked options |
| `character_background_replacements` | duplicated grants replaced by another proficiency of the same kind |
| `character_background_equipment` | what an equipment application added (item ids, coins, noted labels); once per character and version |

Everything else is resolved from the catalog.

## Resolution

- **Ability increases** (`_derived_stats_core`): applied after the lineage, and both together are capped at 20. The stored
  scores never change.
  - The derived abilities report `background_bonus` and `background_applied`, and the Stats tab shows "+2 background".
  - "My stored ability scores already include this background bonus" (`bonuses_included`) keeps the allocation for the
    record but adds nothing (compatibility mode).
- **Skills, tools and languages** (`_background_layer`): they join the derived result as source `background`, labelled with
  the background's name.
  - The proficiency resolver lists them next to class, lineage and manual sources.
  - `_proficiency_match` counts background tools.
  - Expertise validation and the class choice checks accept a background skill.
  - Nothing is copied into manual rows. Changing or removing the background removes only its contribution.
- **Duplicates:** a background grant that another source already gives is reported (`duplicate_grant`, with every source),
  and both sources stay listed. The player can replace a duplicated skill or tool with another of the same kind:
  - **Legacy:** the Player's Handbook 2014 rule.
  - **2024:** the background text doesn't say, so it's a table rule and the UI asks for DM approval.
- **Feats are references:** name, parameter, summary, source link and "not applied automatically yet". They never block the
  background. `data/reports/feats_backlog.json` lists the 11 referenced feats.
- **Legacy features** (City Secrets, Wanderer, Down Low …) are informational summaries. Nothing is turned into a number.

## RPCs

| RPC | What it does |
|---|---|
| `get_background_catalog()` | every version with its grants, choices, feat, features, equipment and tables (for the picker) |
| `get_character_background(character)` | selected version, ruleset, status, source, ability allocation and effective increases (`applied`, capped), grants with origin and duplicates, replacements, feat, features, choices with open state, characteristics, equipment packages and what was applied, warnings (`ability_open`, `ability_capped`, `choice_rule`, `duplicate_grant`, `dm_permission`), duplicate rule |
| `set_character_background(character, version, ability, choices, replacements, options)` | validates everything (listed abilities only, +2 / +1 on different abilities or +1 ×3, no increases for a legacy version, options from the choice, at most the choice count, playtest only with `allow_playtest`) and replaces the selection in one transaction; choices may stay open |
| `clear_character_background(character)` | removes the selection; equipment stays in the inventory |
| `preview_background_equipment(character, package)` | each entry resolved (catalog item, the chosen tool, a pick list, or "not in the catalog"), with already-owned counts and coins |
| `apply_background_equipment(character, package, picks)` | adds the items with `add_inventory_item`, adds the coins, and records the application; once per character and version (a second call is refused) |

## UI (Bio tab, Background card)

- **Empty card:** explains the two rulesets, with **Choose background…**.
- **Picker:**
  - search, a rules filter (2024 / legacy / both) and "Show playtest (DM permission)" (off by default);
  - each entry shows its ruleset, status badges, source and skills;
  - the editor shows only the listed abilities for +2 / +1 (or +1 ×3), the compatibility checkbox, every choice (selects or
    checkbox lists with the count and rules such as "at least one exotic language"), and a DM-permission checkbox for
    playtest versions;
  - server errors stay in the dialog.
- **Card:**
  - name, ruleset and status badges, source with page and link;
  - warnings (with **Replace a duplicate…**) and open choices;
  - ability increases (with "applied: max 20" and "Already in your scores");
  - proficiency chips (with "also <source>" for duplicates);
  - the feat reference, the informational feature;
  - starting equipment: **Review starting equipment…**, or what was added;
  - personal characteristics: free text per table, **Roll dN** (a short title is filled in when the table has them;
    otherwise the number is shown to look up in the source);
  - **Change or edit…** and **Remove background**.
- **After choosing a new background,** the equipment review is offered and nothing is added without confirmation. The review
  shows items, quantities, the picked tool, picks for "any gaming set", labels that are not in the catalog (noted only),
  items already owned, and the coins.
- **Export / import:** the export carries `backgroundVersion` (version, ability allocation, `bonusesIncluded`, choices as
  `kind:id`, replacements, characteristics, notes, `dmApproved`), and the import re-applies it. The schema is in
  `docs/character.schema.json`.
- **Realtime:** a background change in another session refreshes the card and the derived stats.

## Known limits

- **Feats are not automated:** Alert's initiative, Tough's hit points, Skilled's three proficiencies and so on are shown as
  references.
- **Some equipment isn't in the catalog** (a mirror, a small knife, trinkets, letters, the monster hunter's pack). These are
  kept as noted labels, so add a custom item to track them.
- **Characteristic tables** keep short titles only where the source has them (Smuggler's claims to fame and ideals). Other
  tables offer a roll and free text.
- **The backlog is not imported.**

<!-- 20261019 governance/feats/content -->
## Feats and governance (20261019)

The background-era `feats` table is now `feat_versions` (same ids; `background_feat_grants.feat_id` unchanged) and the
Origin feat of a 2024 background is a real feat grant (`bg:<version>`) with effects, choices and resources
([FEATS.md](FEATS.md)). Changing the background removes only that grant. In a campaign, setting or clearing a background
and applying its equipment are governed (`build.background`); DMs can author campaign backgrounds
([CUSTOM_CONTENT_LIFECYCLE.md](CUSTOM_CONTENT_LIFECYCLE.md)).
