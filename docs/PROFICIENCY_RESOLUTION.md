# Proficiency resolution

How a character's effective proficiencies are resolved and shown (2026-10-17). Migration
`20261017001100_proficiency_resolver.sql`, read model `get_character_proficiencies`, UI `js/proficiency-ui.js`, tests
`supabase/tests/classes/proficiency_tests.sql` (20 checks) and `supabase/tests/browser/proficiency_ui_test.py` (12 checks).

## Audit (before)

| Source | Stored as | Resolved by the server | Shown by the UI |
|---|---|---|---|
| Manual weapon / armor groups | `character_proficiencies` rows (mirrored to `characters.equipment_proficiencies`) | yes | yes |
| Manual items (longsword, thieves' tools) | `character_proficiencies` rows | yes | yes, but **class and lineage items had a Remove button** that removed nothing |
| Manual skills / saves | `characters.skill_proficiencies` / `save_proficiencies` | yes | yes |
| Primary class (armor, weapons, tools, saves, skill choice) | class feature effects, `applies_to = primary_class / always` | yes (`_proficiency_match`, derived skills / saves) | skills and saves yes; **armor / weapon chips ignored it (showed unchecked)** |
| Multiclass row | the same effects, `applies_to = multiclass / always` | yes | as above |
| Artificer multiclass | **missing** (`multiclass_unresolved`) | no | no |
| Class features and feature choices (Expertise, Bonus Proficiency) | effects / choices | yes | skills yes; groups no |
| Lineage, sub-lineage, lineage choices (Dwarven Armor Training, Half-Elf versatility) | lineage trait effects | yes | skills yes; **armor / weapon chips no**; languages only as a list |
| Background | not modelled yet | no | no (see the background engine) |

Armor warnings already used the effective result (`_proficiency_match` checks manual, lineage and class sources).

## Model

- **Manual marks are one source among others.** Derived grants are never copied into manual rows. Removing a class,
  changing a lineage or a background removes only that source's contribution, and a manual mark of the same proficiency stays.
- **`get_character_proficiencies(character)`** returns `groups`, `items`, `skills`, `saves`, `tools`, `languages`,
  `warnings` and `armor`.
  - Each entry has `type`, `id`, `name`, `effective`, `level` (skills: 0, 1 or 2), `manual`, `manual_level`, `derived`,
    `editable` and `sources[]`.
  - Each source has a kind (`manual`, `import`, `class`, `feature`, `lineage`, `background`, `item`), a label
    ("Fighter", "Feature: Expertise", "Mountain Dwarf", "Manual") and a detail. Class sources carry their
    `character_class_id`; expertise sources are flagged.
- **Warning `manual_also_granted`.** A manual mark that a grant also covers is kept and only noted, so it survives losing the
  other source.
- **Security.** The function is security invoker, so row level security decides who may read: the owner, the campaign DM or
  an admin. Manual changes go through `set_character_proficiency` (SECURITY DEFINER, `auth.uid()`). Direct inserts into
  `character_proficiencies` and writes to the class catalog are denied.

## Class grants (all 13 classes verified)

A primary class grants its starting armor, weapons, tools and saving throws, plus the completed skill choices. A multiclass
row grants only the class's multiclass line. The test sweep PF20 checks every class: as the primary class it gets exactly
its saves, and as a multiclass it gets no saves and never heavy armor.

The Artificer gap is closed. Multiclassing into Artificer grants light armor, medium armor, shields, thieves' tools and
tinker's tools (Tasha's Cauldron of Everything, Artificer "Multiclassing"). The SRD has no Artificer row and the wikidot
page states only the Intelligence 13 prerequisite, so the data records `multiclass_source` (book `tce`, official). The
generator accepts a documented official source in place of the SRD table.

## UI (Stats tab)

- **States.** The weapon and armor chips show three states: **active, granted** (blue, with source badges such as
  "Fighter" or "Mountain Dwarf"), **active, manual** (gold, "Manual" badge) and **inactive**. The badges carry the meaning in
  text, not only color, and `aria-pressed` / `aria-label` repeat it.
- **Clicking a granted chip** opens an explanation:
  - which sources grant it;
  - that it cannot be switched off there;
  - **Open classes / Open lineage**, which jump to the source;
  - **Also mark manually / Remove manual mark**.
  It never deletes the grant.
- **Clicking an inactive or manual-only chip** toggles the manual mark (shown at once, then replaced by the server result).
- **Specific weapons, armor and tools, and languages** are listed with their sources. Only manual marks have **Remove
  manual**.
- **Skill and save dots** use the resolver for their level, and their tooltip names every source (for example "Proficient:
  Wizard"). Cycling a skill still edits only the manual level.

## Tests

- **SQL (`classes/proficiency_tests.sql`):**
  - primary Fighter armor, shields, weapons and saves;
  - Fighter as a multiclass;
  - Artificer as primary and as a multiclass;
  - Mountain Dwarf fixed grants and languages;
  - Half-Elf choice skills;
  - a lineage change removes only the lineage source;
  - class removal removes only the class source;
  - a manual duplicate is kept;
  - manual skill and save marks;
  - expertise over lineage and class proficiency;
  - the armor warning follows the effective result in both directions;
  - other users and direct writes are blocked;
  - the DM can read;
  - the 13-class sweep.
- **Browser (`proficiency_ui_test.py`):** derived chips with badges, no manual rows, inactive and manual toggles, the
  explanation dialog, "also mark manually", lineage item and language sources, removing a manual item, save dot sources,
  390 px, no errors.
- **Background grants:** the background engine adds its own checks (background proficiency appears, removing the
  background removes only its source).
