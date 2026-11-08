# Combat Builder: repository audit

This audit was taken before any Combat Builder code was written (2026-11-06, `main` at `adc42fe`, 46 migration files). It
records what the repository already had for each concept the Combat Builder needs, and what was decided. Every table, function
and file name below was checked against the local database and the source.

**Existing combat code.** There were no encounter, initiative, turn or combat-effect tables or functions before this
task. The sheet's `.combat-bar` / `.combat-grid` CSS classes belong to the character sheet's Play tab. The Combat
Builder therefore uses the `cb-` class prefix. `combat_wild_shape_heal` is Circle of the Moon healing, not part of
the Combat Builder.

| Component | Current implementation | Reusable as is | Needs extension | Unsuitable | Security | Migration |
|---|---|---|---|---|---|---|
| Migrations / rollbacks | 46 additive timestamped files, one rollback each in `supabase/rollback/`. Local `supabase_migrations.schema_migrations` records 42 (the four newest were applied with psql) | Conventions | — | — | — | Two new files and two rollbacks, rollback proven exact (schema digest) |
| Campaigns, members, DM role | `campaigns`, `campaign_members (role dm/player)`, `is_campaign_dm`, `is_admin` | Yes: encounter authority = campaign DM or admin (`_combat_can_run`) | — | — | Server-side role check in every RPC | None |
| Campaign ruleset | `campaign_governance.content_rulesets text[]` ({2014,2024} by default) | Yes, read only | — | — | — | "Campaign default" resolves to one ruleset at creation |
| Character ownership / access | `can_access_character` (owner, campaign DM, admin) | Yes, for the HP RPC | — | — | — | None |
| Character HP | **Client-computed**. The sheet's Damage/Heal computed new values in the browser and wrote `hp_current`/`hp_temp` through the debounced saver, so it was last-writer-wins | — | **New atomic RPC `apply_character_hp`**, used by the sheet buttons and the Combat Builder | A combat copy of player HP (not created) | SECURITY DEFINER bypasses the `characters_governance` trigger, so the RPC calls `_gov_gate(…, 'runtime.hp')` itself | Function only; no column change |
| Maximum HP | `characters.hp_max` + `_feat_hp_bonus()` (Tough etc.); about 6 ms per character | Yes | — | — | — | — |
| Temporary HP | `characters.hp_temp`; Wild Shape form `character_transformations.hp_temp` | Yes | — | — | — | — |
| Death saves | `death_successes` / `death_failures`, reset by the sheet when healed from 0 | Yes; the RPC resets them the same way | — | — | — | — |
| Wild Shape | `damage_active_transformation`, `heal_active_transformation`, `set_transformation_hp`, one character-row lock, carry-over | **Reused unchanged.** The combat HP path delegates to them | — | — | DM allowed through `can_access_character` | None |
| Player conditions | `characters.conditions` (player list), `character_conditions` (DM-applied, `hidden`) | Shown read-only on the combatant; used for "Move to the sheet" at Finish (`apply_character_condition`) | — | As the store of combat effects: no rounds, turn anchors, source, concentration or advantage scope | Hidden rows stay hidden (existing RLS) | None |
| Resources, spell slots | `character_resources`, slot state | Not touched (no automatic resource spending in combat) | — | — | — | None |
| Companions | `character_companions` | Not added automatically (a DM can add a typed-in combatant) | Possible later | — | — | — |
| Creature catalog | `creatures` (334 SRD 5.1 + campaign custom), read by `_form_options` (Wild Shape) and `getCreatures()` (companion picker) | SRD 5.1 rows are used as **2014 monsters**. Campaign rows are used as **homebrew** | `creature_legendary_actions` (new) carries the SRD 5.1 Legendary Actions the table lacks | **Adding SRD 5.2.1 rows here**: every official beast becomes a Wild Shape option and every row a companion choice | Catalog rows are public SRD data | New table `combat_monsters` for SRD 5.2.1 (insert-only seed) |
| Custom creatures | `dm_content` type `creature` → `_dm_materialize` → `creatures` row `cc-<id>-v<n>`, versioned, archived, validated by `_dm_try` | **Reused** for homebrew monsters (draft, validate, publish, new version, archive) | `_dm_try` gets one line that adds `_combat_creature_errors` for definitions with `combat` | A separate homebrew table | DM-only authoring unchanged | `_dm_try` changed by one inserted line; the exact old text is in the rollback |
| DM Space | `js/dm-space.js` (`#/dm/...`), `get_my_dm_campaigns` | Navigation pattern, styles, campaign selector | — | Hosting combat inside DM Space (the task asks for a sibling destination) | — | — |
| Governance / locks | `_gov_gate`, `characters_governance` trigger | Yes (runtime.hp gate in the HP RPC) | — | — | Locks and dm_only rules still apply to HP changes | — |
| Hidden DM data | Rows a player's RLS never returns (`HIDDEN_DM_DATA.md`) | The principle is reused | — | — | All combat runtime tables are DM-only through RLS. Players get one filtering RPC (`get_combat_player_view`) | — |
| RLS | Per-table select policies, writes through RPCs | Pattern | — | — | No INSERT/UPDATE/DELETE grants on combat tables | — |
| Realtime | `characters` UPDATE + `character_revisions` INSERT per open sheet (2 bindings) | Both are reused by the tracker for linked characters | New `combat_changes` log (ids only) | One subscription per combat table/row | Realtime applies the select policy per subscriber, so players receive no combat rows | Publication: + `combat_changes` |
| Audit history | `dm_content_events`, `character_transformation_events`, campaign audit | Pattern | New `combat_events` (history, Undo, request ids) | — | DM-only | — |
| Progressive reads / read cache | `tl_cache` keyed by character and global counters. **Every public table must carry a `tl_cache_rev` trigger** (`progressive_read_tests.sql`) | `get_character_reads` (cached) is used for the DM's character summaries | A no-op trigger function `tl_cache.combat_skip()` for the runtime tables | Global-counter triggers on combat tables: every turn would invalidate every cached character read (the 57014 incident path) | — | Catalog tables use the normal global counter (seed only). Participants use `linked_character_id` so the "character tables" rule does not force the character counter |
| Cache revisions | `tl_cache.character_rev`, `global_rev`; `character_revisions` (append-only, prunes > 3 days) | Unchanged | Combat revisions: `combat_encounters.rev/turn_rev`, `combat_participants.rev`, `combat_effects.rev`, `combat_changes.id` | — | — | — |
| Frontend routing / navigation | Hash router in `js/app.js` (`#/`, `#/c/<id>`, `#/dm/...`), topbar `#dm-link` | Pattern | New `#/combat`, `#/combat/e/<id>`, `#/combat/library`; topbar `#combat-link` | — | The route is refused for non-DMs; the server refuses anyway | — |
| Icon registry | `js/icon-registry.js` (generated from `assets/icons/*.webp`) | Initiative, concentration, damage, heal, 10 SRD condition icons (the other 5 use the generic effect icon), reaction, creature, temp HP | Ten project-authored inline SVG glyphs (`js/combat-icons.js`) for concepts with no icon | The logo as a combat icon | Self-hosted, no runtime URL | — |
| Design tokens | `css/styles.css` `:root` (surfaces, gold accent, Cinzel display, Inter UI) | Yes | `css/combat.css` (cb- prefix) | — | — | — |
| Breakpoints | 480 / 520 / 560 / 640 / 720 / 760 / 900 px in use | 900 (drawer) and 600 (phone) | — | — | — | — |
| Test isolation | `supabase/tests/browser/isolation.py` (ui-* users, residue, digests) | Yes | Residue and cleanup include combat encounters and favorites | — | — | — |

## Findings that shaped the design

1. **Player HP had no server-side operation.** A DM changing HP while a player's sheet held an older value could be
   overwritten. The new `apply_character_hp` is the single atomic path. It locks the character row, uses Temporary HP
   first, clamps to the feat-aware maximum, resets death saves when healed from 0, and delegates to the Wild Shape
   functions while a form is active. The sheet's Damage/Heal buttons now use it and keep their messages ("Took 5
   damage…"). Typed HP values still save as before.
2. **Wild Shape leakage.** `_form_options` accepts every official creature of the right type. SRD 5.2.1 animals would
   have become duplicate 2014 Wild Shape forms. They therefore live in `combat_monsters`.
3. **Cache coupling.** A combat table with the default global trigger would bump `tl_cache.global_rev` on every turn and
   invalidate every cached character read. The combat runtime tables carry a no-op trigger instead, and a SQL test (X1,
   X2) proves combat writes change neither counter.
4. **Lock order.** No trigger on `characters` or any character table writes combat rows. Combat RPCs lock the encounter,
   then the participant, then the character (the Wild Shape functions lock the same row), then write events. The
   concurrency test runs combat HP, sheet HP, Wild Shape HP and turn moves together with zero deadlocks.
5. **Derived stats are expensive** (about 90 ms per character uncached). Encounter RPCs read stored rows only. The DM's
   AC / Initiative / Speed / passive Perception summary comes from the cached `get_character_reads`, after first paint.
