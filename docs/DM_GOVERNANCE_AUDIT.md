# DM governance audit (task start, 2026-10-19)

Audit of the permission model before campaign governance, approvals and the DM Space were added. Read against the
local database at the task-start state (32 migrations, 2 users, 30 characters, 1 campaign).

## Current permission model

| Layer | What exists |
|---|---|
| Global role | `profiles.role`: `player` or `admin`. Admins see and change everything. Only an admin may change a role (`protect_profile_role`). |
| Campaign role | `campaign_members(campaign_id, user_id, role)` with `dm` / `player`. Only admins change membership (`campaign_members_write`). |
| Helpers | `is_admin()`, `is_campaign_member(c)`, `is_campaign_dm(c)`, `shares_campaign(u)`, `can_access_character(id)` = owner, admin or DM of the character's campaign. `_acts_as_dm(character)` (Wild Shape). |
| Characters | RLS: read/update/delete for owner, admin, campaign DM. Every column of `characters` is client-writable (column grants on all 44 columns), including `level`, ability scores, `hp_max`, `owner_id`, `campaign_id`. |
| Child free-text tables | `notes`, `features`, `attacks`, `feature_trackers`, legacy `spells`, `spell_slots`: `for all` policies via `can_access_character`. |
| Engine tables | class rows, feature choices, lineage, background, spells, resources, transformations, companions, infusions: **no client write grant**; every write goes through a SECURITY DEFINER RPC that checks `can_access_character` (or inventory helpers). |
| Catalogs | official classes, spells, lineages, backgrounds, feats, creatures: read-only for clients (seed only). |
| Homebrew items | `items.owner_id` (+ `campaign_id`): private (author only) or campaign (members read, DM edits). Written only by `create_homebrew_item`, `update_homebrew_item`, `archive_homebrew_item`, `restore_homebrew_item`, `convert_legacy_item_to_homebrew`. Item modifiers: direct table writes by author / campaign DM. |
| Spells catalog | `catalog_spells.owner_id` / `campaign_id` columns exist (`scope` private/campaign) but there is **no** write RPC; no client can create a spell definition. |

## Current DM capabilities

- Read and change every character of their campaigns through the same RPCs as the owner (no DM-specific path).
- Grant seen Wild Shape forms (`set_seen_forms`, DM-or-owner depending on `character_wild_shape_settings.seen_mode`).
- Edit and archive campaign homebrew items.
- Change campaign name / description (`campaigns_update`).
- No approval inbox, no hidden data, no audit timeline, no governance, no locks, no party overview, no DM area in the UI
  (only a "DM" badge and DM-labelled campaign headers on the character list).

## Current player capabilities

- Everything the DM can do on their own characters: level, class, subclass, multiclass, lineage, background, ability
  scores, `hp_max`, proficiencies, known / spellbook spells, always-prepared spells, manual spellcasting sources,
  any catalog item, feature choices, ASIs, resources, rests, Wild Shape, companions (`add_character_companion`).
- Create **mechanical** homebrew items (private or campaign) and convert legacy items to homebrew, from the Inventory tab.
- Move their own character out of the campaign (`campaign_id` is writable; the update check only demands membership
  of the target campaign or `null`).

## Unsafe direct write paths

| Path | Problem | Fix in this task |
|---|---|---|
| `characters` column writes | level, abilities, `hp_max`, proficiencies, `campaign_id` changeable by the player without any policy | `characters_governance` BEFORE UPDATE trigger: maps changed columns to governed actions for the `authenticated` role |
| `campaign_id = null` by a player | escapes campaign governance | DM-only action `character.move_campaign` |
| legacy `spells` inserts | free-text spells with mechanics fields | gated by `spell.manual_add` |
| homebrew RPCs | players author mechanical items | content creation is DM-only (`content.create_item`); existing player homebrew kept |
| `item_modifiers` direct writes | player-authored mechanical modifiers | write policy restricted to campaign DMs / admins |
| domain RPCs | no policy, only `can_access_character` | `_gov_gate` injected at the top of each governed RPC |

## Mechanical custom content available to players (to remove)

- "+ Create homebrew item", "Convert to homebrew…", "Edit homebrew definition" (Inventory tab, `homebrew-form.js`).
- Manual spellcasting sources with free spell picks (Spells tab, "+ New spellcasting source…") — kept, but governed
  (`spell.change_source`, `spell.add_manual`).
- Free-text spell list ("New spell") — legacy, kept read/write as text but governed by `spell.add_manual`.
- No player-facing creator exists for spells, feats, creatures, backgrounds, lineages, companions or conditions.

## Reusable structures

- `items` homebrew model (`_write_homebrew` validation, typed stats, `homebrew_item_events`, archive / restore,
  usage count) -> reused for DM custom items.
- `catalog_spells` + `spell_versions` + `spell_effects` (owner / campaign scope already modelled) -> custom spells.
- `creatures` (CR, AC, HP, abilities, actions, traits jsonb) + transformation engine -> custom Wild Shape forms.
- `character_companions` -> companion instances of templates.
- Class-feature effect vocabulary (`class_feature_effects.effect_type`) and prerequisite format (`_cf_prereq`) -> feats.
- `character_resources` generic rows (`source_type` already allows `feat`) -> feat resources.
- `character_spellcasting_sources` (`source_type` already allows `feat`) -> feat spells.
- `background_feat_grants` -> background Origin feat links.

## Duplicated editors

`homebrew-form.js` is used for create, convert and edit; there is one editor, but it lives in the player Inventory tab.

## Approval gaps

No proposal or request entity; no structured diff; no stale detection; no idempotency for multi-step build changes
(level-up is one RPC, but ASI / feat / spell choices are separate calls).

## Audit gaps

Events exist per domain (`inventory_events`, `homebrew_item_events`, `character_resource_events`,
`character_transformation_events`) but there is no campaign timeline, no actor-readable before/after, no request link,
and no record of policy or lock changes.

## Hidden-information gaps

Nothing is DM-only: every row a DM can read, the owner can read. No secret notes, hidden conditions, curses,
unidentified item state or reveal events.

## Campaign-policy gaps

No source-book / ruleset / playtest policy per campaign; pickers show every official version.

## UX gaps

- No DM workspace; a DM must open characters one by one.
- No place to create campaign content except the player Inventory tab.
- No message telling a player why a change is not allowed.

## Migration requirements

1. Governance: settings, action catalog, overrides, locks, setup state; explicit rows for existing campaigns (`relaxed`).
2. Approvals + campaign audit.
3. DM content registry, versions, publications; typed materialization targets (campaign columns on creatures,
   lineages, backgrounds, feats); hidden-data tables.
4. Feat catalog (rename, canonical table, typed child tables, character feats, choices).
5. Gate injection into existing RPCs (builder copies the live definitions, like the earlier tasks).

## RLS requirements

- Governance tables: members read their campaign's settings; only DMs / admins write (through RPCs).
- Requests: requester + campaign DMs read; DM notes are in the same row but stripped from the player read model
  (`get_my_change_requests`); clients have no direct write grant.
- DM content: author + campaign DMs read drafts; published materializations follow the catalog read policies
  (campaign members).
- Hidden tables: campaign DMs / admins only; no Realtime publication.

## Frontend changes

DM Space route `#/dm`, approval inbox, content library and editors, party overview, campaign rules, audit log;
policy-aware actions on the character sheet (Request … buttons, lock banner); feat section on the Features tab;
removal of the player homebrew creator.

## Import / export impact

Export gains `feats` (exact versions, sources, choices) and custom-content references; hidden data is never exported
from the player export. Import resolves versions, keeps unresolved references as a report, never creates content and
calls only governed RPCs (so governance applies).

## Explicit scope exclusions

- Public sharing of content between DMs (only a reserved `shared` scope value).
- Full condition gameplay automation (only the definition + assignment foundation).
- A complete polished level-up wizard (the existing one becomes approval-ready).
- Third-party feats.
- A hosted deployment of any of this.
