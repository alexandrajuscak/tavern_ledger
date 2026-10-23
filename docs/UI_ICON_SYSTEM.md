# UI icon system

## One family

Tavern Ledger uses **one illustrated icon family**: flat, softly shaded, multi-colour fantasy icons on a transparent
background. The set was curated by the user in `../icons_curated/` (outside the repository; mapping in `ICONS.md` there).
For the app:

- every curated PNG (512 px) was converted to WebP: 96 px for icons, 192 px for portraits. They are in
  `assets/icons/<category>/<name>.webp`, about 0.8 MB for all 172 files, and a page loads only the icons it shows
  (`loading="lazy"`);
- 29 more icons for interface concepts that the curated set did not cover (lock, bonus action, reaction, ritual,
  attunement, DM secret, custom content…) were taken from the same original folder (`../icons/`, same artist and style)
  into `assets/icons/ui/`;
- `assets/icons/SOURCE_ICONS.md` maps every file to its original.

No emoji and no second icon style are used as production icons. Controls that are plain typography stay typographic: the
modal close "✕", the "+ / −" steppers, the "⌃ / ⌄" fold toggle and the summary triangles.

> **Licence to verify.** The original files look like downloads from an icon marketplace (numbered file names). Their
> licence is not recorded in the repository. Before the app is shared outside the private table, confirm the licence of the
> set and add the required attribution (for example a credits line in the footer). This is listed in
> `docs/UI_MIGRATION_NOTES.md`.

## Usage rules

1. **An icon supports text and never replaces it.** Every damage type, school, condition, lock, prepared state,
   concentration and ritual has its words next to the icon.
2. `icon(name, { label, size, cls })` in `js/icons.js` renders `<img class="tl-icon">`. Without a label it is decorative
   (`alt=""` + `aria-hidden="true"`). With a label the alt text carries the meaning. A browser test (UX8) checks that every
   icon on the sheet is one or the other.
3. Sizes: 14–16 px in chips, 18–20 px in buttons and labels, 22–24 px in section titles, 30–34 px in list rows and spell
   cards, 48 px+ for avatars and empty states.
4. Icons are for scanning categories, not for decorating every line: section titles, the bottom navigation, vitals
   labels, list rows (items, spells), state chips. Paragraphs and table cells get no icons.

## Map

| Concept | Icon |
|---|---|
| Sections: Play, Abilities, Spells, Inventory, Build, Bio | `ui/play`, `ui/abilities`, `spell-schools/spells-tab`, `ui/inventory`, `ui/build`, `ui/bio` |
| Attacks / actions | `ui/attack` |
| Bonus actions / reactions / free and special | `ui/bonus-action`, `ui/reaction`, `ui/condition` |
| Armor, weapons, shield (AC) | `equipment-slots/armor`, `items/weapons`, `equipment-slots/shield` |
| Health, temporary HP, death saves | `actions/heal`, `ui/temp-hp`, `actions/death-saves` |
| Speed, initiative, proficiency | `actions/speed`, `actions/initiative`, `actions/proficiency` |
| Senses, skills, saving throws | `ui/senses`, `ui/skills`, `ui/saving-throw` |
| Spell slots, concentration, rituals, spellbook | `actions/inspiration`, `actions/concentration`, `ui/ritual`, `ui/spellbook` |
| Resources, short rest, long rest | `actions/resources`, `actions/short-rest`, `actions/long-rest` |
| Inventory categories | `items/*` (weapons, armor, consumables, magic, ammunition, tools, gear, containers…) and `ITEM_ICONS` in `js/icons.js` |
| Equipment slots | `equipment-slots/*` (main hand, off hand, armor, shield, head, neck, cloak, hands, ring, focus) |
| Attunement | `ui/attunement` |
| Wild Shape, companion, creatures | `actions/wild-shape`, `ui/companion`, `creatures/*` |
| Feat, lineage, background, class | `ui/feat`, `ui/lineage`, `ui/background`, `classes/<class>` (`classIcon()`) |
| Level up, open choices, reminders | `actions/level-up`, `ui/incomplete`, `ui/notes` |
| Approval / approved, pending, locked | `dm/approved`, `ui/pending`, `ui/locked` |
| DM-only, campaign custom content | `ui/dm-secret`, `ui/custom-content` |
| DM content types | `dm/spell`, `dm/item`, `dm/feat`, `dm/creature`, `dm/companion`, `dm/background`, `dm/lineage`, `dm/condition` |
| Campaign | `dm/campaign` |

## Spell icons

There is no hand-drawn icon per spell. Every spell has **one primary icon, chosen by its school only** (`js/spell-icons.js`,
`resolveSpellIcon()`, used by spell cards, the catalog picker, the details dialog, the DM custom spell preview and published /
assigned campaign spells):

| Spell data | Primary icon |
|---|---|
| one of the eight schools | that school (`spell.school.<school>`) |
| school missing or not recognised | generic spell icon (`spell.school.generic`); the badge says "School not resolved" |
| school icon missing or fails to load | generic spell icon (registry fallback, then the load-error fallback) |

Damage type, healing, temporary HP, control, movement, summoning, the spell name and class lists never choose the icon (the
damage-first rule of the first refinement pass was removed the same day). The primary icon's accessible label is the school
("Evocation school"); the school is also a text badge and the card colour. Coverage of all spell versions:
`docs/SPELL_ICON_COVERAGE.md`. The other spell facts are text chips:

- damage types: colour swatch + name (`docs/SPELL_VISUAL_SYSTEM.md`), "+" for types dealt together, "Choose one … or …";
- healing and temporary HP chips;
- concentration (`actions/concentration`) and ritual (`ui/ritual`) badges, always with the word;
- casting time, range and duration as text in the meta line.

The spell name and the spell's own text remain authoritative.

## Avatars

A character without an uploaded portrait shows the emblem of its primary class (`classes/<class>`) instead of initials.
The curated portraits (`assets/icons/portraits/`) are ready for a future "choose a portrait" picker. That picker is listed
as deferred work.

## Registry and fallbacks (2026-10-22)

- **One registry:** `js/icon-registry.js` (generated from `assets/icons` by `scripts/local/build_icon_registry.py`) maps every
  semantic key to its asset, accessible label, category, fallback key and licence group. Keys are `<category>.<name>`
  (`spell.damage.fire`, `spell.school.necromancy`, `item.weapons`, `slot.shield`, `class.wizard`) plus semantic aliases
  (`section.skills`, `section.proficiencies`, `build.lineage`, `build.background`, `build.feat`, `inventory.weapon`,
  `inventory.armor`, `inventory.shield`, `spell.damage.multiple`, `spell.damage.choose`, `generic`). The `spell.damage.*` keys
  stay registered but no view draws them since the school-only spell icon correction (reported as unused by the audit).
- `js/icons.js` is the only module that builds icon URLs. `icon(name)` accepts a semantic key or the older asset name
  (`ui/attack`); `icon(name, { labelled: true })` uses the registry label as alt text.
- **Fallback chain:** specific key → its category fallback (`spell.damage.generic`, `inventory.generic`, `identity.generic`,
  `condition.generic-effect`…) → `generic`. An unknown name resolves to a fallback (and warns once in the console). A file that
  fails to load is swapped for its fallback at the same size, then for the generic icon: no broken image or empty box.
- **Audit:** `python scripts/local/icon_audit.py` lists every reference, checks every file (decodes, size, transparency,
  subject size, contrast on the card surface) and the licence status; output `data/reports/icon_audit.json` and
  `docs/ICON_ASSET_INVENTORY.md`. It exits with 1 on a missing, corrupt or unreadable icon.
- New icons in this refinement (same collection): `damage-types/multiple` (Multi-damage), `damage-types/choose` (Choose damage),
  unused since the correction and kept in place;
  `creatures/bear` replaced by the brown bear (the old one was nearly invisible on the dark theme). The last emoji used as icons
  (DM party cards, homebrew visibility, Wild Shape movement and lock marks, archived item note) are registry icons now.

## v5 (2026-10-22)

- The unused `damageIcon()` helper was removed from `js/icons.js`. No code path can pick a primary spell icon from damage.
  `spell.damage.*` assets stay registered on disk for a possible future chip icon and are reported as unused by the audit.
- Spell primary icons: the school only (`resolveSpellIcon()` in `js/spell-icons.js`), unchanged.
