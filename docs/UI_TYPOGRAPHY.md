# UI typography

## History

1. **Until 2026-10-22 (morning):** Cinzel, loaded from Google Fonts, set almost everything decorative. That included the
   character name, every card heading, HP, AC, initiative, speed, proficiency, ability modifiers, counters, slot numbers,
   modal titles, campaign names and the home level circles. Many labels were uppercase with wide letter spacing.
2. **Player-first redesign (2026-10-22):** Cinzel was removed completely. Inter set all text and numbers, and Alegreya set
   only the logo, page titles and the character name. That was readable, but the sheet lost its fantasy identity and looked
   like an ordinary dashboard.
3. **v5 restoration (2026-10-22):** Cinzel is back, self-hosted, for **identity, meaningful headings and
   prominent sheet numbers only**. Inter still sets everything people read or operate.

4. **v6 original visual language (2026-10-22, this version):** one heading system. Major titles are gold Cinzel
   (`--color-heading-gold` `#d4a64a`, the original `--gold`). Component titles are Cinzel in warm white. Functional headings
   are Inter. Sheet labels are small tracked capitals in Inter. See "Heading system (v6)" below; it overrides the older
   colour notes in this file.

The previous Cinzel configuration (git `HEAD`, `index.html`):
`https://fonts.googleapis.com/css2?family=Cinzel:wght@600;700&family=Inter:wght@400;500;600;700`, with
`--font-display: 'Cinzel', Georgia, serif`.

## The rule

| Face | Token | Used for |
|---|---|---|
| **Cinzel** (medieval display) | `--font-display-medieval` | Fantasy identity, meaningful headings, prominent isolated values |
| **Inter** (readable UI) | `--font-ui` (= `--font`) | Instructions, controls, descriptions and dense information |

Typography follows **meaning, not heading level**. No rule sets a face on every `h2` or `h3`.

### Cinzel (display)

- Identity: the Tavern Ledger logo (`.brand`), the character name (`.char-name`), page titles (`.title`) and the DM Space
  page title (`.dm-title h1`).
- Fantasy section headings: every `sectionHead()` title by default (`.fantasy-section-title`). Examples are Ability scores,
  Saving throws, Skills, Senses and movement, Proficiencies, Spellcasting, Spell slots, Your spells, Classes, Class
  features, Lineage, Background, Feats, Equipped, Coins, and the Play titles (`.play-title`: Ready to use, Attacks…).
- Card titles with fantasy meaning: class names (`.cls-row-title`), lineage (`.lin-name`), background (`.bg-name`), Wild
  Shape panel headings and form names (`.ws-panel h3`, `#ws-active-title`, `.ws-form-name`), feat names in the picker
  (`.feat-row-name`) and published custom content (`.dm-content-name`).
- Spell names on cards (`.sp-card-title`) on screens 701 px and wider only.
- Prominent numbers: current HP, maximum HP, form HP, temporary HP value, AC, initiative, speed, proficiency, ability
  modifiers and scores (strip, Skills blocks, Wild Shape form scores), collapsed-vitals numbers, quick-resource counts,
  Wild Shape HP and AC, and DM party stats.

### Inter (UI)

Inter is used for paragraphs, descriptions, feature, spell and item text, labels (`.stat-label`), units (`ft`), form
fields, buttons, tabs and bottom navigation, filters, chips, badges, count pills, helper text, errors and warnings. It
also sets audit entries, approval diffs, source details, calculation breakdowns, tables, compact metadata, skill and save
rows, and spell mechanics (level, school badge, damage chips, casting time, range, concentration, ritual, prepared).

**Interface headings** use Inter through `sectionHead({ variant: 'interface' })` (`.interface-section-title`): Notes,
Combat notes, Spell notes, Reminders, Your own features, Backup and sharing, Delete character. Modal titles stay in Inter,
because most dialogs are functional ("Remove spell?").

## Tokens (`css/styles.css`, `:root`)

```
--font-display-medieval   'Cinzel', 'Alegreya', Georgia, 'Times New Roman', serif
--font-ui                 var(--font) = 'Inter', system-ui, …
--type-app-title          700 1.15rem Cinzel
--type-character-name     700 1.85rem Cinzel (1.4rem on phones)
--type-page-title         700 1.6rem Cinzel
--type-fantasy-section-title     700 1.1rem Cinzel (1rem on phones)
--type-interface-section-title   650 1.0625rem Inter
--type-card-title         700 1rem Cinzel
--type-stat-value         700 var(--fs-stat) Cinzel
--type-body / --type-label / --type-caption / --type-button / --type-chip   Inter
```

The role rules are in one block at the end of `css/styles.css` ("v5 (2026-10-22)"). To change a role, change its token
or that block. No other rule chooses Cinzel.

## Numbers

- Format: HP `19 / 19`, AC `17`, initiative `+2`, speed `30 ft`, proficiency `+2`, modifiers `+3`, `+0` and `−1`. The sheet
  uses a true minus sign (U+2212, `fmt()` in `js/sheet.js`), which Cinzel's Latin subset covers.
- The number is set in Cinzel. The label, unit (`ft`) and helper text next to it stay in Inter.
- Cinzel has no tabular figures, so numeric boxes have stable minimum widths: HP `3.2ch`, maximum `2.6ch`, modifiers
  `2.4ch`, score pills `46–56px`. A changing value does not move its neighbours.
- `0 1 6 8 + − /` were checked visually at 1366 and 390 px (screenshots in the v5 review).

## Mobile

- Cinzel stays on phones for the character name, page titles, section titles, prominent values and Wild Shape form names.
  Spell card names switch to Inter on phones.
- The character name is 1.4rem on phones, so ordinary names fit on one line (checked at 390 px by test T21). Section titles
  are 1rem.
- The bottom navigation, buttons and inputs stay in Inter. Inputs keep at least 15 px, so iOS does not zoom.

## Loading and licensing

- Self-hosted in `fonts/` (Latin and Latin Extended subsets, variable weight files):
  - `cinzel-latin.woff2` and `cinzel-latin-ext.woff2` (weights 600–700, Cinzel v26)
  - `inter-latin*.woff2` (400–700)
  - `alegreya-latin*.woff2` (600–700, kept as the Cinzel fallback)
- `css/fonts.css` declares all three with `font-display: swap`. `index.html` preloads the main Inter and Cinzel files.
  The app makes no external font request (test L1 / T23).
- Cinzel: Copyright 2020 The Cinzel Project Authors (https://github.com/NDISCOVER/Cinzel). Licence: SIL Open Font
  License 1.1, text in `fonts/OFL-Cinzel.txt`. It may be used, embedded and self-hosted in this app, and redistributed
  with it. It may not be sold on its own.
- Inter and Alegreya: SIL Open Font License 1.1 (`fonts/OFL-Inter.txt`, `fonts/OFL-Alegreya.txt`).
- The Cinzel files were downloaded once, on 2026-10-22, from Google Fonts (`fonts.gstatic.com/s/cinzel/v26/…`).

## Tests

`supabase/tests/browser/vitals_abilities_ui_test.py`:
- T1–T13b: Cinzel roles.
- T14–T17h: Inter roles.
- T20: no long text in Cinzel.
- T21: the name fits at 390 px.
- T21b: the bottom navigation stays in Inter.
- T23 and L1: self-hosted, no external request.

`ux_redesign_ui_test.py` UX2 and UX6 check the page title, character name and AC (Cinzel), and body, buttons and labels
(Inter).

## Heading system (v6)

| Level | Class / selector | Face and colour | Examples |
|---|---|---|---|
| Page title | `.char-name`, `.title`, `.dm-title h1` | Cinzel 700, `--color-heading-gold-strong` `#e2b85c` | Character name, sign-in title, DM Space campaign |
| App title | `.brand` | Cinzel 700, `--color-heading-gold` | Tavern Ledger |
| Major section title | `.tl-section-title` (every `sectionHead()` and the raw inventory h2), `.play-title`, `.section-title`, `.dm-card > h2`, `.home-section`, Wild Shape panel h3 | Cinzel 700 1.12rem, `--color-heading-gold` `#d4a64a` | Ability scores and skills, Hit Dice, Proficiencies, Equipped, Items you carry, Coins, Classes, Lineage, Background, Feats, Attacks, Ready to use, At the table |
| Fantasy sub-heading | `.fantasy-sub-title`, `.save-label`, `.ab-left .ability-name` | Cinzel, gold | Death Saves, Saving Throw, Strength … Charisma |
| Component title | `.cls-row-title`, `.lin-name`, `.bg-name`, `.ws-form-name`, `.feat-row-name`, `.dm-content-name`, `.campaign-title`, `.sp-card-title` (≥ 701 px) | Cinzel, warm white `--color-title` (spells: warm white; the school colour stays on badge and edge) | Paladin, Noble, Brown Bear, Fireball |
| Functional heading | `.interface-section-title` (`sectionHead({ variant: 'interface' })`), `.tl-sub-title`, `.prof-sub`, modal titles | Inter 650, warm white | Notes, Reminders, Backup and sharing, Armor and weapons, Tools and languages, dialog titles |
| Label | `.combat-bar .stat-label`, `.sum-tile .stat-label`, `.inv-metric-label`, `.death-label`, `.res-name`, `.coin` | Inter 600 0.68rem, uppercase, 0.1em tracking, `--text-2` | HIT POINTS, ARMOR CLASS, PASSIVE PERCEPTION, ITEMS, COINS |

- **Gold rule:** gold marks fantasy hierarchy only: major titles, ability names, Saving Throw, Death Saves, the AC value, the
  coin amount and the selected tab. It is never used for paragraphs, metadata, warnings (`--warning`) or DM-only labels
  (`--dm-secret`). `#d4a64a` on the section surface `#17171e` is about 7.9:1.
- **Prominent numbers in Cinzel:** HP current, maximum and form HP, the temp field, AC, Initiative, Speed, Proficiency,
  ability modifiers and scores, summary-tile values (Proficiency, Passive Perception, Passive Insight), quick-resource
  counts, hit-dice count, coin amounts, inventory metric values, Wild Shape and DM stats.
- **Never Cinzel:** paragraphs, descriptions, skill names, skill and save bonuses (Inter tabular figures), buttons, inputs
  (except the score, HP, temp, hit-dice and coin number fields), tabs, bottom navigation, chips, badges, source details,
  approval diffs, audit logs, legends and helper text.
- **Pages:** Play, Abilities, Spells, Inventory, Build and Bio have no separate page title. The character name (h1) is the
  page title and the selected tab names the page. This avoids a second large title above every tab.
