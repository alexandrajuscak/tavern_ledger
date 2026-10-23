# Character proficiencies (weapons, armor, shields, tools)

Structured equipment proficiencies used by the derived stats
([DERIVED_CHARACTER_STATS.md](DERIVED_CHARACTER_STATS.md)). Saving throw and skill proficiencies are unchanged
(`characters.save_proficiencies`, `skill_proficiencies`). Languages and other notes stay in the free-text
`characters.proficiencies`.

## Tables

`proficiency_groups` (lookup, readable by everyone):

| id | Type | Matches |
|---|---|---|
| `simple-weapons` | weapon | `weapon_stats.weapon_group = 'simple'` |
| `martial-weapons` | weapon | `weapon_group = 'martial'` |
| `firearms` | weapon | `weapon_group = 'firearm'` |
| `light-armor`, `medium-armor`, `heavy-armor` | armor | the armor's `category_id` |
| `shields` | shield | category `shield` |

`character_proficiencies`: one row per character and **either** a group **or** one specific catalog item (a weapon,
armor, shield or tool). Columns: `proficiency_type`, `group_id` / `item_id`, `source_type` (`manual`, `sheet`,
`import`, `class`, `race`, `background`, `feat`, `item`), `source_id`, `notes` (≤ 500), `created_by`, `created_at`.
Unique per character and group, and per character and item. A trigger checks that the type matches the group or item.

## Matching

`_proficiency_match(character, item, base_item, group)`: a specific proficiency for the item **or its base item**
wins; otherwise the group; otherwise `{proficient: false, missing_group_id, missing_group_name}`. So a proficiency in
"Longsword" covers a +1 Longsword, and "Martial Weapons" covers every martial weapon.

Tools have no groups: a tool counts as proficient only with a specific tool proficiency. A tool without proficiency
stays in the inventory without a warning and is listed as "not proficient" on the Stats tab.

## Writing

Clients can only read `character_proficiencies` (RLS: `can_access_character`, so the owner, the campaign DM and an
admin). The only write path is:

```
set_character_proficiency(p_character uuid, p_group text default null, p_item text default null,
                          p_enabled boolean default true, p_notes text default null) returns jsonb
```

Exactly one of `p_group` / `p_item`. Idempotent: adding an existing proficiency or removing a missing one returns
`changed: false`. Errors: `42501` for a character the caller can't access, `22023` for an unknown group or item,
an item that is not a weapon, armor, shield or tool, or notes that are too long.

## Legacy flags

`characters.equipment_proficiencies` (`{light, medium, heavy, shields, simple, martial, firearms}`) is the old store.
The migration copied the existing flags into `character_proficiencies` (`source_type = 'sheet'`). Two triggers keep
them in sync both ways (`proficiency_groups.legacy_flag` maps the keys), so JSON import/export (`js/transfer.js`) and
older cached sheets keep working. Specific item proficiencies have no legacy flag.

## UI

Stats tab: one chip per group (Firearms is new) and a "Manage proficiencies" dialog to search for and add or remove
specific weapons, armor, shields and tools. Changes refresh the derived stats immediately and reach other open
sheets over Realtime (`character_proficiencies` is in the `supabase_realtime` publication).

## Lineage proficiencies (migration 20261015001500)

A selected lineage grants proficiencies through its effects (groups, specific weapons, armor, tools, skills). They are
**not** stored in `character_proficiencies`: `_proficiency_match` and the derived `proficiencies` list resolve them from
the selection with `matched_by` / `source_type = 'lineage'`. Changing or removing the lineage removes exactly those
grants; a manual row for the same group or item keeps the proficiency. Lineage skills show as dashed dots on the Stats
tab and count in the skill bonus. See [LINEAGES.md](LINEAGES.md#proficiencies-and-origins).

## Not modeled

Nothing is inferred from class, background or feats. Lineage grants are resolved as described above.
