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
| `characters` | identity, HP, AC, speed, ability scores, `save_proficiencies` `{"str": true}`, `skill_proficiencies` `{"stealth": {"proficient": true, "expertise": false}}`, `equipment_proficiencies`, `conditions` (jsonb array), `portrait_url` |
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
