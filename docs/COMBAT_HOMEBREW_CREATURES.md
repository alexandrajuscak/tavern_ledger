# Combat Builder: homebrew creatures

Homebrew monsters use the **existing DM content lifecycle** ([CUSTOM_CONTENT_LIFECYCLE.md](CUSTOM_CONTENT_LIFECYCLE.md),
[CUSTOM_CREATURES.md](CUSTOM_CREATURES.md)). That is content type `creature`, with draft → validate → publish → new version
→ archive, materialized into `creatures` (`cc-<id>-v<n>`, `content_scope = 'campaign'`). The Combat Builder adds an
editor and conditional validation; there is no second homebrew system.

## Where

- **Monster Library → + New homebrew creature.** This is the dialog inside an encounter, or the `#/combat/library` page.
- **A homebrew row in the library → Edit (new version).** Published content is never edited in place: a new draft
  version is started (`new_dm_content_version`).
- The DM Space Content Library still edits the same content with its general form. Definitions written there have no
  `combat` marker and keep the old validation.

## Two modes

**Quick creature.** This is the default, for a simple enemy. Fields:
- name, size, type, rules (2014/2024), CR and XP (for the 2024 difficulty estimate);
- HP and hit dice, AC, walking Speed;
- Dexterity and an optional Initiative modifier;
- **one basic attack**: name, melee or ranged, to-hit, reach or range, damage formula and type, notes.

The other ability scores default to 10. The editor says so, and the full stat block can change them.

**Full stat block.** Everything in Quick, plus:
- alignment, armor text, fly / swim / climb / burrow speeds;
- all six abilities, saving throws (only for proficient saves);
- skills, darkvision, Passive Perception, languages;
- resistances, damage immunities, vulnerabilities, condition immunities;
- traits;
- Actions, Bonus Actions and Reactions, each with:
  - kind: melee, ranged, saving throw effect, or other/text;
  - to-hit, reach or range, save ability and DC, damage formula and type;
  - "no damage", recharge (2–6), notes;
- **Legendary Actions**, when switched on: uses 1–5 and options with a cost of 1–3;
- **Spellcasting**, when switched on: ability, save DC and/or spell attack bonus, a spell list text;
- DM notes (never shown to players).

**Only relevant fields are shown.**
- An attack shows a to-hit, a save effect shows ability and DC, a ranged attack shows a range.
- The recharge roll appears only when Recharge is ticked.
- The Legendary and Spellcasting sections appear only when switched on.

Fields that are hidden or switched off are dropped from the definition before saving, so they can never block save or
publish. A live **preview** renders the stat block exactly as the tracker will.

## Validation (server, authoritative)

`_dm_try` (the validation that also runs at publish) gained one line. For a creature definition with `combat`, it adds
the messages of `_combat_creature_errors(definition)`. Messages are friendly and name the action:

| Rule | Applies when | Message (example) |
|---|---|---|
| size, type | always | "Choose a size." |
| a Speed | always | "Give a Speed (walking or another movement, in feet)." |
| Initiative modifier −10…+20 | when given | "The Initiative modifier is -10 to +20." |
| to-hit bonus | melee or ranged attack | "\"Claw\": an attack needs a to-hit bonus." |
| damage formula | damaging attack (not "no damage") | "\"Claw\": a damaging attack needs a damage formula (e.g. 1d6+2)." |
| formula format | when a formula is given | "\"Claw\": the damage formula looks like 1d6+2." |
| range | ranged attack | "\"Shortbow\": a ranged attack needs a range." |
| ability + DC | saving throw effect | "\"Breath\": a saving throw effect needs the ability and the DC." |
| recharge 2–6 | Recharge ticked | "\"Breath\": choose the recharge roll (2 to 6)." |
| one basic attack | Quick mode | "A quick creature needs one basic attack (name, to-hit and damage)." |
| uses 1–5, ≥ 1 option, names, cost 1–3 | Legendary Actions on | "Legendary Actions: add at least one option." |
| ability, DC or attack bonus, spells | Spellcasting on | "Spellcasting: list the spells." |

The existing creature checks still apply: AC, HP, the six abilities, and catalog constraints translated into readable
text. Database wording (constraint names, columns) never reaches the DM.

## Publishing and versions

- **Publish.** The editor validates first, then calls `publish_dm_content`. The creature appears in the campaign's
  library as **Homebrew**. Only the currently published version is listed.
- **New version.** Version 2 is a new catalog row (`…-v2`); version 1 stays for whatever uses it.
- **Snapshot integrity:**
  - an encounter that already added version 1 keeps its **snapshot** (HP 22 stays 22);
  - new additions get version 2;
  - **Duplicate** (run again) takes the current published version for each homebrew monster;
  - SQL tests B9–B14.
- **Archive.** It can no longer be added to encounters ("…is archived. Restore it in DM Space before adding it."), and
  existing snapshots are unaffected.
- **Wild Shape and companions.** A homebrew combat creature is saved with `wild_shape_eligible = false`, so it never
  becomes a Wild Shape option by accident (the DM can still grant one from DM Space).

## Combat data kept outside the catalog row

`creatures` has no columns for Initiative, Bonus Actions, Legendary Actions or spellcasting. These stay in the version's
`definition`. `_combat_source` reads them through `content_version_id` when the snapshot is taken. Nothing in the
existing catalog changes.

## CR and XP

There is no automatic CR estimate. The DM chooses the CR and may give XP. Homebrew without XP is listed in the
difficulty estimate as "not counted".
