# Original UI restoration: visual audit (2026-10-22)

This audit was done before the v6 restoration. It compares the original Tavern Ledger character sheet with the state after
the player-first redesign, the refinement, the correction and v5, and decides for each component what comes back and what
stays.

## Sources

| Source | What it shows | Used for |
|---|---|---|
| `tavern-ledger-local-backups/ui-review-2026-10-22/before/` (Paladin combat, stats and inventory at 1366 and 390, DM pages) | The last state before the redesign: the preferred design | The visual reference for every component |
| Git `HEAD` 849d7f1 (2026-10-14): `css/styles.css`, `js/sheet.js`, `index.html` | The earliest committed sheet. `--gold: #d4a64a`, Cinzel via Google Fonts, `.ab-block` with the save row, `.sum-tile`, `.chip-toggle` | Exact tokens and the component CSS. No data logic was taken from it. |
| `css/styles.css` lines 1–1811 (current file) | The original component rules are still present (`.combat-bar.compact`, `.tile-ac` shield, `.ab-block`, `.ab-left`, `.save-dot`, `.sum-tile`, `.legend`, `.chip-toggle`, `.coins`). Later blocks override them. | Restored by removing or overriding the later overrides |
| Public page `https://alexandrajuscak.github.io/tavern_ledger` | Its static `index.html`, `css/styles.css` and `js/sheet.js` were fetched with curl and are byte-identical to git `HEAD` | Confirmed the git reference. The page was not opened in a browser, because its scripts would contact the hosted backend. |
| Screenshots supplied with the request | None were attached to the message | — (the archived screenshots above stand in) |
| `original-ui-2026-10-22/before/` | The current (v5) state at 1920, 1366, 820 and 390 for every tab | "Current" column |

## What changed in each redesign

| Pass | Visual change | Kept functionality |
|---|---|---|
| Player-first redesign | Cinzel removed (Inter everywhere, Alegreya for four titles). Sentence-case labels. Headings warm white. Shield flattened. Gold reduced to accents | Play, Abilities, Spells, Inventory, Build and Bio. Bottom navigation, sections, source-aware proficiencies, authoritative values, a11y |
| Refinement | Separate sections for Ability scores, Saving throws and Skills. Skills became a flat list. Six generic ability cards | Clear section boundaries (L0–L3 surfaces) |
| Correction | Skills blocks back, without Constitution and without saves | School-only spell icons |
| v5 | Cinzel back for numbers and some headings (white, not gold). Ability strip. Collapsed vitals as one text line | Authoritative max HP, base max on Build, restrained resources, Damage/Heal feedback |

## Component audit

| Component | Original | Current (before v6) | Why the original was better | Restore | Keep |
|---|---|---|---|---|---|
| Logo | Cinzel, gold, tracked | Cinzel, warm white | Gold made the brand distinct | Gold Cinzel | Icon mark |
| Character name | Cinzel, warm white, large | Cinzel, warm white | — | Page-title gold, Cinzel | Class/lineage subtitle, state chips |
| Section headings | Cinzel gold (Equipped Weapons, Attacks, Hit Dice, Proficiencies) | A mix: some white Cinzel, some white Inter (Items you carry, DM cards), some white sentence case | One recognisable heading voice | One gold Cinzel rule for every major title | Section surfaces and dividers; functional headings in Inter |
| Vitals expanded | HP card (largest), shield AC, Initiative/Speed/Proficiency cards with small tracked labels and big Cinzel numbers, conditions and resources below | Same structure. Labels sentence case with icons. Shield present | Labels read like a sheet | Small tracked capitals, no label icons, gold AC | Derived max, base max on Build, feedback messages, quick-resource rules |
| Vitals collapsed | The same components shrunk: HP value and bar, AC shield, three cards | One text line ("HP 52/52 AC 19 Init +0…") | Kept the visual identity | Original compact components; temp HP and the HP state as small badges | Remembered preference, mobile default collapsed, focus-safe handle |
| Ability cards | Six cards, 3 × 2: gold name, modifier, score pill on the left; divider; saving throw row and the skills on the right | v5 strip of six score cards, plus separate Saving throws and Skills sections | Each skill visibly belongs to its ability; one glance per ability | Six ability-and-skills cards in one section | Derived values, Wild Shape sources, true minus sign, accessible names |
| Markers | Empty circle, gold circle, gold double ring (expertise), diamond (save) | Same shapes, plus green/dashed source accents | — | Gold tokens, focus ring | Source-aware titles; derived grants cannot be removed |
| Passive values, Inspiration | Four summary tiles (Proficiency, Passive Perception, Passive Insight, Inspiration) above the cards | PB and Inspiration in the section header; passives in Senses | Fast to find, balanced | The four tiles | Labelled toggle |
| Hit Dice, Death Saves | Gold headings, compact controls | One "Hit dice and death saves" section, Inter sub-heading | — | "Hit Dice" section with a gold "Death Saves" sub-heading | Current hit-dice fields |
| Proficiencies | Two-column tiles, gold tint when active | Blue tint for granted tiles | Gold matched the sheet | Gold-tinted active tiles (granted solid, manual dashed); dark inactive | Source badges, source dialog, manual-only removal |
| Inventory summary | Four tiles with label, value and note | Loose text in four boxes; Coins "25 gp / edit below" | — (both weak) | Metric cards: icon, tracked label, Cinzel value, unit, note; Coins with Edit | Attuned list, denominations |
| Coins | Five labelled inputs | Same | — | Tracked labels, Cinzel amounts | Current currency fields |
| Spell cards | — | School icon, school badge and colour, damage chips | Current is better | Nothing (Cinzel names ≥ 701 px stay) | Everything |
| Play | Gold Cinzel group titles | White Cinzel | Consistency | Gold titles | Structure |
| Build | — | White titles | Consistency | Gold section titles; class names Cinzel white | Structure |
| DM Space | — | White Inter card titles | Consistency | Gold Cinzel card titles, gold kicker | Behaviour unchanged |

## Plan

1. A single v6 block at the end of `css/styles.css` replaces the v5 block. It holds tokens, the heading system, number
   typography, vitals, abilities, the lower Abilities sections, proficiencies, inventory metrics and coins.
2. `js/sheet.js`:
   - Abilities markup: summary tiles, legend and six ability-and-skills cards, with Hit Dice + Death Saves, Senses and
     Proficiencies below;
   - vitals: remove the text-line summary; add the temp and state badges;
   - refresh the coin card when coins are edited.
3. `js/inventory-ui.js`: the metric-card markup, the Coins Edit action and a summary-only refresh.
4. No data or calculation code from the old implementation. All values keep their current authoritative sources.
