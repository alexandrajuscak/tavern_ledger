# UI design system

Tavern Ledger aims to be a beautiful, highly readable and approachable digital character sheet. Players should enjoy using
it while building a character and at the table. This document holds the principles and the structure. The details are in:

| Topic | Document |
|---|---|
| Type faces, sizes, rules | `docs/UI_TYPOGRAPHY.md` |
| Colours, surfaces, spacing tokens | `docs/UI_VISUAL_TOKENS.md` |
| Icons | `docs/UI_ICON_SYSTEM.md` |
| Reusable components | `docs/UI_COMPONENTS.md` |
| Audit that led here | `docs/UX_INFORMATION_ARCHITECTURE_AUDIT.md` |
| Player journeys | `docs/PLAYER_JOURNEY_REVIEW.md` |
| What changed for existing users and tests | `docs/UI_MIGRATION_NOTES.md` |
| Manual usability review | `docs/UI_USABILITY_REVIEW.md` |

## Principles

1. **Player first.** Sections follow what a player does (play, check a skill, cast, manage gear, change the build,
   write notes), not the database tables.
2. **Readability first.** The fantasy tone comes from colour, the illustrated icons, the display face on titles and the
   wording. It never comes from a decorative face on text.
3. **Progressive disclosure.** The default view shows the essentials. Calculations, sources, versions and automation
   classifications sit behind "How is this calculated?", "Details and source", folded sections and dialogs.
4. **Contextual actions.** Damage and Heal sit next to HP, Use next to the resource, Prepared on the spell, Equip on the
   item, Revert on the active form, Level up next to the classes.
5. **Consistency.** One chip style per state, one card style per kind of content, one button hierarchy, one icon family.
6. **Calm by default.** Empty groups collapse into one quiet sentence. Zero counters fade. Warnings get a thin amber
   marker, not a red box.
7. **Gameplay speed.** Everything used every round is on Play or in the vitals bar, reachable with one tap from any
   section. Build actions may take more steps.
8. **Accessibility.** Meaning is never carried by colour, icon, position, hover or motion alone.

## Information architecture

### Before

Eight tabs: Combat · Stats · Spells · Inventory · Features · Resources · Notes · Bio. A large sticky combat bar sat above
them, and the header carried Level Up, Short Rest and Long Rest.

### After

```
Top bar      logo · (on a sheet, once the vitals scroll away) name · HP · AC · DM Space · Sign out
Header       class emblem / portrait · name · "Paladin 6 (Devotion) · Human"
             chips: campaign · lock · requests · Wild Shape · choices to make        Short rest · Long rest
Vitals       HP (form HP first while transformed) + Damage / Heal · AC · Initiative · Speed · Proficiency
             conditions · resource pips                                               (collapsible)
Sections     Play · Abilities · Spells · Inventory · Build · Bio      (tabs; a bottom bar on phones)
```

| Section | Holds | Came from |
|---|---|---|
| **Play** | Ready to use (Rage-style states, feature DCs, quick resource buttons) · Wild Shape · Attacks (equipped weapons, class-feature attacks and riders such as Divine Smite, hand-made attacks) · Actions / Bonus actions / Reactions / Free and special (catalog class features by timing + hand-written entries + free-text spells) · hand-tracked resources · Companions · turn guide · combat notes | Combat, Resources, Features (companions, At a glance) |
| **Abilities** | proficiency summary, abilities with saves and skills, hit dice, death saves, other values (incl. base speed), proficiencies (weapons, armor, tools), lineage traits | Stats |
| **Spells** | spellcasting sources (DC / attack) · slots (Use / Restore, rests, recovery) · your spells, ready to cast first · lineage abilities · hand-written spells (folded) · notes | Spells (reordered, compact cards) |
| **Inventory** | summary · equipped (empty slots folded) · items by category · coins | Inventory |
| **Build** | Next steps (open choices, Level up / Request level up / locked reason) · Classes · Class features (current levels open, earlier folded, next-level preview, resource limits and recovery) · Infusions · Lineage · Background · Feats (grouped by source) · Reminders · Your own features (folded) | Bio (classes, lineage, background, pending choices), Features |
| **Bio** | identity (portrait, name, alignment, XP, level, campaign, player; free-text class and background folded) · character / session / campaign notes · backup (download file) · delete | Bio (identity, portrait, export, delete), Notes |

Play and Build are kept apart on purpose. Play holds what changes during a session and resets on rests. Build holds
permanent choices, which may need the DM's approval.

The internal tab keys stayed the same (`combat`, `stats`, `spells`, `inventory`, `features`, `bio`), so stored
preferences, deep links and tests keep working. Old stored keys `resources` and `notes` open Play and Bio.

### DM Space

DM Space keeps its eight sections (Overview, Approvals, Party, Content, Assign, Hidden, Campaign rules, Audit log). It
uses the same tokens, components and icons, and its title uses the display face. Overview now leads with one **Needs you**
list: requests waiting (with Review), approvals that could not be applied, characters down or low on HP, open choices,
setup. The counters follow and fade when zero. DM-only information always carries a "DM only" chip in the
`--dm-secret` colour.

## Responsive behaviour

| Width | Behaviour |
|---|---|
| ≥ 1100 px | two- and three-column grids (abilities, notes, inventory equipment beside items) |
| 760–1100 px | vitals in two columns (HP / tiles), sections as top tabs |
| ≤ 700 px | sections become a fixed **bottom bar** (6 × icon + short label, 54 px touch targets); page padding reserves its height; toasts float above it |
| ≤ 520 px | header actions become full-width buttons; tile labels shorten (AC, Prof.); the top bar hides the logo text while the HP / AC readout is shown |

The vitals bar is no longer sticky. A sticky 300 px block covered too much of a phone screen. Once the bar scrolls out of
view, the top bar shows a compact readout instead (name, HP or form HP, AC). Tapping it returns to the top.

## Motion

- Panel change: 120 ms fade. Modals: 180–200 ms fade and slide. No hover motion on cards.
- `prefers-reduced-motion: reduce` turns off every animation and transition, and smooth scrolling.

## Surfaces and sections (refinement of 2026-10-22)

Inside every sheet section the content is grouped in **sections** (`js/section.js`, `.tl-section`). Four surface levels, each
with one purpose:

| Level | What | Surface | Edge |
|---|---|---|---|
| L0 | page | `--bg` `#0e0e12` | — |
| L1 | section (Ability scores, Skills, Equipped, Classes, Feats…) | `--surface-1` `#17171e` | `--border-section`, 16 px radius, soft shadow, header divider |
| L2 | card inside a section (ability, spell, item, feat, class row, resource) | `--surface-2` `#23232d` | `--border-card` |
| L3 | detail inside a card or section (calculation, sources, expanded text) | `--surface-inset` (darker, no border) | — |

- A section starts with an **h2** (icon 22 px, decorative; title; optional count; one-line description; one action on the
  right). Nested groups are **h3**, cards **h4–h5**. No section inside a section, no card three levels deep.
- Section gap 28 px (phone 18 px) is always larger than the card gap 10 px (phone 8 px).
- Emphasis is reserved for meaning: `tl-section-emph` (gold edge) only while Next steps has open steps; `tl-section-warn`
  (amber edge) for Old sheet items. Errors, Wild Shape and low HP stay stronger than any section.
- Foldable sections are `<details class="tl-section tl-section-fold">` with the header in the summary.

Abilities: Ability scores · Saving throws · Skills · Senses and movement · Hit dice and death saves · Proficiencies.
Inventory: Equipped · Attunement · Quick use · Containers · Old sheet items (each only when it has content) · Items you carry ·
Coins. Build: Next steps (or a quiet "Up to date" row) · Classes · Class features · Lineage | Background · Feats (grouped by
source) · Reminders · Your own features. Spells: Spellcasting · Spell slots · Your spells · Lineage abilities · Spells written by
hand · Spell notes. Bio: Identity · Notes · Backup and sharing · Delete character. Play keeps its sections with the same surface.

## Fantasy identity restored (2026-10-22, v5)

The redesign's structure stays: the Play, Abilities, Spells, Inventory, Build and Bio sections, the bottom navigation, the
dark theme, sections and progressive disclosure. Three earlier, preferred elements are back:

- **Vitals panel**: the pre-redesign hierarchy, with HP largest, the shield-shaped AC, Initiative, Speed and Proficiency
  tiles, then conditions and quick resources. It can be collapsed to one summary line, and the choice is remembered.
- **Six-ability strip**: one row of STR to CHA cards on desktop, scrolling sideways inside the strip on narrow screens.
- **Medieval display face**: Cinzel for the logo, character name, fantasy headings and prominent sheet numbers. Inter
  stays for everything that is read or operated (docs/UI_TYPOGRAPHY.md).

Abilities sections: Ability scores (the strip) · Saving throws · Skills (six restored blocks) · Senses and movement · Hit
dice and death saves · Proficiencies.

## Original visual language (2026-10-22, v6)

v6 combines the original character-sheet components with the redesign's structure:

- **L0 page:** the darkest surface.
- **L1 major sections:** their own surface, border, divider and gold Cinzel title, with a clear gap between sections.
  Examples: Vitals, Ability scores and skills, Hit Dice, Senses and movement, Proficiencies, Equipped, Items you carry,
  Coins, Classes, Lineage, Background, Feats.
- **L2 specialised components:** these keep their own shapes:
  - the HP card and the AC shield;
  - the Initiative, Speed and Proficiency cards;
  - ability-and-skills cards and summary tiles;
  - proficiency tiles, inventory metric cards, spell cards, the Wild Shape sheet and approval diffs.
- **L3 rows:** light dividers (skill rows, save rows, kv rows), no extra frames.

Abilities is now one "Ability scores and skills" section. It holds:
- the summary tiles: Proficiency, Passive Perception, Passive Insight, Inspiration;
- the marker legend;
- six cards (3 × 2 desktop, 2 × 3 tablet, 1 per row on phones), each with its saving throw and skills.

Below are Hit Dice with Death Saves, Senses and movement, and Proficiencies. Details are in
docs/ORIGINAL_UI_RESTORATION_REVIEW.md.

## V6.1 hardening (2026-10-22)

The visual language is unchanged. The pass fixed:
- heading order;
- touch targets (≥ 24 px);
- loading marks on Home instead of stored legacy values;
- wrapping of long button labels below 420 px;
- toast behaviour.

See docs/V6_PRODUCT_HARDENING_REVIEW.md.
