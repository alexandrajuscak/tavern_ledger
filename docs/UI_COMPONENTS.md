# UI components

Tavern Ledger is a vanilla JavaScript app: components are HTML-string helpers plus CSS classes, with no framework and no build
step. This is the reusable set after the redesign; new UI should use these instead of one-off styles.

## Primitives

| Component | Markup / helper | Notes |
|---|---|---|
| Button | `.btn` + `.btn-gold` (primary), *(none)* (secondary), `.btn-quiet` (tertiary), `.btn-bad` (danger), `.btn-good`, `.btn-sm`, `.btn-xs` | one primary per context; min height 40 px (34 px small); disabled buttons are always explained next to them (`.field-note`) |
| Icon button | `.icon-btn` with `aria-label` | only for unambiguous controls (close); edit / delete now say "Edit" / "Delete" in text |
| Inline link action | `.btn-link`, `.link-btn` | small contextual actions inside text |
| Icon | `icon(name, {label, size, cls})`, `schoolIcon`, `damageIcon`, `classIcon`, `conditionIcon` (`js/icons.js`) | decorative unless labelled |
| Chip | `.chip` + `.chip-quiet / -locked / -pending / -nature / -warn / -custom / -secret`; `button.chip` when it opens something | state in words, icon optional |
| Badge | `.badge`, `.sp-badge`, `.cf-badge`, `.feat-b` | small metadata labels inside cards (kept per feature for stable tests) |
| Stat | `.tile` + `.stat-label` + `.big-num` (+ `.tile-note`) | vitals; tabular numbers |
| Resource | `resourceListHTML` / quick resource (`feature-ui.js`), `.pips`, `.slot-boxes` | remaining / max, Use / Restore, recovery text |
| Tabs | `.tabs` `role=tablist` with `.tab` `role=tab` (`aria-controls`, roving `tabindex`, arrow keys, Home / End) | bottom bar under 700 px |
| Segmented filter | `.inv-chip` (`role=tab`, `aria-selected`) | inventory categories, with icons and counts |
| Modal | `openModal({title, body, footer, wide})`, `confirmDialog()` (`utils.js`) | focus trap, Escape, focus restoration by `data-focus-key`; primary action last (right / bottom); sticky footer |
| Details (progressive disclosure) | `details.quiet-details` (light summary), `details.card.quiet-details` (folded card with a chevron) | "How it is calculated", "Details and source", folded groups |
| Alert / banner | `.gov-banner` (+ `.gov-lock`, `.gov-setup`), `p.warn` / `.sp-warn` / `.inv-note.warn` (amber left marker) | proportional to severity |
| Live status | `toast(msg, type)` (polite; errors `role=alert`), `#slot-status`, `#ws-status`, `#save-status` | non-blocking confirmation for slot used, resource restored, item equipped, spell prepared |
| Search | `.search-field` (icon + input + visually hidden label) | home list; spell and item pickers keep their own search |
| Empty state | `.empty-state` (card, icon, title, one sentence, the allowed action), `.calm-note` (one quiet line), `.empty` | never a blank panel |
| Skeleton | `.skeleton` + `.skeleton-line` / `.skeleton-block` | home list while loading; shimmer is off with reduced motion |

## Cards

| Card type | Class | Hierarchy | Actions |
|---|---|---|---|
| Summary card | `.char-card` (home), `.sheet-header`, `.combat-bar` | emblem → name → class · lineage → stats → state chips | the whole card is the link |
| Action card | `.entry.action-card` (Play groups), `.feature-attack`, `.feature-rider` | name → source → what it does → uses chip | spend buttons live in Ready to use; riders offer "Spend a slot…" |
| Resource card | `[data-cf-res]` (Build details), `[data-cf-quick]` (Play) | name → remaining / max → recovery | Use, Restore, amount + Spend |
| Spell card | `.sp-card` | school icon (school only, `resolveSpellIcon()`) + name + level → readiness chip, school, damage, concentration, ritual, slot hint → cast · range · duration → DC / to hit + Prepared → quiet source line | name opens the details dialog |
| Item card | `.inv-item` | category icon + name → state badges → kind · category · weight → quantity | Equip / Unequip / Use; details dialog |
| Catalog / picker card | `.lin-row`, `.bg-row`, feat picker rows, `.dm-create-tile` | name → short summary → eligibility | select, then review step |
| Detail card | `.cf-card`, `.feat-card`, lineage and background cards | title + badges → summary → choices → "Details and source" | Change / Choose… |
| Warning card | `.gov-banner`, `.next-list` item | icon + sentence | one action button |
| Approval card | request rows in DM Approvals, `diffHTML()` before → after | player · character · change · diff · warnings · note | Approve / Return / Reject |
| DM secret card | `.chip-secret`, Hidden section rows | "DM only" chip | DM-only controls |

Rules:

- Don't nest more than two surfaces: card (`--surface-1`) → block (`--surface-2`).
- Don't wrap a single value in border + title + badge + button. Use a tile or a row.
- Mobile: cards are single-column, action rows wrap, and buttons keep 40–44 px height.

## Feature-specific helpers that use the system

- `featsCardHTML` groups feats by source with `.feat-group-title`.
- `glanceHTML(state, derived, editable, states, { attackFacts })` is the Ready to use block (Play passes `attackFacts: false`).
- `levelUpButtonHTML()` is an enabled "Level up", a "Request level up" with an explanation, or disabled with the lock reason.
- `sheetChipsHTML()` builds the header state chips. `buildNextHTML()` builds Build → Next steps.
- `characterCard()` + `listCharacterBadges()` build the home cards with batched state reads.

## Section (2026-10-22)

`sectionHead({ id, icon, title, desc, count, action, level })` and `sectionHTML({ id, cls, tone, attrs, body, ...head })` in
`js/section.js`.

- Renders `<section class="tl-section">` with `aria-labelledby` → the h2 (level 3 gives an h3 for nested groups).
- `icon` is a registry key, decorative (the title carries the meaning); `count` shows as a pill; `desc` is one short line;
  `action` is one contextual control on the right (below the title on phones).
- `tone`: `emph` (open steps, gold edge), `warn` (amber edge); `.tl-section-quiet` for a one-line state (Build "Up to date").
- Foldable: `<details class="tl-section tl-section-fold"><summary>${sectionHead(...)}</summary>…</details>`.
- Rows of sections: `.tl-section-row` (two columns from 900 px, one on smaller screens).
- Cards inside a section get the L2 surface automatically (`.card`, `.entry`, `.feat-card`, `.cls-row`, `.sp-source`,
  `.slot-panel`, `.inv-item`, `.ab-card`…); details inside use `.tl-detail` (L3 inset).

## New character dialog (2026-10-22)

`newCharacterDialog()` in `js/app.js`: a stepper (`.nc-steps`, `aria-current="step"`) over Identity, Lineage, Lineage choices,
Class and Review. Steps 2–4 embed the Build pickers (`openLineagePicker({ host, saveButton, onStep })`,
`openAddClass({ host, saveButton })`); each step can be skipped. Closing the dialog after step 1 opens the created character.

## Skills block (restored 2026-10-22)

Inside the Skills section (`sectionHTML`, h2) the skills keep their own, earlier component: `.ab-grid` of `.ab-block`s, one
per ability, all six in STR DEX CON INT WIS CHA order (since v5; Constitution says "No skills use Constitution."). Left
column `.ab-left`: ability name, modifier (Cinzel) and score pill (`.ab-score-pill`), divider on the right. Right column
`ul.prof-list.ab-list`: one row per skill (round proficiency mark that cycles none → proficient → expertise, bonus, name,
disadvantage badge). Three blocks per row from 1100 px, two from 680 px, one below. It is deliberately not the generic card
or row style of the other sections: consistency is the section frame, not identical insides.

## Vitals panel (restored 2026-10-22, v5)

`combatHTML()` in `js/sheet.js`, inside `section.combat-bar` above the tabs.

- **Expanded** (`#vitals-body`):
  - HP card: current HP (input), the authoritative maximum (`[data-derived="hp-max"]`, a value, not an input), temp HP,
    HP bar, the feat note ("Maximum 44: base 36 + 8 from Tough"), and Damage · amount · Heal. In Wild Shape the form HP
    comes first and the normal HP is shown as protected.
  - Tiles: the shield-shaped AC (button, opens the breakdown), Initiative, Speed (`ft` in Inter), Proficiency.
  - Footer: conditions and quick resources.
- **Collapsed** (`#vitals-summary`, `vitalsSummaryHTML()`): one line with HP cur/max, a state word (Bloodied, Critical,
  Down), Temp when above 0, AC, Init, Speed, PB, a "Wild Shape: <form>" chip and the visible conditions.
- **Control**: `.compact-toggle`, a small tab with "Less"/"More". It has `aria-label` "Collapse vitals"/"Expand vitals",
  `aria-expanded` and `aria-controls="vitals-body"`, and keeps focus.
- **Preference**: `localStorage['tavern-ledger:compact']` (`'1'`/`'0'`), the existing UI-preference key. With no stored
  choice, phones (≤ 700 px) start collapsed and wider screens expanded.
- **Quick resources** (`stripHTML()`): at most 4 class resources with ≤ 12 uses, then the player's own trackers, one
  "Spell slots" line (1st 4/4 · 2nd 3/3 …) and one "Pact Magic" line from the authoritative slot state. There are at most
  6 chips, then "+ N more in Play". Legacy hand-tracked slots appear only without a class slot table.

## Six-ability strip (2026-10-22, v5)

`.ab-score-grid.ab-strip`: a focusable `role="group"` ("Six ability scores, Strength to Charisma"), always in ABILITIES
order. Each `.ab-card` (`role="group"`, `aria-label` = full name) shows:
- the abbreviation (`STR`, Inter) and the full name (caption);
- the modifier (Cinzel, dominant) and the score input (base, Cinzel);
- in Wild Shape, the form score pill and a source chip, "From form" or "Retained from character";
- the adjustment note.

Layout: flex with `flex: 1 0 118px`. All six fit on one row from about 800 px. Below that the strip scrolls sideways
inside itself (`overflow-x: auto`, scroll snap, `scroll-padding-inline`, so a focused field brings its whole card into
view). The page never scrolls sideways.

## v6 components (2026-10-22): supersedes the v5 strip, the v5 collapsed line and the separate Skills section

- **Vitals panel** (`combatHTML()`):
  - Expanded: HP card, AC shield, Initiative, Speed and Proficiency cards, conditions and quick resources.
  - Collapsed (`.combat-bar.compact`): the same components smaller. The HP value and bar, the shield and the three cards
    stay. Damage/Heal, the temp field, notes and resources fold away. `.hp-temp-badge` ("+5 temp") and
    `.hp-state-text` (Bloodied, Critical, Down) stay visible. In a form, the form HP is the collapsed value.
- **Ability card** (`#ability-cards > .ab-block[data-ability]`, `role="group"`, `aria-label` = full name):
  - Left column `.ab-left`: gold Cinzel name, Cinzel modifier, score input pill (base). In a form: the form score pill and
    "From form" / "Retained from character", plus the adjustment note.
  - Divider.
  - Right column `ul.ab-list`: the save row (`.save-dot` diamond, bonus, gold "Saving Throw"), then `.skill-row`s (mark,
    bonus, name).
  - Constitution has the save row only.
- **Marker anatomy:**
  - `.prof-dot`: empty circle = not proficient; filled gold = proficient; gold with a double ring (`data-level="2"`) =
    expertise.
  - `.save-dot`: the same as a diamond.
  - The `title` names the source. A granted mark keeps its grant when tapped (only the manual mark changes).
- **Summary tiles** (`.sum-row > .sum-tile`): tracked label + Cinzel value. Inspiration is a toggle labelled by its tile.
- **Proficiency tile** (`.prof-chip`): granted = gold tint, solid border; manual = gold tint, dashed border;
  inactive = dark. A granted tile opens its source dialog.
- **Inventory metric card** (`.inv-summary > .inv-metric`):
  - icon disc, tracked label, Cinzel value with an Inter unit, a short note, optional action (Attuned: Show; Coins: Edit);
  - the same height and alignment for all four;
  - layout: 4 across on desktop, 2 × 2 at 900 px and below (icons hidden at 520 px and below).

## V6.1 hardening notes (2026-10-22)

- **Heading levels:** section h2 → card titles h3 (`.entry-name`, `.bg-name`, `.lin-name`) → parts h4 (`.bg-sub`) → Wild
  Shape parts h5. DM Space has a visually hidden section h2 (`[data-dm-heading]`) above its cards.
- **Touch targets:**
  - `.prof-dot` keeps a 20 px look with a 32 px hit area (`::after`, inset −8 px from the padding box);
  - `.compact-toggle` is 28 px tall on phones;
  - `.ac-button` is at least 28 × 36 px.
- **Home card loading mark:** `.cc-wait` ("…", `aria-label="loading"`) until the authoritative maximum HP and AC arrive.
- **Dialogs:** a dialog without a field focuses itself (`.modal[tabindex=-1]`).
