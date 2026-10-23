# Character creation audit: Race, Lineage and new characters (2026-10-22)

Scope: every place that reads or writes the old free-text **race** or the structured **lineage**, what is authoritative,
and how new characters are created since the UI refinement. Related: `docs/LINEAGES.md`, `docs/UI_REFINEMENT_REVIEW.md`.

## Fields

| Field | Where | Role |
|---|---|---|
| `character_lineages` (lineage, version, sub-lineage, ability-bonus flag) + `character_lineage_choices` | migration 20261015001500 | **Authoritative.** The only source of lineage mechanics (`get_character_lineage`, `get_character_derived_stats`, proficiency resolver). Written only through `set_character_lineage` / `clear_character_lineage`, which pass the campaign governance gate (`build.lineage`) and the content policy. |
| `characters.race` (`text not null default ''`) | base schema 20261015000000 | **Legacy compatibility / narrative text.** No SQL function derives mechanics from it (checked: derived stats, proficiency resolver and class / spell engines read only the lineage tables; the `'race'` value in `character_effects.source_type` and the resolver is an old source-type label, not this column). Changes are governed as `identity.descriptive` (player managed). |
| `lineage_versions` / `v_lineage_catalog` | 20261015001500, custom lineages 20261019000400 | The canonical, versioned catalog (official, legacy, setting-specific, campaign custom). |

Nothing was removed or migrated in the database. No schema or RPC change was needed.

## Every use of race (before → after)

| Place | Before | After |
|---|---|---|
| New character dialog (`js/app.js`) | free-text **Race** field next to free-text Class | no Race field; steps Identity → Lineage → Lineage choices → Class → Review using the canonical pickers |
| Build → Lineage card (`js/sheet.js`, `js/lineage-ui.js`) | "Race (free text, used only without a lineage)" input shown as an active field | callout "Legacy race has not been mapped to a Lineage" (only while no lineage is chosen), exact-name suggestion with **Review …**, otherwise **Choose lineage…**; the text itself is editable only in a folded "Legacy race text (kept, grants no traits)" detail |
| Sheet subtitle (`subtitle()`) | lineage name, else race text | unchanged: lineage name; the legacy text only while no lineage exists (display only) |
| Home card (`characterCard`) | lineage, else race | unchanged (display only) |
| Bio | no race field | no race field |
| Export (`js/transfer.js`) | `race` = lineage label when a lineage existed, else the text | `race` only when the character really has legacy text; `lineage` carries `lineageId`, exact `version`, `subversion`, choices, `name`, `versionLabel` |
| Import | `race` stored; lineage applied best effort, silently | exact lineage version applied; on failure the readable name is kept as legacy race text and a warning is shown; a file with only `race` keeps it as unmapped text and warns. Old exports (whose `race` was a copy of the lineage label) do not create a duplicate legacy race |
| Import preview | shows race | unchanged (shows the file's text) |
| Demo seeder (`scripts/local/seed_local_demo.py`) | writes race text for demo characters, some also get a lineage | unchanged: the demo characters deliberately include legacy-race-only characters (for example Showcase Paladin "Human") that exercise the legacy path |
| Browser tests | `lineage_ui_test` 18b expected the label in `race` | updated: `race` is the preserved legacy text, the lineage name is in `lineage.name` |

## Rules applied

1. New characters never get race text from the app (`race: ''`); their lineage is the exact catalog version chosen in step 2.
2. Legacy race text is never deleted, never converted silently and never grants mechanics.
3. A **suggestion** is offered only for a reliable mapping: the text equals exactly one catalog lineage name (case, spaces and
   hyphens ignored). "Human", "Gnome", "Dwarf" are suggested; "Wood Elf", "High Elf", "Half-Orc (Mark of Finding)" are not
   (ambiguous: base lineage, sub-lineage and version would be guesses).
4. Accepting a suggestion opens the normal lineage picker on that lineage: the player sees the version, the traits (the
   mechanical preview) and the choices before saving. The save is the normal `set_character_lineage` call, so campaign
   governance decides: initial setup → direct; set-up campaign character under the standard / strict preset → refused with
   "needs approval" and the sheet offers **Ask your DM** (request flow). Legacy, setting or custom content follows the
   campaign content policy (shown in the picker, enforced by the server).
5. A DM may assign anything (the server allows it and audits it); the picker says "(you are the DM: allowed for you)".

## Local data at task start

35 characters; race text values: empty 15, Human 8, Wood Elf 2, Half-Elf 2, Gnome 2, Tiefling 1, Halfling 1, High Elf 1,
Half-Orc 1, Dragonborn 1, Dwarf 1. Characters without a lineage but with race text show the legacy callout; with the exact
rule (checked against the local catalog), Human, Gnome, Tiefling, Halfling, Half-Elf, Half-Orc, Dragonborn and Dwarf each match
exactly one lineage and get a suggestion; Wood Elf and High Elf match none (they are sub-lineage names) and get "choose it
yourself".

## Not changed (deliberately)

- The `race` column stays (compatibility, display, export of old characters).
- The full future character-creation wizard (ability score generation, background, equipment, spells) is not part of this
  task; the new flow covers identity, lineage, lineage choices, class and a review, and everything else stays on Build.
