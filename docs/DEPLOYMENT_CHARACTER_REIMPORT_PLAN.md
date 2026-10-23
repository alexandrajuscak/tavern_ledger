# Deployment: legacy character reimport plan (2026-10-23)

## Evidence: local pilot with the user's own legacy files

`supabase/tests/browser/legacy_import_pilot_test.py` imported the six level-2 legacy exports from the local `examples/`
folder (schema version 1, pre-V6 app). It used the real import dialog against the **local** stack, as a synthetic user,
inside the isolation harness (all rows removed and verified afterwards). The report was written outside Git:
`tavern-ledger-local-backups/v62-adversarial-2026-10-23/legacy_import_pilot.json`.

**Result: 6 / 6 imported, no page errors, no external requests.** Every file showed the same pattern:

| Character | Legacy class / level | Legacy race | Imported as | Needs |
|---|---|---|---|---|
| Character A | Monk 2 | Wood Elf | name, scores, HP 15/15, background text "Hermit", 16 inventory rows, 3 attacks, 16 features, 3 reminders | lineage, class engine (Monk 2), background, review the inventory (16 rows from 7 entries) |
| Character B | Bard 2 | Dwarf | HP 15/21, 7 items, 6 legacy spells, 9 reminders | lineage, class (Bard 2), background, spells from the catalog, runtime HP policy |
| Character C | Artificer 2 | Human | 14 items, 6 legacy spells, 6 reminders | lineage, class (Artificer 2), background, spells, infusions |
| Character D | Paladin 2 | Human | 10 items, 4 reminders | lineage, class (Paladin 2), background, Fighting Style choice |
| Character E | Druid 2 | Lizardfolk | 9 items, 7 legacy spells, 9 reminders | lineage, class (Druid 2, subclass at 2), background, spells, Wild Shape seen forms |
| Character F | Warlock 2 | Drow (Dark Elf) | 14 items, 6 legacy spells, 6 reminders | lineage, class (Warlock 2), background, spells, invocations |

What the importer does with a legacy file (verified):

- **Race** stays as legacy text, with the warning "choose the lineage on Build". It is never silently mapped.
- **Class**: a legacy file has no class version, so the class stays as text (`class_name`). Nothing is switched on in the
  class engine until the class is chosen on Build.
- **Background** stays as text until a background version is chosen.
- **Spells** are kept as free-text spell rows. Catalog spells must be added from the spell list. Remove the old rows
  after that.
- **Inventory** rows are all created.
- **Reminders** (pending choices) are kept.
- **Maximum HP, AC, proficiency and spell slots** are recalculated by the engines once the class and lineage are set. The
  imported numbers are never authoritative.

The production exports (Phase C) will be checked the same way, file by file, before the destructive or switching phase.

## Order per character (in the production app)

1. The account exists (the player or the DM) and is a member of the campaign. The campaign is created first by the DM.
2. **Import** the file (home → Import file): campaign = the target campaign; owner = the player (the DM / admin owner
   field).
3. **Lineage**: Build → Lineage → the canonical lineage (e.g. "Wood Elf" → Elf, Wood Elf subrace) with its choices.
4. **Background**: Build → Background → the version (2014 or 2024) and its choices.
5. **Class**: Build → Classes → class version and level (e.g. Monk 2). Subclass if the level gives one. Then the class
   choices (Fighting Style, invocations, Wild Shape forms…).
6. **Feats**, if any.
7. **Spells**: add the catalog spells per source, then delete the legacy free-text spell rows.
8. **Inventory**: compare with the original. Equip armour and weapons and attune magic items.
9. **Custom content**: if the character needs homebrew, the DM creates and publishes it in DM Space and assigns it.
10. **Reminders**: resolve or delete each one.
11. **Derived values**: check maximum HP, AC, attack bonuses, save DC and slots against the paper sheet. "How this is
    calculated" explains each value.
12. **Runtime state**: apply the policy below.
13. **DM review**: the DM opens the character from DM Space → Party.
14. **Export** the new version (Bio → Download) and store it with the original.

## Runtime-state policy (default for the rebuild)

| State | Policy |
|---|---|
| Build, owned items, prepared spells | preserved where valid |
| Maximum HP, AC, proficiency, slot maxima, form HP | recalculated, never imported |
| Current HP | **full** (a long-rest start) |
| Temporary HP, death saves, conditions, inspiration | cleared |
| Spell slots and resources used | restored |
| Active Wild Shape | ended (the importer always imports in normal form) |
| Equipment / attunement | kept where valid (re-equip if the item was matched to a different catalog item) |
| Hidden / custom content | DM review |

The pilot showed that the importer **keeps** the legacy current HP (Character B: 15/21). Applying the policy is a manual step:
Rest → Long rest after the class is set. It is a checklist item, not an importer change.

## Pilot first

In production, **one** character is imported and completed first (steps 1–14). It is then exported again and compared
with its original manifest entry, and persistence is checked (sign out, sign in, reopen). The remaining characters
follow only after the user approves, one at a time or in small batches.
