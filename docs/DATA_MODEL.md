# Data model

Tavern Ledger stores **source-of-truth data only**. The app calculates everything else whenever it's displayed:

| Shown on the sheet | Calculated from |
|---|---|
| Ability modifier | `floor((score − 10) / 2)` |
| Proficiency bonus | level: `ceil(level / 4) + 1` |
| Saving throw bonus | ability mod + proficiency bonus if `savingThrows.X.proficient` |
| Skill bonus | ability mod + proficiency bonus × (0, 1, or 2 if `expertise`) |
| Passive Perception / Insight / Investigation | 10 + the skill bonus |
| Initiative | DEX mod + `combat.initiativeBonus` (misc. only) |
| Weapon to-hit | ability mod (STR, DEX, best of both, or spellcasting) + proficiency if proficient + magic bonus |
| Weapon damage | dice + ability mod (if `addModifier`) + magic bonus |
| Spell save DC / spell attack | 8 + proficiency + casting mod / proficiency + casting mod |

Not stored: skill bonuses, save bonuses, passive scores, attack bonuses and initiative values.
AC and speed *are* stored. They depend on armor, shields and class features (e.g. Unarmored Defense) that the app deliberately doesn't automate.

## Character JSON (import / export)

- Schema: [`character.schema.json`](character.schema.json) (JSON Schema 2020-12).
- Character files: keep them in `examples/` locally. That folder is in `.gitignore`, so real characters are never pushed to the public repo.
- **Export:** sheet → **Bio** tab → *Download JSON*.
- **Import:** character list → *Import JSON*. The importer also accepts the older hand-written format: `"class": {"name", "level"}`, plain feature strings, and `weapons` instead of `attacks`. Numbers stored as skill bonuses in that format are ignored, because they were derived values.

Key shapes:

```json
"skills":       { "stealth": { "proficient": true, "expertise": false } },
"savingThrows": { "dex": { "proficient": true } },
"features":     [{ "name": "Shield Master", "type": "Bonus Action", "source": "feat", "description": "…" }],
"spells":       [{ "name": "Shield", "level": 1, "castingTime": "1 reaction", "description": "+5 AC until the start of your next turn" }],
"resources":    [{ "name": "Ki", "current": 2, "max": 2, "reset": "short" }],
"conditions":   ["Prone", "Hexed"],
"notes":        { "character": "…", "session": "…", "campaign": "…" }
```

## How the Combat tab groups things

| Group | Contains |
|---|---|
| **Attacks** | Rows from `attacks` |
| **Actions** | Features with `type: Action`, and spells whose casting time contains "action" |
| **Bonus Actions** | Features with `type: Bonus Action`, and spells cast as "1 bonus action" |
| **Reactions** | Features with `type: Reaction`, and spells cast as "1 reaction" |
| **Passive Features** | Features with `type: Passive` (collapsed) |

Spells with longer casting times (1 minute, 10 minutes, rituals…) appear only on the Spells tab.

## Database (Supabase)

| Table | Notes |
|---|---|
| `profiles` | role `player` / `dm` |
| `characters` | identity, HP, AC (`ac` is the legacy manual value; `ac_override` is the explicit manual override, see [ARMOR_CLASS.md](ARMOR_CLASS.md)), base speed, ability scores, `save_proficiencies` `{"str": true}`, `skill_proficiencies` `{"stealth": {"proficient": true, "expertise": false}}`, `equipment_proficiencies` (legacy mirror of `character_proficiencies`: `light`, `medium`, `heavy`, `shields`, `simple`, `martial`, `firearms`), `conditions` (jsonb array), `portrait_url` |
| `features` | `category` (source: racial, class, background, feat, custom, magic_item) and `activation` (passive, action, bonus_action, reaction) |
| `attacks` | weapons and attacks |
| `spells` | lightweight spell entries |
| `feature_trackers` | generic resources |
| `spell_slots` | levels 1–9 |
| `inventory_items` | items |
| `notes` | one row per kind: `character`, `session`, `campaign`, `spells`, `attacks` (other combat notes) |
| Storage bucket `portraits` | `portraits/<character_id>/<file>.jpg`, public read; only the owner or the DM can write |

## Migrations

`supabase/schema.sql` is idempotent and contains every migration. Re-run the whole file in the SQL Editor **before** deploying new code. The v3 section:

1. Adds `characters.conditions` and `characters.portrait_url`.
2. Adds `features.activation` (default `passive`) and allows the `background` source.
3. Renames note kind `quest` → `session` (existing Quest Log text is kept as Session Notes).
4. Converts `skill_proficiencies` from numbers (`0/1/2`) to `{proficient, expertise}` objects.
5. Creates the `portraits` storage bucket and its access policies.

## Campaigns and permissions (v4)

| Who | Sees | Can change |
|---|---|---|
| **Admin** (`profiles.role = 'admin'`) | everything | everything: campaigns, members, roles, all characters |
| **Campaign DM** (`campaign_members.role = 'dm'`) | every character in their campaigns, and the names of the people in them | those characters (incl. level ups, owner); the campaign's name/description |
| **Player** (`campaign_members.role = 'player'`) | their own characters, and the names of people in their campaigns | their own characters; may move them between campaigns they belong to |

- `campaigns(id, name, description, created_by)`
- `campaign_members(campaign_id, user_id, role)`: a person can be in several campaigns, with a different role in each.
- `characters.campaign_id`: one campaign per character, or none. Deleting a campaign keeps its characters.
- The v4 migration renames the old global `dm` role to `admin`. If characters already exist, it also creates **Our Campaign** containing them, with admins as DMs and everyone else as players.
- Only admins add or remove campaign members.

## Schema refinement (v5): choices, formulas, spell sources, Special

All four additions are **optional** in the JSON. Files without them import exactly as before.

| JSON | Database | Purpose |
|---|---|---|
| `pendingChoices: [{id, type, description, options[]}]` | `characters.pending_choices jsonb default '[]'` | Unresolved decisions. The sheet header and the character card show a "⚠ N choices to make" badge, and the Bio tab lists them with **✓ Done** and **+ Add a choice**. |
| `resources[].formula` (string) | `feature_trackers.formula text default ''` | Shows how the maximum is worked out (`monkLevel`, `paladinLevel * 5`, `1 + charismaModifier`). **Display only**: not evaluated, so `max` must still be set. Shown on the Resources tab, as a tooltip on the combat-bar chip, and in the Level Up wizard. |
| `spells[].source` (string) | `spells.source text default ''` | Where a spell comes from (`Warlock`, `Magic Initiate`, `Drow Magic`, `Druid`…). Shown next to the spell level and editable in the spell form. |
| `features[].type: "Special"` | `features.activation = 'special'` | Triggers on something else and uses no action (Divine Smite, Sneak Attack, damage riders). Shown in its own **Special** group on the Combat tab, only when the character has one. |

**Migration:** re-run `supabase/schema.sql`. It adds the three columns with empty defaults and allows `special`. Existing rows keep their values. Then deploy the frontend (asset tag `?v=7`).

## Item catalog and inventory (migrations 20261015000100-001200)

A normalized item catalog (`items` plus typed stats), generic `inventories`, equipment slots, an event log and
transactional RPCs live in `supabase/migrations/`. The Inventory tab (asset tag `?v=10`) uses them: it reads `v_inventory_detail`,
`v_item_catalog` and `character_equipment` and changes items only through RPCs. **Deploy the frontend only after the
migrations**, otherwise the Inventory tab shows a load error. See [`INVENTORY_DATABASE.md`](INVENTORY_DATABASE.md) and
[`INVENTORY_UI.md`](INVENTORY_UI.md).

## Derived character stats (migration 20261015001400)

Equipment, attunement and proficiencies feed a read-only calculation, `get_character_derived_stats(character)`: AC with
a breakdown, speed, armor consequences (non-proficient armor, Strength requirement, Stealth), equipped weapon attacks,
tools and structured warnings. Nothing calculated is stored on the character. New tables:

| Table | Notes |
|---|---|
| `proficiency_groups` | lookup: simple/martial weapons, firearms, light/medium/heavy armor, shields |
| `character_proficiencies` | a group **or** a specific weapon, armor, shield or tool per character; written only by `set_character_proficiency` |
| `item_effects` | permanent catalog item effects (AC/save/attack/damage bonus, ability override …) with activation and stacking rules; data in `supabase/seed/item_effects.sql` |

`characters.ac_override` (nullable) is new. See [DERIVED_CHARACTER_STATS.md](DERIVED_CHARACTER_STATS.md),
[ARMOR_CLASS.md](ARMOR_CLASS.md) and [CHARACTER_PROFICIENCIES.md](CHARACTER_PROFICIENCIES.md). Deploy order as above:
migration and both seed files first, then the frontend.

## Character lineages (migration 20261015001500)

A versioned lineage (race) catalog and a normalized selection per character; effects are resolved on read by
`get_character_lineage` and folded into `get_character_derived_stats`. Nothing resolved is stored on the character, and
the stored ability scores and base speed stay what the user entered.

| Table | Notes |
|---|---|
| `lineage_categories`, `skills`, `languages` | lookups (categories and skills are created by the migration; languages by the seed) |
| `lineages`, `lineage_versions` | lineage and its published versions / sub-lineages (source, status current/legacy, setting, optional, supersession) |
| `lineage_traits`, `lineage_trait_replacements` | traits with automation label, level gate, uses and recharge; child traits that replace parent traits |
| `lineage_choices`, `lineage_choice_options`, `lineage_option_replacements` | choices (kinds, picks, level, sub-choices) and options that carry effects or replace traits |
| `lineage_trait_effects` | typed effects (ability, size, speed, sense, proficiency, language, resistance, natural armor/weapon, spell, limited use …) |
| `character_lineages`, `character_lineage_choices` | one selection per character + chosen values; written only by `set_character_lineage` / `clear_character_lineage` |

`characters.race` (free text) is kept and used when no lineage is selected. Data: `data/lineages/*.json` →
`supabase/seed/lineages.sql`. See [LINEAGES.md](LINEAGES.md), [LINEAGES_DESIGN.md](LINEAGES_DESIGN.md) and
[LINEAGE_COVERAGE.md](LINEAGE_COVERAGE.md). Character JSON gains an optional `lineage` object (see the schema).

## Spell catalog, spellcasting sources and class foundation (migration 20261015001600)

A versioned spell catalog (567 spells, 574 versions), a minimal class foundation (9 classes, versions and spell lists)
and a spellbook per character resolved on read by `get_character_spellbook`.

| Table | Purpose |
|---|---|
| `spell_schools`, `catalog_spells`, `spell_versions` | schools; canonical spell (official or homebrew via `owner_id` / `campaign_id`); published versions with parsed mechanics and source metadata |
| `spell_effects`, `spell_effect_damage_types`, `spell_damage_type_links` | structured damage / healing / temp HP with scaling and automation status; damage types for filtering |
| `classes`, `class_versions`, `class_spell_lists`, `class_spell_list_entries` | class basics (ability, preparation, ritual, caster type) and spell lists |
| `spell_slot_progressions`, `spell_slot_progression_levels` | structure only (empty) |
| `character_spellcasting_sources`, `character_spells` | sources (class preview, subclass, feat, item, manual, other) and grants (known / prepared / always prepared); written only by RPCs |

`lineage_trait_effects.spell_version_id` links lineage spells to the catalog; they are not stored per character.
The free-text `spells` and `spell_slots` tables are unchanged. Character JSON gains optional `spellcasting.sources` and
`catalogSpells`. See [SPELLS.md](SPELLS.md), [SPELL_DATA_MODEL.md](SPELL_DATA_MODEL.md),
[SPELLCASTING_SOURCES.md](SPELLCASTING_SOURCES.md), [CLASS_FOUNDATION.md](CLASS_FOUNDATION.md).

## Character classes, spell slots, resources and rests (migration 20261015001700)

| Table | Purpose |
|---|---|
| `class_version_levels`, `subclass_versions`, `subclass_version_levels` | per-level class table numbers; one-third caster progressions |
| `character_classes` | class version + level (+ subclass) per character; one per class; one primary; total at most 20 |
| `character_spell_slot_state` | expended standard slots per level and expended Pact slots (maximums are derived) |
| `character_temporary_spell_slots` | future created slots, separate from the class maximums |
| `character_resources`, `character_resource_events` | generic resources with formula maximums and recharge; audit of every use, restore, correction and rest |

`characters.level` becomes a mirror of the class total while classes exist (legacy fallback otherwise);
`character_spellcasting_sources.character_class_id` links a class source to its class. Read with
`get_character_class_summary` / `get_character_spell_slots`; write only through the RPCs. Character JSON gains optional
`classes`, `slotState`, `characterResources` and `spellcasting.sources[].classKey`. See [CLASS_LEVELS.md](CLASS_LEVELS.md),
[SPELL_SLOTS.md](SPELL_SLOTS.md), [RESOURCES_AND_RESTS.md](RESOURCES_AND_RESTS.md).

## Class feature engine (migration 20261015001800)

Catalog: `subclasses`, `class_features`, `class_feature_versions`, `class_feature_unlocks`, `class_feature_scaling`,
`class_feature_choices`, `class_feature_choice_options`, `class_feature_effects`, `class_feature_resources` (read-only for
clients). Character state: `character_feature_choices` + `character_feature_choice_values`, `character_optional_features`,
class resource rows in `character_resources` (`feature_resource_id`, `temporary_bonus`, `max_adjustment`); events in
`character_resource_events` (`feature_resource_id`). Everything else (active features, effects, resource maximums,
grants) is calculated by `get_character_class_features` / `get_character_resources` / `get_character_derived_stats`.
Character JSON: `classFeatures` (choices, optionalFeatures, resources with stable catalog ids; never the catalog).
Seed: `supabase/seed/class_features.sql`; synthetic test content: `supabase/tests/fixtures/class_feature_engine_fixture.sql`.
Rollback: `supabase/rollback/rollback_class_features.sql`. See [CLASS_FEATURE_ENGINE.md](CLASS_FEATURE_ENGINE.md).

## Wild Shape gameplay engine (migration 20261017001300)

- **Creature catalog:** `creatures` gains `mechanics_status` / `mechanics_notes`.
- **Active form:** `character_transformations` gains form temp HP, a normal-HP snapshot, duration / `expires_at`,
  `elemental`, `equipment` (merge / drop / wear per item), `action_state`, `seen_status` and `notes`. It is in the
  Realtime publication.
- **New tables** (RLS read through `can_access_character`, no client writes): `character_wild_shape_settings`,
  `character_seen_forms`, `character_form_favorites`, `character_transformation_events`.
- **JSON export:** an optional `wildShape` block (seen forms, favorites, settings, and a reference copy of an active form,
  which is imported as inactive).

Details: [CREATURE_DATA_MODEL.md](CREATURE_DATA_MODEL.md), [TRANSFORMATION_ENGINE.md](TRANSFORMATION_ENGINE.md).

<!-- 20261019 governance/feats/content -->
## Campaign governance, requests, feats, DM content, hidden data (migrations 20261019000100–000700)

- **Governance** (`…0100`): `governance_actions` (69 actions with per-preset decisions, `max_player`, lock class),
  `campaign_governance` (preset, custom base, prerequisite / note / edit settings, content policy, revision),
  `campaign_policy_overrides`, `character_governance` (lock, setup), `governance_migration_report`,
  `campaign_audit_events`. Gate `_gov_gate` in 75 RPCs; direct-write triggers on `characters` and its child tables.
  [DM_GOVERNANCE.md](DM_GOVERNANCE.md), [CHARACTER_LOCKS.md](CHARACTER_LOCKS.md), [CAMPAIGN_CONTENT_POLICY.md](CAMPAIGN_CONTENT_POLICY.md).
- **Change requests** (`…0200`): `change_request_ops` (registry of proposable domain RPCs), `change_requests`
  (ops, baseline + hash, status, review, approved ops; Realtime), `change_request_events`, `change_request_private_notes`.
  [APPROVAL_WORKFLOWS.md](APPROVAL_WORKFLOWS.md).
- **Feats** (`…0300`): the old `feats` table is renamed `feat_versions`; new canonical `feats`; `feat_prerequisites`,
  `feat_choices`, `feat_choice_options`, `feat_effects`, `feat_spell_grants`, `feat_resource_grants`, `feat_attack_grants`;
  character side `character_feats`, `character_feat_choices`. Character JSON: `feats`. [FEAT_DATA_MODEL.md](FEAT_DATA_MODEL.md).
- **DM content** (`…0400`): `dm_content`, `dm_content_versions`, `dm_content_events`; campaign columns on creatures,
  backgrounds, lineages, spells and class spell list entries (`content_version_id`, `archived_at`).
  [CUSTOM_CONTENT_LIFECYCLE.md](CUSTOM_CONTENT_LIFECYCLE.md).
- **Hidden DM data** (`…0500`): `dm_character_notes`, `character_conditions` (+ `character_condition_secrets`), `item_secrets`,
  `inventory_item_knowledge`, `items.secret`. [HIDDEN_DM_DATA.md](HIDDEN_DM_DATA.md).
- **DM read models** (`…0600`): `get_my_dm_campaigns`, `get_dm_overview`, `get_dm_party`. [DM_SPACE.md](DM_SPACE.md).
- **Performance** (`…0700`): `_character_mods` evaluates the derived stats once instead of once per ability.
- **Feat backfill** (`…0800`): `_sync_character_feats` for every existing character (feat resources and spells that
  pre-existing background / lineage / ASI feats grant).
