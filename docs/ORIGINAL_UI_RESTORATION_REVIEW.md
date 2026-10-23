# Original UI restoration: review (v6, 2026-10-22)

The audit is in docs/ORIGINAL_UI_RESTORATION_AUDIT.md. This is a local-only frontend change. No backend, schema, RLS,
governance, approval or calculation code changed.

## Why the newer design felt flatter

- The redesign replaced Cinzel with Inter for every heading and number, and set labels in sentence case. Gold survived
  only as an accent. Every section looked like the same white-titled box.
- Specialised sheet components were turned into generic ones:
  - the collapsed vitals became one text line;
  - the ability cards became a strip;
  - saves and skills moved to separate generic sections;
  - the inventory summary became loose text.
- Heading styles had drifted apart: white Cinzel, white Inter, gold accents and sentence-case labels all appeared side by
  side.

## What v6 restores

- **One heading voice.** Every major section title (sheet, Play, Inventory, Build, DM Space, home) is Cinzel in the
  original gold `#d4a64a`. Page titles (character name, DM campaign) use a stronger gold. Component titles are Cinzel in
  warm white. Functional headings and dialog titles are Inter.
- **The original vitals panel:**
  - the HP card is the largest; the gold AC shield, then Initiative, Speed and Proficiency cards;
  - small tracked-capital labels and large Cinzel numbers;
  - collapsed: the same components shrunk (HP value and bar, shield, three cards), with "+N temp" and
    Bloodied / Critical / Down badges.
- **The original Abilities page:**
  - four summary tiles: Proficiency, Passive Perception, Passive Insight, Inspiration;
  - the marker legend;
  - six ability-and-skills cards (3 × 2): gold ability name, modifier and score pill, a divider, then the saving throw
    (diamond, gold "Saving Throw") and the skills it governs;
  - Hit Dice with a gold Death Saves sub-heading;
  - gold-tinted Proficiency tiles.
- **Inventory:** four metric cards with one anatomy (icon, label, Cinzel value with unit, note), and a Coins card with
  Edit.

## What stays from the redesign

- Play, Abilities, Spells, Inventory, Build and Bio, with the bottom navigation.
- Section surfaces and spacing (L0 page, L1 section with border and divider, L2 component, L3 row), so sections no longer
  blend.
- **Values:**
  - authoritative derived values: maximum HP with feats, AC, initiative, speed, PB, saves and skills, Wild Shape form
    values;
  - base maximum HP edited on Build;
  - quick-resource rules (≤ 6 chips, slot and Pact summary).
- **Behaviour:**
  - Damage/Heal feedback and duplicate protection;
  - remembered collapse (mobile default collapsed);
  - source-aware proficiencies (a granted mark or tile explains its source and cannot be removed as manual);
  - school-only spell icons with damage chips;
  - DM Space behaviour, governance and approvals;
  - accessibility names, focus handling, true minus sign.

## Component details

**Vitals**
- **Expanded:**
  - HP card: HIT POINTS · TEMP field; current / maximum (Cinzel); bar; Damage · amount · Heal (44 px).
  - Tiles: AC shield (gold value, opens the breakdown), INITIATIVE, SPEED (`ft` in Inter), PROFICIENCY. Below 1000 px the
    AC tile reads "AC".
  - Below: conditions and quick resources.
- **Collapsed:**
  - the HP row and bar, the shield and the three cards, under 140 px tall on desktop and under a quarter of a 390 × 844 phone screen (tests V19b, R5);
  - in Wild Shape, the form and its HP;
  - "More" / "Less" handle centred on the bottom edge, labelled "Expand vitals" / "Collapse vitals".
- **Preference:** `localStorage['tavern-ledger:compact']`.
- **Top bar:** shows HP and AC only after the panel scrolls away, so there is no second dashboard.

**Abilities, per viewport**
- 1920 and 1366: three columns × two rows.
- 820: two × three.
- 390: one card per row (124 px ability column, 112 px under 420 px). All six are in the page; none is hidden by overflow
  or by the bottom navigation.
- Constitution shows its saving throw only.
- In Wild Shape, STR, DEX and CON show the form scores with "From form"; INT, WIS and CHA show "Retained from character".

**Inventory**
- Items: stacks and pieces.
- Weight: carried lb. The app does not track capacity, so none is shown.
- Attuned: used / limit, with "N slots free", "limit reached" or "N over the limit" (amber), and Show.
- Coins: the largest denomination as the value, the others listed, and Edit, which focuses the GP field. Editing a coin
  refreshes the card without re-rendering the item list.
- Layout: four across on desktop, 2 × 2 from 900 px down. On phones the icons are hidden and labels stay above values.

## Verified with synthetic fixtures (original_ui_test.py)

- **OU Tough Fighter** (Fighter 4, base max 36, Tough):
  - vitals 36 / 44; Damage 10 → 26; Heal 999 → 44;
  - Init +2, Speed 30, PB +2; Second Wind in the quick resources;
  - modifiers +3 +2 +2 −1 +1 +0; saves +5 +2 +4 −1 +1 +0 (STR and CON diamonds on);
  - Stealth expertise +6; passives 11 / 11;
  - inventory: 2 items · 3 pieces, 57 lb, 0 / 3, 25 gp + 3 sp. Edit → GP field; set to 30 and the card updates.
- **OU Low Fighter** (8 / 40, temp 5, Poisoned): Critical (in words), "+5 temp", Poisoned. Collapsed keeps all three.
- **OU Moon Druid as Brown Bear:**
  - form HP 34 / 34 first; normal 45 protected;
  - STR 19 / DEX 10 / CON 16 from the form (+4 +0 +3); INT, WIS, CHA retained (WIS +3).

## Tests

| Suite | Result |
|---|---|
| `original_ui_test.py` (new) | 116 / 116. Vitals V1–V24, abilities A1–A28, Hit Dice / Death Saves / Proficiencies H, inventory I1–I20, typography T1–T26, responsive R, console C1, local traffic L1 |
| `skills_spell_icon_ui_test.py` | 44 / 44 (cards + school-only icons) |
| `ui_refinement_ui_test.py` | 67 / 67 |
| `ux_redesign_ui_test.py` | 29 / 29 |
| `inventory_ui_test.py` | 38 / 38 |
| `derived_stats_ui_test.py` | 35 / 35 |
| `proficiency_ui_test.py` | 12 / 12 |
| `wild_shape_ui_test.py` | 74 / 74 |
| `spell_ui_test.py` | 28 / 28 |
| `spell_visual_ui_test.py` | 13 / 13 |
| `dm_space_ui_test.py` | 50 / 50 |
| Complete browser suite (once, sequential) | 26 suites, 793 checks, 0 failed |

## Screenshots

`%USERPROFILE%\tavern-ledger-local-backups\original-ui-2026-10-22\`:
- `before\`: the state before v6.
- `after\`: the state after v6.
  - Both folders hold Paladin's six tabs at 1920, 1366, 820 and 390, the collapsed vitals, Druid 8 Abilities, Wizard
    Spells and DM Overview.
- `compare\`: original preferred | before v6 | restored v6:
  - `abilities_1366.png`, `vitals_play_1366.png`, `vitals_collapsed_1366.png`, `inventory_1366.png`;
  - `mobile_play_390.png`, `mobile_abilities_390.png`.
- `focused\` (from the test):
  - vitals: expanded at 1366 and 1920, collapsed, low collapsed, Wild Shape, 820, and phone compact / expanded;
  - abilities: 1366, 820, full 1366 and 1920, Wild Shape, one card, the legend, the lower sections, and the phone
    abilities;
  - inventory summary at 1366, 820 and phone; coins; build;
  - spells at 1366, 820 and 390; DM custom spell preview.

## Deferred (concrete)

- Weight has no carrying-capacity context, because the app does not track capacity yet.
- Hit Dice is still one pool (count + die) as before. Multiclass pools per die type are not modelled.
- The collapsed vitals hide the condition chips; they are visible again when expanded.
- In a form, the form-score pill replaces the base-score field; the base stays in the note.
