# Combat Builder data model

Migration `20261106000100_combat_builder_schema.sql` adds 11 tables and changes nothing that existed. Every runtime table is
readable only by the campaign's DM (and admins) and is written only by the `combat_*` RPCs ([COMBAT_PERMISSIONS.md](COMBAT_PERMISSIONS.md)).

```
campaigns 1─* combat_encounters 1─* combat_participants *─1 characters (linked_character_id, nullable, on delete set null)
                     │                   │  *─1 combat_statblocks (one snapshot per source + version per encounter)
                     │                   └─ current_participant_id (encounter -> participant, on delete set null)
                     ├─* combat_effects (target / source / anchor participant, concentration_id -> combat_effects)
                     ├─* combat_reminders
                     ├─* combat_events   (history, Undo, request ids)
                     └─* combat_changes  (Realtime log: ids only)
combat_monsters (SRD 5.2.1)   creature_legendary_actions (SRD 5.1)   combat_conditions (2014 / 2024)   combat_monster_favorites
```

## Catalogs (read only for clients)

| Table | Rows | Key columns |
|---|---|---|
| `combat_monsters` | 73 SRD 5.2.1 stat blocks (seed) | `id` (`srd52-…`), `rules_version`, size, type, AC, HP + hit dice, `initiative_modifier` + `initiative_score`, speed, CR, XP, PB, `legendary_uses`, `statblock` (the full normalized block), `source_label`, `source_ref`, `source_url`, `license`, `attribution_required`, `archived_at` |
| `creature_legendary_actions` | 32 (seed) | `creature_id` → `creatures` (SRD 5.1), `uses`, `actions [{name, cost, text}]` |
| `combat_conditions` | 30: 15 per ruleset (in the migration) | `(ruleset, key)`, name, project-authored summary, `incapacitating`, `initiative` (2024 Advantage/Disadvantage), `leveled` (Exhaustion), icon, `source_ref` |
| `combat_monster_favorites` | per user | `(user_id, monster_ref)`, ref `srd52:<id>` or `creature:<id>` |

SRD 5.1 creatures (`creatures`, `content_scope = 'official'`) and published campaign homebrew (`content_scope = 'campaign'`)
come from the existing table. Nothing was added to it.

## `combat_encounters`

| Column | Notes |
|---|---|
| `campaign_id` | authority: the campaign's DMs (admins) |
| `name`, `description`, `dm_notes`, `finish_notes` | `dm_notes` is never part of any player read |
| `ruleset` | `2014` or `2024`, always concrete. `ruleset_source = campaign_default` when "Campaign default" was chosen |
| `status` | `draft` → `active` ⇄ `paused` → `completed`. `archived_at` is separate (any non-running state) |
| `is_template`, `source_encounter_id` | reuse: a duplicate is a new draft pointing at its source |
| `round`, `current_participant_id`, `turn_rev` | turn position; `turn_rev` increases with every turn move (the expected value of Next / Previous) |
| `rev`, `updated_at` | structure revision (participants added, settings …). Optimistic check of `combat_update_encounter` |
| `settings` | `hp_mode` (`average`/`rolled`), `player_enemy_hp` (`state`/`none`/`exact`), `fixed_initiative`, `manual_order`, `ties_confirmed` |
| `started_at`, `paused_at`, `resumed_at`, `active_seconds`, `completed_at` | elapsed combat time excludes paused time; nothing is applied for real time that passed |
| `summary` | written by `combat_finish` |

## `combat_statblocks`

One **snapshot** per (encounter, source kind, source id, source version). All copies of a monster share it, and later
catalog edits or homebrew versions never change it. `source_kind` is one of:
- `srd2024`: `combat_monsters`;
- `creature`: SRD 5.1;
- `homebrew`: published campaign creature (the version id is the `dm_content_versions` id);
- `custom`: typed in for this encounter.

**Stat block snapshot** (normalized by `_combat_source` for every source):
- `name`, `size`, `size_text`, `creature_type`, `subtype`, `alignment`;
- `armor_class`, `armor_type`, `hit_points`, `hit_dice`, `initiative {modifier, score}`, `speed`;
- `abilities`, `saving_throws`, `skills`, `senses`, `languages`;
- `challenge_rating`, `xp`, `proficiency_bonus`;
- `damage_resistances`, `damage_immunities`, `damage_vulnerabilities`, `condition_immunities`;
- `traits`, `actions`, `bonus_actions`, `reactions` (each entry has `text` plus structured attack, save, damage and usage
  data);
- `legendary {uses, uses_in_lair, actions [{name, cost, text}]}`, `spellcasting`;
- `source_kind`, `source_id`, `source_version`, `rules_version`, `source_label`, `source_ref`, `license`,
  `attribution_required`, `homebrew`.

## `combat_participants`

| Column | Notes |
|---|---|
| `kind` | `character` or `monster` |
| `linked_character_id` | characters only; **HP lives on `characters`**. The participant has no HP of its own (`hp_*` null). Named `linked_…` on purpose: the read-cache coverage rule would otherwise force the character counter on this table |
| `statblock_id` | monsters |
| `display_name`, `instance_label`, `player_label`, `group_key` | "Goblin Warrior" + "B"; `player_label` is the disguise for a future player view; `group_key` = one Initiative roll for the group |
| `initiative`, `initiative_mod`, `initiative_roll`, `initiative_mode`, `initiative_tiebreak`, `initiative_order` | the order is `initiative_order` (steps of 10) |
| `hp_current`, `hp_max`, `hp_temp`, `armor_class` | monsters only: the instance's own values |
| `active`, `removed_at` | "skip its turns" vs removed (history kept) |
| `hidden`, `revealed_at`, `joins_round` | hidden from players; delayed entry |
| `defeated`, `surprised`, `turns_taken`, `reaction_used`, `legendary_max`, `legendary_left` | turn state |
| `notes`, `rev` | DM notes; revision |

A character can be in an encounter once (unique while not removed). A deleted character leaves its participant row
(name and history) with `linked_character_id = null`.

## `combat_effects`

One row per applied condition, custom effect, advantage state or concentration.

| Column | Notes |
|---|---|
| `effect_type` | `condition` (with `condition_key`, `exhaustion_level`), `custom`, `advantage` (`adv_mode`, `adv_scope`, `adv_detail`, `adv_target_id`), `concentration` |
| `target_participant_id`, `source_participant_id` | |
| `visibility` | `players` or `dm` (hidden effect) |
| `application` | `applied` only for AC and Speed modifiers (shown in the tracker's numbers); everything else is `reminder` |
| `duration_type` | `indefinite`, `rounds` (also minutes × 10), `until_turn_start`, `until_turn_end`, `save_ends` |
| `duration_rounds`, `remaining_rounds`, `anchor_participant_id`, `expires_on` | the clock ticks at the anchor's turn start or end |
| `save_ability`, `save_dc`, `save_timing` | repeated save reminder |
| `concentration_id` | link to the caster's concentration effect; ending it ends the linked effects |
| `modifier_target`, `modifier_value`, `defense_kind`, `defense_type` | modifiers and Resistance/Immunity/Vulnerability reminders |
| `pending_checks` | concentration checks waiting for the DM (`{id, dc, damage, event_id}`) |
| `active`, `ended_at`, `ended_reason`, `rev` | `expired`, `removed`, `concentration_ended`, `save_succeeded`, `encounter_finished`, `carried_to_sheet`, `undo`, `source_removed` |

## `combat_reminders`

- `kind`: `lair`, `hazard`, `reinforcement`, `environment` or `custom`.
- `title`, `note`, `trigger_round`, `trigger_initiative`, `repeat_every`, `hidden`, `active`.
- `last_fired_round`: once per round.
- `acknowledged_round`: the DM's Done.

## `combat_events`

The history, Undo and duplicate protection, one row per accepted mutation:
- `kind`, `participant_id`, `round`, `before`, `after`, `details`;
- `result`: the stored answer for a replay;
- `request_id`: unique per encounter;
- `undoable`, `undone_by`, `undo_of`.

## `combat_changes`

The Realtime log: `encounter_id`, `domain` (`encounter`, `turn`, `participants`, `hp`, `effects`, `reminders`), `kind`,
`participant_id`, `player_visible`, `changed_at`. It carries **no names, HP or notes**. About 2 % of writes prune rows
older than 3 days (`skip locked`).

## Indexes

| Index | Hot path |
|---|---|
| `combat_encounters_campaign_status (campaign_id, status, updated_at desc)` | Combat Home |
| `combat_encounters_running (campaign_id) where status in (active, paused)` | running encounters of a campaign |
| `combat_participants_encounter (encounter_id, initiative_order, created_at)` | the order |
| `combat_participants_character (linked_character_id) where not null` | linked characters |
| `combat_participants_one_per_character` (unique, partial) | a character once per encounter |
| `combat_statblocks_source` (unique, partial) | snapshot reuse |
| `combat_effects_target_active`, `combat_effects_concentration`, `combat_effects_anchor` (partial, `active`) | effects of a target, linked effects, clocks of a turn |
| `combat_events_encounter (encounter_id, id desc)`, `combat_events_request (encounter_id, request_id)` unique partial | history page, replay |
| `combat_changes_encounter (encounter_id, id desc)`, `combat_changes_changed_at` | reconnect summary, pruning |
| `combat_monsters_cr`, `combat_monsters_type` | library filters |

Plans on a realistic fixture are in `supabase/tests/combat_query_plans.sql`. At that size every hot path is an index scan
or a scan of a few hundred rows. Server times (inside SQL):

| RPC | Time |
|---|---|
| `combat_get_encounter` (20 combatants, 30 effects) | 27.6 ms |
| `combat_next_turn` | 3.0 ms |
| `combat_apply_hp`, monster | 1.8 ms |
| `combat_apply_hp`, character | 10.5 ms |
| `combat_add_effect` | 1.1 ms |
| `combat_get_history`, 50 of 450 | 2.1 ms |
| `combat_monster_library` search | 3.6 ms |

## Read-cache counters

- **Catalog tables** carry the normal `tl_cache_rev` trigger in `global` mode; they change only when the seed is loaded.
- **The eight runtime tables** carry `tl_cache_rev` → `tl_cache.combat_skip()`, a no-op. No cached character read reads
  them, so turns and monster HP never invalidate character caches. Linked character HP changes are runtime columns,
  which `tl_cache.bump` already ignores. Tests X1–X3 in `combat_builder_tests.sql` cover this.
