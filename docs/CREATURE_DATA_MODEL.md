# Creature data model

`public.creatures` is a read-only catalog. RLS allows anyone to read it, and no client can write it. One row per
creature:

| Column | Type | Notes |
|---|---|---|
| `id` | text | SRD index, e.g. `brown-bear` |
| `name`, `size`, `creature_type`, `subtype`, `alignment` | text | |
| `armor_class`, `armor_type` | int, text | natural armor etc. |
| `hit_points`, `hit_dice` | int, text | the form maximum in Wild Shape |
| `speed` | jsonb | `{"walk": 40, "climb": 30, "swim": …, "fly": …, "burrow": …, "hover": bool}` |
| `abilities` | jsonb | `{"str": 19, …}`; STR / DEX / CON replace the character's in a form |
| `saving_throws`, `skills` | jsonb | the printed bonuses (candidates for the best-of rule) |
| `senses` | jsonb | `{"darkvision": 60, "passive_perception": 13, …}` |
| `challenge_rating`, `xp`, `proficiency_bonus` | numeric, int, int | |
| `damage_vulnerabilities`, `damage_resistances`, `damage_immunities`, `condition_immunities` | text[] | |
| `traits`, `actions`, `reactions`, `legendary` | jsonb arrays | see below |
| `mechanics_status` | text | `complete` / `partial` / `informational`. Only `complete` forms can be taken |
| `mechanics_notes` | text | what is unresolved |
| `source_label`, `source_url`, `license` | text | `SRD 5.1`, `CC-BY-4.0` |

## Action object

```json
{"name": "Web", "kind": "ranged", "attack_bonus": 5, "range": [30, 60], "targets": "one creature",
 "save": {"dc": 12, "ability": "STR", "kind": "check"},
 "conditions": ["restrained"], "usage": {"type": "recharge on roll", "dice": "1d6", "min_value": 5},
 "summary": "Ranged attack; on a hit the target is restrained by webbing. …"}
```

- **`multiattack`:** `[{"action": "Bite", "count": 1}, …]` on the Multiattack entry.
- **`usage.type`:** `recharge on roll`, or `recharge after rest` (with `rest_types`).
- **`attack_bonus`:** present only when the text is an attack.

## Trait object

```json
{"name": "Keen Smell", "group": "senses", "summary": "Advantage on Wisdom (Perception) checks that rely on smell.",
 "automation": "informational"}
```

**`group`** is one of `combat`, `movement`, `senses`, `defense` or `utility`.

## Character-side tables

These are introduced by `20261017001300`. All of them are readable through `can_access_character` and have no client
write grants. They change only through RPCs.

| Table | Purpose |
|---|---|
| `character_transformations` | the active form (one per character), as described below |
| `character_wild_shape_settings` | `seen_mode`, `default_equipment`, `confirm_lethal` |
| `character_seen_forms` | `(character, creature)` with `source` seen / dm_grant / fixture / import and a note |
| `character_form_favorites` | starred forms |
| `character_transformation_events` | history: `transformed`, `damaged`, `healed`, `combat_healing`, `excess_damage`, `reverted_manual`, `reverted_zero_hp`, `reverted_expired`, `ability_used`, `ability_recharged`, `equipment`, `settings`, `seen_added`, `seen_removed` (and the other types in the table check), with before / after / metadata |

`character_transformations` holds:
- `hp_current`, `hp_max` and `hp_temp`;
- the normal HP snapshot;
- `max_duration_minutes` and `expires_at`;
- `elemental`;
- `equipment {mode, items, dropped}`;
- `action_state`;
- `seen_status` and `notes`.

`character_transformations` is in the Realtime publication.

<!-- 20261019 governance/feats/content -->
## Campaign creatures (20261019000400)

`creatures` gains `owner_id`, `campaign_id`, `wild_shape_eligible`, `companion_eligible`, `archived_at` and
`content_version_id`; rows with `content_scope = 'campaign'` are visible to campaign members only.
`character_companions.template_version_id` links a companion to the DM template it came from
([CUSTOM_CREATURES.md](CUSTOM_CREATURES.md), [CUSTOM_COMPANIONS.md](CUSTOM_COMPANIONS.md)).
