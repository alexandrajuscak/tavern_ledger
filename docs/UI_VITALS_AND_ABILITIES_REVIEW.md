# Vitals, six abilities, Skills and medieval typography (v5, 2026-10-22)

This is a local-only frontend restoration. No backend, database, migration, RLS, governance or mechanics change.

## Evidence used

- **Preferred design.** Screenshots before the player-first redesign:
  `tavern-ledger-local-backups/ui-review-2026-10-22/before/` (01 combat, 02 stats). They show:
  - the HP card with Temp, Damage · amount · Heal;
  - the shield-shaped AC, Initiative, Speed and Proficiency tiles;
  - conditions and resource chips;
  - the collapse tab;
  - Cinzel names, headings and numbers;
  - ability blocks with their skills.
- **Before the refinement.** `ui-refinement-2026-10-22/before/`.
- **Before the previous correction.** `skills-icon-fix-2026-10-22/{preferred,unwanted,after}`.
- **Old font configuration.** Git `HEAD` `index.html` loaded Google Fonts
  `Cinzel:wght@600;700&Inter:wght@400;500;600;700`, and `css/styles.css` set
  `--font-display: 'Cinzel', Georgia, serif`.
- **Before screenshots** for this task: `tavern-ledger-local-backups/vitals-typography-2026-10-22/before/`.

No separate reference image was attached to the request, so the pre-redesign screenshots served as the vitals reference.

## Root causes

| Symptom | Confirmed cause | Correction |
|---|---|---|
| Only five abilities | The previous correction rebuilt the Skills blocks only for abilities that have skills (`ABILITIES.filter(a => SKILLS.some(...))`), so Constitution vanished, and the Abilities page showed five ability blocks with modifiers. The ability-score cards above were always six in the DOM. They wrapped 3 + 3 below 1000 px, so on a phone only three were visible at first. | All six Skills blocks are shown again (Constitution says "No skills use Constitution."). The score cards are now one strip that scrolls inside itself. |
| Skills changed | The UI refinement replaced the blocks with a flat alphabetical list. The correction restored the blocks without Constitution and without the score pill. | Six blocks with name, modifier and score pill on the left. |
| Vitals changed | The redesign kept the structure but removed Cinzel, flattened the AC shield (`clip-path: none`) and made the collapsed state just a squeezed copy of the panel (temp HP, conditions and Wild Shape hidden). The base maximum HP was an input beside Damage/Heal, and the resource strip listed every class resource and every slot level. | Shield AC restored. The collapsed state is a real summary line. The maximum shown is the authoritative one, and the base moved to Build. Quick resources are restrained. |
| Damage-first spell icons | Already replaced by the school-only resolver in the previous correction. The only remaining damage-icon code was the unused `damageIcon()` in `js/icons.js`. | `damageIcon()` removed. Coverage: 0 icons not taken from the school. |
| Fantasy identity lost | The redesign set Inter for every number and heading and Alegreya for four titles only (docs/UI_TYPOGRAPHY.md "History"). | Cinzel self-hosted. Semantic role tokens. Inter kept for all reading and controls. |

## Vitals panel

- **Expanded:**
  - HP card: current HP (Cinzel), `/ maximum` (authoritative: base + feat bonus), Temp, HP bar, the feat note
    ("Maximum 44: base 36 + 8 from Tough."), Damage · amount · Heal (44 px), and death saves when down.
  - Tiles: shield AC (gold, opens the breakdown), Initiative, Speed (`ft` in Inter), Proficiency.
  - Below: conditions and quick resources.
- **Collapsed:** one line with HP cur/max, a state word (Bloodied, Critical, Down), Temp (when above 0), AC, Init, Speed,
  PB, a "Wild Shape: <form>" chip and the visible conditions. It is about 70 px tall on a phone.
- **Control:**
  - a small "Less"/"More" tab, `aria-label` "Collapse vitals"/"Expand vitals", `aria-expanded`, `aria-controls`;
  - keyboard operable, and focus stays on the control.
- **Preference:**
  - stored in the existing `localStorage` key `tavern-ledger:compact`, kept across tabs and refreshes;
  - with no stored choice, phones (≤ 700 px) start collapsed and wider screens expanded;
  - an explicit choice always wins;
  - no database change.
- **HP controls:**
  - invalid, empty or negative amounts are refused ("Enter an amount first");
  - the field is cleared after use, so a second press cannot repeat the change;
  - a short result message ("Took 10 damage: 26 / 44.", "Healed 5: …");
  - Heal stops at the authoritative maximum;
  - in Wild Shape the existing form workflow runs: form HP first, lethal preview with carry-over, normal HP protected,
    Revert in Play.
- **Quick resources:** at most 4 class resources with ≤ 12 uses (e.g. Second Wind, Channel Divinity, Wild Shape), then
  the player's own trackers, one "Spell slots" line (`1st 4/4 · 2nd 3/3`) and one "Pact Magic" line from the
  authoritative slot state. There are at most 6 chips, then "+ N more in Play".
- **Conditions:** only the character's own condition list (no hidden DM data reaches the sheet). "+ Condition" is
  unchanged.
- **Sticky header:** unchanged. The top bar shows HP and AC only after the panel scrolls away, so the same values are
  never shown twice at equal prominence.

## Abilities

- Six cards in `ABILITIES` order, STR DEX CON INT WIS CHA. Each card is `role="group"` with the full name, and shows the
  abbreviation, full name, modifier (dominant, Cinzel), score (Cinzel) and adjustment note.
- One row from about 800 px. Below that the strip scrolls sideways inside itself:
  - touch, mouse or trackpad, or Tab through the score fields (`scroll-padding-inline` brings each whole card into view);
  - scroll snap;
  - a partly visible next card hints at more;
  - no page-level horizontal scroll.
- Modifiers use `+` and a true minus sign (`−1`).
- **Wild Shape:** STR, DEX and CON show the form's score with a "From form" chip, and the base score input is hidden
  (the note keeps "your score N"). INT, WIS and CHA show "Retained from character". Stored values are never overwritten.

## Skills

The six restored blocks sit inside the Skills section (h2, icon, own surface) in the same 3 × 2 arrangement as the
preferred screenshots (2 columns on tablets, 1 on phones). The proficiency marks and rows are unchanged: they cycle none →
proficient → expertise, and show source titles, disadvantage badges and values from the authoritative derived data.

Differences from the old blocks, kept on purpose:
- no saving-throw row (saves keep their own section);
- the score is a read-only pill (edit it in the strip);
- Constitution shows a one-line note instead of an empty list.

## Spell icons

The primary icon comes from the school only (`resolveSpellIcon()`), and damage types stay colored chips. Coverage on
2026-10-22 (575 versions):

| School | Versions |
|---|---|
| Abjuration | 60 |
| Conjuration | 108 |
| Divination | 40 |
| Enchantment | 61 |
| Evocation | 114 |
| Illusion | 36 |
| Necromancy | 44 |
| Transmutation | 112 |

Unresolved, fallback, damage-derived, missing, broken, blank and unlabelled icons: all 0. Examples:
- Fireball: Evocation + Fire chip.
- Cure Wounds: Evocation.
- Shield: Abjuration.
- Detect Magic: Divination.
- Misty Step: Conjuration.
- Hold Person: Enchantment.
- Chill Touch: Necromancy + Necrotic chip.
- Minor Illusion: Illusion.
- Polymorph: Transmutation.

A DM custom Conjuration spell with Necrotic damage gets the Conjuration icon (test I-series).

## Typography

See docs/UI_TYPOGRAPHY.md.
- Cinzel: logo, character name, page titles, DM Space title, fantasy section headings, fantasy card titles, spell names
  (≥ 701 px) and prominent numbers.
- Inter: everything read or operated.
- Interface headings opt out with `sectionHead({ variant: 'interface' })`.

## Verified examples (synthetic test characters)

| Fixture | Result |
|---|---|
| VA Tough Fighter (Fighter 4, base max 36, Tough) | Vitals `36 / 44`, note "base 36 + 8 from Tough", Heal 999 → 44, Init +2, Speed 30 ft, PB +2. Strip +3 +2 +2 −1 +1 +0 (16 14 14 8 12 10) |
| VA Low Fighter (8 / 40, temp 5, Poisoned) | Card state critical. Collapsed: `HP 8/40 · Critical · Temp 5 · AC 11 · Init +1 · Speed 30 ft · PB +2 · Poisoned` |
| VA Moon Druid as Brown Bear | Form HP 34 / 34 first, normal 45 protected, 40 damage asks first (6 carries over). STR 19 (+4), DEX 10 (+0), CON 16 (+3) "From form"; INT 12, WIS 16 (+3), CHA 10 "Retained from character" |
| Showcase Paladin (demo, read only) | 52 / 52, AC 19 shield, +0, 30 ft, +3, Channel Divinity, Divine Sense, "Spell slots 1st 4/4 2nd 2/2". Six Skills blocks: Strength +3 16 … Constitution +2 14 "No skills use Constitution." |
| Skill Icon Tester (Wizard 9 / Cleric 1) | Arcana +12 (expertise), History +8; score pills 10 12 12 18 14 10 |

## Tests

- `vitals_abilities_ui_test.py`: 90 checks.
  - V1–V28: vitals.
  - A1–A27: abilities and Skills.
  - T1–T23: typography.
  - R1–R10: responsive.
  - C1: console.
  - L1: local-only traffic.
- `skills_spell_icon_ui_test.py`: 44 checks (six blocks, school icons).
- Complete browser suite: 26 suites, 768 checks, 0 failed, run once and sequentially.
- Icon audit: 0 unresolved references, 0 fallbacks.
- Spell coverage: see above.

## Screenshots

`%USERPROFILE%\tavern-ledger-local-backups\vitals-typography-2026-10-22\`:
- `before\`: Paladin, Druid 8 and Wizard at 1920, 1366, 820 and 390, and home.
- `after\`: the same set after the change.
- `after\focused\`:
  - vitals expanded, collapsed, low and temp HP, low collapsed, and Wild Shape at 1366;
  - vitals expanded at 1920 and vitals at 820;
  - mobile compact and expanded at 390;
  - abilities at 1366, 820, 390 and in Wild Shape; abilities_1366_full;
  - skills at 1366, 820 and 390; header_1366;
  - spells at 1366, 820 and 390; spell_detail_fireball; picker_custom; dm_custom_spell_preview;
  - DM Space at 1366 and 390.

## Open (polish)

- In a form, the form-score pill is a little smaller than the base-score field it replaces.
- Cinzel has no tabular figures. Numeric boxes have fixed minimum widths instead.

## Superseded by v6 (2026-10-22)

The user preferred the original design. Two v5 elements were replaced (docs/ORIGINAL_UI_RESTORATION_REVIEW.md):
- the one-line collapsed vitals are now the original compact components;
- the six-ability strip plus separate Saving throws and Skills sections are now six ability-and-skills cards.

The authoritative maximum HP, the base maximum on Build, quick-resource rules, Damage/Heal feedback, the remembered
preference and Wild Shape sources stay.
