# Character Shell contract (release 2026-10-30, migration 20261030000100)

The Character Shell is the part of `get_character_view` that every mounted sheet needs. It is not a new rules engine: each
section is the unchanged output of an existing read (RPC or table query), returned together in one transaction with one
rules evaluation per security context. Domain bundles (Spells, Inventory): `docs/CHARACTER_DOMAIN_BUNDLES.md`.

## Request

```
POST /rest/v1/rpc/get_character_view   { "p_character": "<uuid>", "p_tab": "combat|stats|spells|inventory|features|bio" }
```

`SECURITY INVOKER`, `search_path = public, pg_temp`, execute granted to `authenticated` (and `service_role`), revoked from
`anon` and `public`. Unknown tab → `22023`. Character not readable by the caller (unrelated user, deleted, anonymous) → `42501`
before any read runs (`can_access_character`).

## Response (contract 1)

```json
{
  "contract": 1,
  "character_id": "<uuid>",
  "tab": "combat",
  "server_ms": 61,
  "reads":  { "<read name>": <value>, ... },
  "errors": { "<read name>": { "code": "<SQLSTATE>", "message": "..." } }
}
```

A read that fails on its own (for example a feature-engine error for one character) is reported in `errors` and the rest
still arrives; the client lets that loader read again on its own, exactly as before. A statement timeout (`57014`) is never
caught per read: it fails the whole request.

## Shell reads (`_character_read_set('shell')`)

| Read | Source (unchanged) | Used for |
|---|---|---|
| `characters` | `characters` row (`select *` as before) | identity, vitals (HP, temp HP, death saves, inspiration, coins), portrait, campaign, revision `updated_at` |
| `inventory_items`, `notes`, `spell_slots`, `feature_trackers`, `features`, `attacks`, `spells` | the stored rows of `js/store.js loadBundle`, same order | legacy lists, Bio notes, trackers |
| `get_character_derived_stats` | rules engine | AC, initiative, speed, max HP, proficiency bonus, abilities, saves, skills, attacks, senses |
| `get_character_proficiencies` | proficiency resolver | Abilities chips |
| `get_character_lineage`, `get_character_background`, `get_character_feats` | lineage / background / feat engines | Build cards, sheet chips, open choices |
| `get_character_class_summary`, `get_character_spell_slots`, `get_character_class_features`, `get_character_resources`, `get_character_states` | class engine | class line, slots, Play features and resources, states |
| `get_character_transformation`, `companions` | Wild Shape engine, `character_companions` + creature | active form (vitals), Wild Shape panel, companions |
| `get_character_infusions`, `starting_equipment_applied`, `primary_class_starting_equipment` | infusions, starting equipment | Build |
| `get_character_governance`, `get_character_change_requests` (open only) | governance | permission (`is_dm`), lock, approvals, decisions |
| `revisions` | `character_revisions` (max id per table) | revision metadata: `{source_table: rev}` (see invalidation model) |

`p_tab = 'spells'` adds `get_character_spellbook`; `p_tab = 'inventory'` adds `inventory_bundle`.

## Field groups required by the brief

| Group | Where in the response |
|---|---|
| Identity: id, name, portrait, campaign | `reads.characters` (`id`, `name`, `portrait_url`, `campaign_id`); campaign name in `reads.get_character_governance.campaign_name` |
| Ownership / actor relationship | `characters.owner_id` vs. the signed-in user; `get_character_governance.is_dm` |
| Lock, approval state | `get_character_governance.lock_mode/lock_reason/decisions`; open requests in `get_character_change_requests` |
| Incomplete choices | `characters.pending_choices`, lineage/background/feat/class `choices` with status |
| Active Wild Shape summary | `get_character_transformation.active` (and the derived `wild_shape` layer) |
| Vitals | `characters.hp_current/hp_temp`, `derived.hit_points.max`, `derived.armor_class`, `derived.initiative`, `derived.speed`, `derived.proficiency_bonus` |
| Revisions | `reads.revisions` (per source table), `characters.updated_at` |

Not included: catalog descriptions, the item/spell catalog, DM-only notes, hidden conditions, unrevealed item details, audit
history. Hidden data cannot appear: every section is the existing RLS-filtered read, run as the caller.

## Size and cost (measured)

| Measure | Value | Budget |
|---|---|---|
| Rules evaluations per view | 1-2 (invoker + SECURITY DEFINER callers each share one) | ≤ 2 (tested) |
| Response size, production characters | see `docs/FLUENCY_BENCHMARKS.md` §1 | ≤ 300 KB uncompressed |
| Reads per view | 26 (+1 for Spells / Inventory) | ≤ 40 (enforced: `22023`) |

## Compatibility

Additive: every old read RPC stays and behaves identically; the legacy frontend path (`FLUENT_READS = 'off'`) keeps working
against the new database. Version field `contract` changes only with an incompatible shape change.
