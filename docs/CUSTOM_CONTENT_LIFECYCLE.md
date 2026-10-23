# Custom content lifecycle

DMs author campaign content – spells, items, feats, creatures and Wild Shape forms, companion templates, backgrounds,
lineages and conditions – in **DM Space → Content Library** (`js/content-editors.js`, `js/dm-space.js`). Migration
`20261019000400_dm_content.sql`. Per-type definitions: [CUSTOM_SPELLS.md](CUSTOM_SPELLS.md), [CUSTOM_ITEMS.md](CUSTOM_ITEMS.md),
[CUSTOM_FEATS.md](CUSTOM_FEATS.md), [CUSTOM_CREATURES.md](CUSTOM_CREATURES.md), [CUSTOM_COMPANIONS.md](CUSTOM_COMPANIONS.md);
backgrounds, lineages and conditions are described at the end of this page.

## Who may author

Only a DM (for a campaign: a DM of that campaign; for the private library: a DM of any campaign) or an admin
(`can_author_content`, `_gov_content_gate`, actions `content.*`, always `dm_only`). **Players never author mechanical
content.** Players keep free-text notes, free-text features and free-text spells on their own sheet; those have no rules
effect beyond what the player types.

## Model

| Table | Holds |
|---|---|
| `dm_content` | one piece of content: type, author, campaign (null = the DM's private library), scope, status, current and published version, archive state, revision |
| `dm_content_versions` | immutable-once-published versions: name, summary, `player_text` (what players read), `dm_notes` (never shown to players), ruleset, `definition` (the mechanics, JSON per type), validation result, `catalog_ref` |
| `dm_content_events` | history: created, saved, validated, validation_failed, published, new_version, archived, restored, duplicated, deleted, assigned, copied |

Publishing **materializes** the version into the normal catalogs (`_dm_materialize`), with ids `cc-<10 hex>-v<n>`:
`catalog_spells` / `spell_versions` / `spell_effects` / class spell list entries, `items` (+ weapon / armor stats and
modifiers), `feats` / `feat_versions` / prerequisites / choices / effects / spell and resource grants, `creatures`,
`backgrounds` / `background_versions` / grants / equipment, `lineages` / `lineage_versions` / traits / effects / choices.
Every catalog row carries the campaign, the author, `content_version_id` and the source label **Campaign custom**, and is
visible only to members of that campaign (RLS). From there the existing engines (spellbook, inventory, derived stats, feats,
Wild Shape, companions) treat it like official content – no special code path.

## Statuses

```
draft ─validate─▶ ready_for_review ─publish─▶ published ─new version─▶ revised (draft v2) ─publish─▶ published (v1 superseded)
  │                      ▲                        │
  └──▶ validation_failed ┘                        └─archive─▶ archived ─restore─▶ published
```

* **Validate** (`validate_dm_content`, also run by publish): `_dm_try` materializes the version inside a sub-transaction,
  reads the catalog row back (the player preview) and rolls back. Any constraint the real catalogs enforce is therefore
  enforced here, with a readable message.
* **Publish** (`publish_dm_content(content, expected_version)`): exactly once per version (row lock); the previous published
  version becomes `superseded` (it stays in the catalog for the characters that use it).
* **Published content is never edited in place** (`TLPUB`). `new_dm_content_version` starts a draft from the published
  version; characters keep the version they have until the DM assigns the new one.
* **Archive** (`archive_dm_content(content, reason)`) hides the catalog rows from new picks (`archived_at`); everything that
  already references them keeps working and stays readable. Assigning archived content is refused.
* **Restore** brings archived content back; **duplicate** copies it as a new draft (optionally into another campaign: this is
  how private library content is "copied to Campaign A"); **delete** only removes a draft that was never published and is
  referenced by nothing (author only). Published content is never deleted.
* Optimistic concurrency: `save_dm_content(..., expected_revision)` refuses a stale save ("Someone else saved this draft
  meanwhile. Reload it."), `publish_dm_content(..., expected_version)` refuses publishing a version that is no longer current.

## Usage and assignment

`_dm_usage(content)` counts characters, stash items, backgrounds granting a custom feat and pending requests that use the
content; the library shows it and archive warns with it. `dm_assign_content(content, characters, mode, options)` gives
published content to characters of the campaign through the domain RPCs:

| Type | Modes |
|---|---|
| spell | `known`, `innate`, `always_prepared` (into a chosen or a "Campaign gifts" spellcasting source) |
| item | inventory (default) or `stash`; options `quantity`, `custom_name`, `identified` (false = unidentified, see [HIDDEN_DM_DATA.md](HIDDEN_DM_DATA.md)) |
| feat | `dm_grant` or `campaign_reward` |
| creature | `seen_form` (Wild Shape grant) or `companion` |
| companion | a companion instance from the template |
| background / lineage | sets it on the character |
| condition | applies it (visible or hidden) |

Each assignment returns a per-character result (one failing character does not undo the others) and is logged
(`assigned`).

## Backgrounds, lineages and conditions

* **Background** definition: `abilities` (three ability keys for the 2024 +2/+1 or +1/+1/+1), `feat` (+ `feat_parameter`),
  `skills`, `tools`, `languages`, `feature` {name, summary} (legacy style), `equipment` [{item_id, quantity, label}] and
  `gold` (option B), `duplicate_rule`. Ruleset 2024 or 2014.
* **Lineage** definition: `creature_type`, `traits` [{name, summary, min_level, effects [{type, target, value, value_text}]}]
  (speed, sense, resistance, language, proficiency, ability bonus – applied by the lineage engine), `ability_patterns` +
  `ability_picks` (+2/+1 or +1/+1/+1), `feat_choice` (a feat picked from the catalog).
* **Condition** definition: `category` (curse, disease, blessing, magical, environmental, other), `duration`, `removal`,
  `save` {ability, dc, repeat}, `effects` [{type, target, value, text}]. Applied by version id with
  `apply_character_condition` (visible or hidden, optional timer). **The effects are shown on the condition card as
  reminders; they are not applied to derived stats automatically** (a known limitation, see the final report).

## Tests

`supabase/tests/classes/dm_content_tests.sql` (37 checks: authoring rights, lifecycle, validation, publish, versioning,
archive in use, restore, duplicate, delete rules, every content type materialized and used by its engine),
`governance_api_test.py` (GA16–GA32), `dm_space_ui_test.py` (the spell editor end to end, assignment, archive).
