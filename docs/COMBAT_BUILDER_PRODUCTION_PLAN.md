# Combat Builder and combined follow-up: production plan (prepared, NOT executed)

Nothing in these tasks touched production. This is ONE combined in-place release: the Combat Builder, the feat-removal fix,
the source-aware ability rows, and the 2026-11-07 follow-up (final-total Initiative, Wild Shape overflow, active class
options and Artificer infusions in Play, Herbs & Plants, potion details, per-item icons, safe item deletion). It follows
[DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md](DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md) and the 2026-10-30 / 31 releases
([PRODUCTION_OPERATIONS.md](PRODUCTION_OPERATIONS.md)). Local evidence: [COMBAT_BUILDER_FOLLOWUP.md](COMBAT_BUILDER_FOLLOWUP.md).

## Scope

| Item | Exact content |
|---|---|
| Migrations (in this order) | 1. `20261106000100_combat_builder_schema.sql` 2. `20261106000200_combat_builder_functions.sql` 3. `20261107000100_feat_removal.sql` 4. `20261107000200_combat_initiative_wild_shape.sql` 5. `20261107000300_items_herbs_icons_deletion.sql` 6. `20261107000400_class_option_activation.sql` |
| Rollbacks (in this order) | frontend first, then 6 → 1: `rollback_class_option_activation.sql`, `rollback_items_herbs_icons_deletion.sql`, `rollback_combat_initiative_wild_shape.sql`, `rollback_feat_removal.sql`, `rollback_combat_builder_functions.sql`, `rollback_combat_builder_schema.sql`, then `supabase migration repair --status reverted 20261107000400 20261107000300 20261107000200 20261107000100 20261106000200 20261106000100` |
| Seed | `supabase/seed/combat_monsters.sql` (SRD 5.2.1 monsters + SRD 5.1 legendary actions; upsert-only into the two new tables; idempotent; CC-BY-4.0 attribution in the seed header and the UI). **No catalog re-import** |
| Catalog patch | migration 6 only: adds `activation` (and `play: reminder`) to 208 named class options (`class_feature_choice_options.data`); idempotent; no row added or removed; character choices untouched |
| Reference rows | migration 5: item kind `herbs_plants` + 11 categories `plant-*` (insert … on conflict do nothing) |
| Expected rows after | `combat_monsters` 73, `creature_legendary_actions` 32, `combat_conditions` 30, `item_kinds` +1, `item_categories` +11, options with `activation` 208. No other row changes |
| Frontend | `?v=18` everywhere (production is `?v=17`); new modules `js/combat*.js` (4), `js/active-features.js`, `js/item-icon-gallery.js`; new assets `assets/icons/plants/*.webp` (8), `assets/icons/potions/flask.webp`, `bottle.webp`; regenerated `js/icon-registry.js` (+12 keys, additive) |
| Feature flag | `js/config.js` `COMBAT_BUILDER`: commit 1 ships `'off'`; commit 2 `'dm'` after the DM smoke. Everything else (Initiative is inside the Combat Builder; Wild Shape, Play options, infusions, items, feats, abilities) is not behind the flag |
| `_dm_try` | changed by migration 2 only (one line, anchor-checked); preserved by every later migration |
| Read compatibility | progressive fluent reads, Character Shell, tab bundles, read cache and the legacy fallback are kept. Migration 5 adds two catalog columns to the inventory bundle (`_character_read`) and bumps the global read-cache revision once; migration 6's catalog update bumps it through the existing trigger. First open of each character after the release is a cold read |
| Downtime | none expected (additive tables/columns, `create or replace` with identical signatures, ~260 KB seed, a 208-row JSON update) |

**Order matters once:** the new frontend reads `items.icon_key / details` (catalog columns) and calls `apply_character_hp`,
`preview_item_deletion`, `delete_custom_item`: **apply all migrations before the frontend goes live.**

## Existing-data questions

| Question | Answer |
|---|---|
| Existing encounters affected? | none exist in production (new tables) |
| Existing Initiative values need migration? | no: values were always stored as final totals; only the UI labels and group propagation changed |
| Existing Wild Shape state needs reconciliation? | no row changes. Read-only count for the record: forms past their wall-clock duration (`expires_at < now()`); they behave as documented in WILD_SHAPE_DAMAGE.md |
| Existing Artificer choices need reconciliation? | no: infusions and choices are read as they are; they now also appear in Play and Inventory |
| Existing items changed? | no: `icon_key` NULL and `details` `{}` for every row; no category or kind changed |
| Existing icons changed? | no: category defaults unchanged; the registry change is additive |
| Official catalog rows patched? | only the 208 class option `data` keys (migration 6) and the new herb kind/categories; nothing else |
| Feat removal changes data? | no (functions + 2 revision triggers) |

## Steps

1. **Fresh production backup** (dump + restore rehearsal + checksum) under
   `%USERPROFILE%\tavern-ledger-production-exports\<date>-combined-release\…-pre`.
2. **Golden output (read-only, saved next to the backup):** row counts of the touched tables; `pg_get_functiondef` of
   `_dm_try`, `remove_character_feat`, `set_character_feat_choices`, `damage_active_transformation`, `apply_character_hp`
   (absent before the release), `_write_homebrew`, `_character_read`, `pg_get_viewdef('v_item_catalog')`; md5 of each
   (`replace(…, chr(13), '')`) compared with the text embedded in the rollback files. **Any difference: stop**; a rollback then
   restores the saved production text, not the local copy. Also: no `combat_%` table, no column `items.icon_key`, no kind
   `herbs_plants`, no option with `activation`, the publication exists, `creatures` has the 32 legendary SRD 5.1 ids,
   counts of expired forms and of orphan inactive feat resources (record only).
3. **Dry run:** `supabase db push --dry-run` lists exactly the six migrations in the order above.
4. Commit 1 (flag `'off'`, `?v=18`). Push. Wait for GitHub Pages.
5. `supabase db push` → run `combat_monsters.sql` once (idempotent).
6. **Verify:** expected rows above; grants (every new / replaced function executable by authenticated, none by anon;
   `_ws_lock`, `_item_*` helpers not executable by authenticated); the two feat revision triggers; `items_icon_key_check`.
7. **Smokes** (synthetic users and campaign, removed afterwards):
   - player sheet: Damage / Heal through `apply_character_hp`; typed HP still saves;
   - **Wild Shape overflow:** a synthetic Druid in a 20 HP form, normal 30: damage 21 → normal 29 (sheet and Combat Builder);
   - **player denial:** Combat link hidden, `#/combat` refused, `combat_list_encounters` → 42501; player-safe view hides
     hidden monsters and DM-only effects;
   - **feat removal / ability rows:** as in FEAT_REMOVAL.md and ABILITY_SCORE_SOURCE_MODEL.md;
   - **Play options / infusions:** a synthetic Warlock (Pact of the Blade in Actions, Devil's Sight in reminders); a
     synthetic Artificer with Enhanced Weapon on a Mace (Play section + Inventory badge);
   - **items:** as a DM create a Herbs & Plants item with an icon and an environment; a potion with doses; delete an unused
     one (typed name); a used one offers Archive;
   - existing smokes: `production_fluent_smoke.py`, `production_polish_smoke.py` (PP-02 expects `?v=18`), legacy smoke.
8. Commit 2: `COMBAT_BUILDER = 'dm'`. Push. **DM smoke:** encounter, Add party, SRD monsters, player **Final Initiative**
   totals typed (17 stays 17), monsters auto-rolled, one manual monster total, a group total, tie review, Start, Next ×3,
   damage a monster and a linked character (linked HP), damage a Wild Shape form by HP + 1 (1 overflow), a condition,
   concentration, Undo, pause / resume, Correct Initiative with a reason, finish → summary.
9. **Post-deployment backup.** Delete the access file. The user rotates the DB password.

## Rollback

| Situation | Action |
|---|---|
| Frontend only | revert the commit(s) (or `COMBAT_BUILDER = 'off'`); the database stays. The old frontend does not use the new columns or RPCs, except the new sheet's `apply_character_hp`, which the old sheet does not call |
| Class option timing only | `rollback_class_option_activation.sql` (removes the keys; Play then shows options on Build only) |
| Items only | `rollback_items_herbs_icons_deletion.sql`: drops `icon_key` / `details` (icons and item details are lost) and refuses while any `herbs_plants` item exists (archive / convert them first, or keep the migration); restores `_write_homebrew`, `v_item_catalog`, `_character_read` exactly |
| Initiative / Wild Shape only | `rollback_combat_initiative_wild_shape.sql` (restores the five functions; the expiry defect returns) |
| Everything | frontend to `?v=17` first, then the six rollbacks newest first (the combat schema rollback **deletes all encounters**; back them up), then `migration repair` as above |
| Data written before a rollback | encounters are self-contained; linked HP and moved conditions are ordinary character data; removed feats stay removed; deleted unused items stay deleted |

## Exact next approval phrase

To run this plan, the user writes:

**PROCEED WITH COMBAT BUILDER PRODUCTION RELEASE**

and recreates the production access file. Without that phrase nothing above is executed.
