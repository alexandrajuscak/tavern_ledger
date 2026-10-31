# Gameplay polish: audit and fixes (2026-10-31)

Migration `20261031000100_gameplay_polish.sql` (rollback `supabase/rollback/rollback_gameplay_polish.sql`), frontend `?v=16` (import fix `?v=17`, section 8).
Tests: `supabase/tests/gameplay_polish_tests.sql`, `supabase/tests/browser/gameplay_polish_ui_test.py`.

## 1. Homebrew items (DM Space item editor)

| | |
|---|---|
| Current behaviour | A DM's non-armor item (gear, tool, potion, wondrous item, weapon) failed validation and could not be published: "Armor stats only apply to armor". Every item without a price also failed: "Cost needs both an amount and a coin". Ammunition could never be published (no ammunition-type field). The Type list offered Mount and Vehicle, which a homebrew item cannot be. |
| Root cause | `js/content-editors.js` always showed and sent the Armor section. Its "Stealth disadvantage" checkbox is serialised as `false`, which survives `prune`, so `definition.stats.armor = {stealth_disadvantage: false}` was sent for every item. `_write_homebrew` (the validator and writer behind both validate and publish) rejects any armor section on a non-armor item. The coin select always has a value. |
| Fix, frontend | Weapon, Armor and Ammunition sections are shown only for their type (`data-ce-for`, re-applied after every redraw). `readForm` sends only the stats of the chosen type (values left in a hidden section never become mechanics) and drops the coin when there is no cost. An Ammunition section (type, pack size) was added. Type lists only the 8 homebrew types. Required fields are labelled "(required)". The player homebrew form now requires weapon damage dice. |
| Fix, backend (authoritative) | `_write_homebrew` ignores a stats section with no value (null, false, empty), so an old cached editor works too. A section **with** values must still fit the type, so a tool with `base_ac` is still refused. A weapon now needs damage dice. Every other rule is unchanged, and armor still needs a base AC (or a shield bonus). |
| Existing content | No published item is changed (the writer runs only when an item is saved). Production at deployment: 10 custom items (armor 1, gear 2, tool 3, magic item 3, scroll 1) and 2 DM content entries, **0 custom weapons**, so the new damage-dice rule blocks no existing item from being edited, versioned or imported. |
| Tests | SQL H1-H24 (gear, tool, weapon, potion, wondrous, scroll, ammunition, armor and shield valid; armor without AC, weapon without damage, stale armor on a tool, stale weapon on armor refused; published tool has no armor or weapon stats; unrelated player denied). Browser H0, H3, H11-H13, H22. |

### Item-type validation matrix (server)

| Type | Required | Must not carry |
|---|---|---|
| gear (generic) | name | armor, weapon or ammunition stats with values |
| tool | name | armor, weapon or ammunition stats |
| weapon | name, damage dice (group defaults from the category) | armor stats |
| armor | category (light, medium, heavy, shield), base AC (body armor) or AC bonus (shield) | weapon stats |
| ammunition | name, a known ammunition type | armor, weapon stats |
| potion, scroll | consumable (default on) | armor, weapon stats |
| magic item | a rarity when magical | armor, weapon stats |
| any | cost needs amount and coin together; attunement only a flag | — |

## 2. Magic Initiate (and every feat granted with a parameter)

| | |
|---|---|
| Current behaviour | A character with Magic Initiate from the Acolyte, Guide or Sage (2024) background picked the cantrips and the level-1 spell, saw "Choices saved", but no spell appeared in Spells. |
| Root cause | `_store_feat_choices`: `fixed := par is not null and c.config -> 'parameter_map' ? par`. For a background grant `par` = 'Cleric' / 'Druid' / 'Wizard', and for the choices without a `parameter_map` (ability, cantrips, spell) the expression is NULL. `not fixed` is then NULL, and the choice was silently skipped. Nothing was stored, so `_sync_character_feats` saw incomplete choices and granted nothing. A directly assigned Magic Initiate (no parameter) worked. |
| Fix | NULL-safe `coalesce(..., false)`. The rest of the grant engine was already correct and is unchanged: one spellcasting source per grant (`feat_grant_key`), only the selected spells, the chosen ability, cantrips at will, the level-1 spell with one free cast per long rest (a feat resource), idempotent (unique source + spell), removed with the grant while other sources stay. |
| Other sources audited | `background_feat_grants` with a parameter: exactly the 3 Magic Initiate rows. Lineage feats, ASI feats and direct feats have no parameter. Lineage spells, class spells and item spells use other code paths (not affected). |
| Existing characters | The migration re-syncs every character holding a feat with spell grants (idempotent). Choices that were never stored cannot be recovered: those characters see the feat's open choices (Build) and pick again once. |
| Tests | SQL M1-M31 (choices stored, incomplete = no grant, 3 spells, ability INT, free-cast resource, no duplicates after repeated syncs, spellbook and progressive bundle list them, second Magic Initiate on another list, removal keeps the background source, unrelated player denied). Browser M0-M8 (Spells tab lists the 3 spells with the Magic Initiate source). |

## 3. Coin calculator

| | |
|---|---|
| Current behaviour | Five raw number inputs (CP SP EP GP PP); the player converted coins by hand. |
| Data | `characters.cp/sp/ep/gp/pp` integer, `characters_coins_check` (>= 0), governance action `inventory.currency`. Values from `currencies.conversion_to_cp`: cp 1, sp 10, ep 50, gp 100, pp 1000. |
| New | `adjust_character_coins(character, mode, amount, expected)`, SECURITY INVOKER (RLS: owner, campaign DM, admin; governance trigger applies). Row lock (`select … for update`), one `update`, optional stale-wallet check (`40001`), whole numbers 0-9,999,999 only. Frontend `js/coins.js`: "Add or spend…" in the Coins section; Spend / Gain; preview (taken, change, afterwards); Apply; Undo (an exact `set` guarded by the wallet it replaced). |
| Spend algorithm | (1) each requested denomination from the same coins as far as they go; (2) the rest from the remaining coins, smallest denomination first, whole coins only; (3) if something is still owed, one coin of the smallest denomination worth more than the rest is broken and the change returned largest first in gp / sp / cp below it (electrum is never created as change). Example: 1 gp − 3 sp 4 cp = 6 sp 6 cp. Same code in SQL and in the preview (tested to match). |
| Gain | Adds the entered coins as they are. No automatic normalisation (none is offered either). Existing wallets are never converted. |
| Realtime / cache | One `characters` UPDATE: the other session patches the coins (no reload); coins are runtime columns, so the server rules cache stays valid (tested P1). |
| Tests | SQL C1-C31 (gain, exact, smaller first, break GP / PP / EP, insufficient, zero, negative, decimal, non-numeric, huge, unknown coin or mode, stale wallet, undo, DM allowed, unrelated player and anonymous denied, grants). Browser C4-C27 (preview, apply = preview, Realtime, Undo, insufficient, decimal, double click applies once, keyboard focus and labels, 390 px). |

## 4. Lineage resource counters (Hungry Jaws)

| | |
|---|---|
| Stored rules | `lineage_trait_effects` 'limited_use': Lizardfolk (MPMM) Hungry Jaws = uses `pb`, long rest, "Bonus action bite; on a hit gain temporary HP equal to your proficiency bonus". Lizardfolk (VGM) = 1 use, short or long rest. 42 such traits on 36 lineage versions, all with uses 1 or pb and a known recharge; none depends on an option. |
| Current behaviour | Shown as text only (derived stats); no counter. |
| New | `_sync_lineage_resources`: one `character_resources` row per limited-use trait of the lineage / sub-lineage (`source_type` 'lineage', key `lin-<trait>`, formula pb or fixed, the stored recharge, `unlock_level` from the trait's minimum level). Kept in step by a trigger on `character_lineages`; a trait no longer held is deactivated (count kept), so re-choosing the lineage reuses the row. Use / Restore / rests are the existing resource engine. Play: in "Ready to use" and the Resources card, source "Lineage: Lizardfolk" with the action text; the temporary HP is applied by hand (noted on the card). |
| Existing characters | The migration syncs every character with a lineage (local: 8; 0 Lizardfolk). |
| Tests | SQL L1-L21 (counter, max = PB, Use, short rest does not / long rest does restore, VGM version, lineage change deactivates, re-choose = no duplicate, bundle includes it, unrelated player denied, all 42 traits supported). Browser L0-L9 (Play Ready to use 2 / 2, source and action, Use, long rest updates the open sheet). |

## 5. Icons

| Role | Before | After | Source (local icon pack, `assets/icons/SOURCE_ICONS.md`) |
|---|---|---|---|
| Inventory Weapons (`item.weapons`) | crossed swords, **byte-identical to the site logo** (Fighter emblem) | the hammer previously used for Tools | `hammer.png` (also the source of the Bludgeoning damage icon) |
| Inventory Tools (`item.tools`) | hammer | lute (same file as `items/lute`) | `671385046.png`; the gear-and-wrench toolkit was rejected because it is the Artificer class emblem |
| Illusion school (`spell.school.illusion`) | masquerade mask with a dagger (read as Rogue) | a figure with a shimmering spectral duplicate | `barrier.png` (not used elsewhere) |

The files are replaced in place, so the central registry keys are unchanged (`js/icon-registry.js`) and there are no per-card
overrides. All are self-hosted 96 px WebP, with no external request. `scripts/local/icon_audit.py`: 0 missing, 0 corrupt,
0 unresolved references. The licence of the whole pack is still unverified (unchanged open item,
`docs/UI_ICON_SYSTEM.md`). Tests: browser IC1-IC18.

## 6. Progressive architecture

| Change | Invalidation |
|---|---|
| Coin transaction | runtime columns only: the server rules cache is not invalidated; Realtime patches the other session |
| Hungry Jaws Use / rest | `character_resources` revision → only the resources reload |
| Magic Initiate choices | feat choices, spells, sources → character counter bump (Build, Spells, derived) |
| DM item publish | catalog write → global counter (rare, DM action) |
| Icons | frontend only |

## 7. Production deployment (2026-10-31)

| Step | Result |
|---|---|
| Local | `gameplay_polish_tests.sql` 70/0; `progressive_read_tests.sql` 1,283/0; `fluent_read_tests.sql` 1,707/0; `gameplay_polish_ui_test.py` 32/0; full browser suite 1,053 passed in 35 suites + 1 Realtime timing flake (DS25; `dm_space_ui_test.py` rerun 50/0 twice); plain-PostgreSQL suite 3,432/0 incl. whole-schema rollback (first run found that `rollback_class_levels.sql` drops `character_resources` under the new lineage trigger; the sync now no-ops without the table); release rollback exact (function hash `efc4edb2…` restored), reapply identical; local rehearsal of `production_polish_smoke.py` 27/0 |
| Precheck | 44 migrations; ref matches the frontend; 8 users, 7 characters, 2 campaigns, 10 custom items, 2 DM content; 1 character with Magic Initiate from a background (0 stored choices: they were dropped by the bug); 1 Lizardfolk |
| Backup | `…\2026-10-31-gameplay-polish-release\2026-10-31T013824Z-pre-polish`, rehearsal 7/7 |
| Dry run | exactly `20261031000100` |
| Commit / push | `446ef35`, Pages `?v=16`, served files byte-identical to the commit |
| Migration | 03:28:32-03:28:36 UTC, 45 migrations; coins of every character identical (hash); counts and catalog unchanged; direct reads identical except the class summary of the Lizardfolk character (its new Hungry Jaws counter in `resources`; all derived values identical); view == direct (98/0); Hungry Jaws counter created (1); grants as designed |
| Smoke | polish smoke 27/0; progressive smoke 28/0 and legacy `?fluent=0` 25/0 (on a fresh fixture; on the reused fixture two checks failed only because the polish smoke had already given that character a lineage and the first post-migration open was cold) |
| Cleanup | synthetic accounts, campaign, characters, DM drafts: 0 left |
| Backup | `…\2026-10-31T033812Z-post-polish`, rehearsal 7/7 |

The player whose character has Magic Initiate from a background picks its cantrips and spell once more (Build → background
feat → choices); they are kept from now on.

## 8. Follow-up the same day: import of lineage counters (`?v=17`, frontend only, commit `0824603`)

Found while testing export / import: the importer restores the lineage first (its trigger creates the Hungry Jaws counter),
then tried to create the exported counter again under the same key. `save_character_resource` refused (unique key), and the
used count was lost with only a console warning. `js/transfer.js` now carries the used count over to the existing lineage
counter. Tested (`gameplay_polish_ui_test.py`, 35/0): C29 coins identical after import, L12 one counter with the same use
count, M23 the Magic Initiate choices and its 3 spells come back. Before this release, imported background feat choices had
been dropped by the same `_store_feat_choices` bug.
