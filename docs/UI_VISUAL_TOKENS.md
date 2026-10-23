# UI visual tokens

Every colour, radius, shadow, spacing step and type size is a CSS custom property on `:root` in `css/styles.css`. Components
use the tokens. Inline colours are not used, except data-driven widths such as the HP bar.

Older component rules use the earlier names (`--panel`, `--muted`, `--gold`, `--good`, `--blue` …). These names are kept as
**aliases** of the new tokens, so the whole app follows a token change.

## Surfaces

| Token | Value | Use |
|---|---|---|
| `--bg` | `#0e0e12` | L0 page background (deep neutral), with a faint warm glow at the top (`--bg-grad`) |
| `--surface-1` | `#17171e` | L1 sections, vitals bar, modals |
| `--surface-2` | `#23232d` | L2 cards inside a section (abilities, spells, items, feats, class rows), HP card, tiles, inputs |
| `--surface-3` | `#2d2d38` | hover, icon wells, raised controls |
| `--surface-inset` | `rgba(0,0,0,.24)` | L3 details inside a card or section (calculations, sources) |
| `--border-section` / `--border-card` | `#2a2a35` / `#363643` | section edge and header divider / card edge |
| `--surface-raised` | `#1e1e25` | hovered cards |
| `--border` / `--border-strong` | `#2e2e38` / `#464654` | soft separators / inputs and outlines |

Depth is mostly the surface step. Shadows are reserved for floating layers (`--shadow-lg`: modals, bottom bar).

## Text

| Token | Value | Contrast on `--surface-1` / `--surface-2` (WCAG) |
|---|---|---|
| `--heading` | `#f3ead9` | 14.5:1 / 13.4:1 |
| `--text` | `#ece8e1` | 14.2:1 / 13.1:1 |
| `--text-2` | `#aaa6b1` | 7.3:1 / 6.7:1 (secondary text, labels) |
| `--text-3` | `#908c9a` | 5.3:1 / 4.9:1 (hints, metadata only; was `#7f7b89` at 4.2:1, raised to pass AA) |
| `--accent` on surfaces | `#d9ae55` | 8.4:1; dark text on an accent button 8.8:1 |

## Accents and meaning

| Token | Value | Meaning | Always paired with |
|---|---|---|---|
| `--accent` / `--accent-strong` / `--accent-soft` | `#d9ae55` / `#ebc46e` / 14 % | primary action, selection, current section | text label |
| `--focus` | `#f4cf74` | keyboard focus ring (2 px outline, offset 2 px) | — |
| `--success` (+ `-soft`) | `#4fae7b` | healed, done, prepared | text ("Prepared", "Done") |
| `--warning` (+ `-soft`) | `#e3a640` | open choices, something to check | text + 3 px left bar on warning paragraphs |
| `--danger` (+ `-soft`) | `#d4505c` | damage, destructive actions, down | text ("Damage", "Delete character…") |
| `--info` (+ `-soft`) | `#6c9cf0` | information, setup banner, bonus-action edge | text |
| `--magic` (+ `-soft`) | `#8f8cf3` | magic in general | text |
| `--nature` (+ `-soft`) | `#5fae74` | Wild Shape, druidic | "Wild Shape: …" text |
| `--pending` (+ `-soft`) | `#b99af2` | waiting for the DM, returned requests | "waiting for your DM" text |
| `--locked` (+ `-soft`) | `#9aa3b5` | locked character, locked choice | "Progression locked" text + chain icon |
| `--dm-secret` (+ `-soft`) | `#e0707f` | DM-only information | "DM only" text |
| `--custom` (+ `-soft`) | `#4fbab0` | campaign custom content | "Campaign custom" text |
| `--temp` | `#5fa8d3` | temporary hit points | "Temp" label |

State chips (`.chip-locked`, `.chip-pending`, `.chip-nature`, `.chip-warn`, `.chip-custom`, `.chip-secret`) combine the soft
fill, a 45–55 % border and a light text colour, so every state is readable without its colour.

Selected, active, disabled, locked and pending states look different from each other:

- selected: accent border plus accent-soft fill (tab, filter chip);
- active: a filled status chip with the word "Active";
- disabled: 55 % opacity plus a reason next to the control;
- locked: steel chip with a chain icon;
- pending: violet chip with an hourglass.

## Gameplay categories

| Token family | Use |
|---|---|
| `--school-*` (8 + `none`) | spell school: card edge, tint, school badge. **Necromancy green `#4cbb6c`** is preserved |
| `--dmg-*` (13 + `none`) | damage-type chips. **Fire orange `#f5873b`, Necrotic deep green `#3fae6d`** are preserved |
| `--effect-healing`, `--effect-temp-hp` | healing and temporary HP chips |
| `--rarity-*` | common, uncommon, rare, very rare, legendary, artifact |
| Play timing edges | actions: accent; bonus actions: info blue; reactions: pending violet (left edge of action cards) |

The spell and damage colours are documented in `docs/SPELL_VISUAL_SYSTEM.md`. They were not changed.

## Shape, spacing, type

- Radius: `--radius-sm` 8 px (controls), `--radius` 12 px (cards), `--radius-lg` 16 px (vitals bar, modals); chips are fully round.
- Spacing scale: `--space-1` … `--space-6` = 4, 8, 12, 16, 24, 32 px.
- Spacing roles (2026-10-22): `--gap-inline` 4, `--gap-row` 8, `--gap-card` 10, `--gap-group` 18, `--pad-section` 20,
  `--gap-section` 28, `--pad-page` 24 px; on phones (≤ 700 px) card 8, group 14, section padding 14, section gap 18, page 16.
  The section gap is always visibly larger than the card gap.
- Type: `--font` / `--font-ui` (Inter), `--font-display-medieval` (Cinzel, v5), `--font-display` (Alegreya, now only the Cinzel fallback), the role tokens `--type-*` and the sizes `--fs-*` (see `docs/UI_TYPOGRAPHY.md`).
- Layout: `--topbar-h` 56 px. `--bottomnav-h` is 64 px on phones (≤ 700 px) and 0 elsewhere.

## Adjusting the look

The first redesigned version is meant to be reviewed visually. The quickest adjustments:

- warmer or cooler surfaces: `--bg`, `--surface-*`;
- stronger or softer gold: `--accent*`;
- more or less contrast in secondary text: `--text-2`, `--text-3`;
- the display face: `--font-display-medieval` (role tokens `--type-*`).

## v6 tokens (2026-10-22)

- `--color-heading-gold: #d4a64a` (the original `--gold`) for major titles and fantasy sub-headings.
  `--color-heading-gold-strong: #e2b85c` for page titles. `--color-title` (= `--heading`) for component titles.
- `--font-display-medieval` (Cinzel) and `--font-ui` (Inter).
- `--type-page-title`, `--type-major-section-title`, `--type-fantasy-sub-title`, `--type-component-title`,
  `--type-functional-heading`, `--type-stat-value`, `--type-label`, `--type-body`, `--type-caption`, `--type-button`,
  `--type-chip`.
- The surfaces stay as in the refinement: L0 page `--bg`, L1 section `--surface-1` + `--border-section`, L2 component
  `--surface-2` + `--border-card`, L3 inset `--surface-inset`.
