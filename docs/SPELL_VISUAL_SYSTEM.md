# Spell visual system

Visual language of the Spells tab (2026-10-17). Code: `js/spell-ui.js` (`schoolBadgeHTML`, `effectTagsHTML`, `readiness`,
`spellCardHTML`), `css/styles.css` (tokens on `:root`, card rules). Tests: `supabase/tests/browser/spell_visual_ui_test.py`
(13 checks) and `skills_spell_icon_ui_test.py` (school-only primary icon).

## Audit (before)

- **Spellbook cards** (catalog spells) were plain grey: the school was muted text at the end of the meta line, there was no
  damage information on the card, and the readiness state sat at the bottom among the source badges.
- **The older free-text cards** had damage-type colors (`.dt-*`). Their values were hardcoded, and necrotic was a pale grey-green.
- **The school badge** existed only in the detail dialog, always blue.

## Tokens

Defined once on `:root`. The app has one dark theme, so one set covers every view.

| School | Token | Color | | Damage | Token | Color |
|---|---|---|---|---|---|---|
| Abjuration | `--school-abjuration` | cyan `#4fc3e8` | | Acid | `--dmg-acid` | chartreuse `#c9dc3c` |
| Conjuration | `--school-conjuration` | violet `#a87cf0` | | Bludgeoning | `--dmg-bludgeoning` | stone `#b0a493` |
| Divination | `--school-divination` | gold `#e6c35c` | | Cold | `--dmg-cold` | ice blue `#86d8f2` |
| Enchantment | `--school-enchantment` | pink `#e872b8` | | Fire | `--dmg-fire` | **orange** `#f5873b` |
| Evocation | `--school-evocation` | red `#ec5b4f` | | Force | `--dmg-force` | violet-blue `#9d8cf6` |
| Illusion | `--school-illusion` | indigo `#7f86f2` | | Lightning | `--dmg-lightning` | electric yellow `#f5d442` |
| Necromancy | `--school-necromancy` | **green** `#4cbb6c` | | Necrotic | `--dmg-necrotic` | **deep green** `#3fae6d` |
| Transmutation | `--school-transmutation` | amber `#e89a3c` | | Piercing | `--dmg-piercing` | steel blue-grey `#9fb4c9` |
| (unknown) | `--school-none` | grey | | Poison | `--dmg-poison` | toxic green `#8ee05a` |
| | | | | Psychic | `--dmg-psychic` | magenta `#e879c9` |
| | | | | Radiant | `--dmg-radiant` | warm gold `#ffd166` |
| | | | | Slashing | `--dmg-slashing` | crimson `#e05866` |
| | | | | Thunder | `--dmg-thunder` | deep cyan-blue `#4ea6dc` |
| | | | | Healing / Temp HP | `--effect-healing` / `--effect-temp-hp` | green `#5fd38d` / blue `#6fb8e0` |

The free-text damage rolls (`.dt-*`) now use the same damage tokens.

## Precedence

1. **The school owns the card.** It sets the 4 px left edge, a 7 % tint of the panel (`color-mix`, with a plain panel as
   fallback), the school badge and the keyboard focus ring.
2. **Damage types are chips**: a swatch plus the type name, with the colored border from the damage token and the text in the
   normal text color. They never color the whole card, so school and damage never compete as two backgrounds.
3. **Green is never ambiguous.** A green card edge means Necromancy (the school badge says so). A green chip with the word
   "Necrotic" means necrotic damage. The two tokens differ, and the words decide.
4. **A spell without damage** (Shield, Invisibility) shows only its school, with no damage color. Healing and temporary hit
   points have their own chips ("Healing", "Temp HP").

## Multiple damage types

- **One type:** one chip.
- **Choose one** (`damage_mode = choice`, e.g. Chromatic Orb): one dashed group labelled "Choose 1" with the chips joined
  by "or". Its `aria-label` is "Choose one damage type: Acid, Cold, …".
- **Dealt together** (`damage_mode = simultaneous`, stored as one effect row per type, e.g. Ice Storm, Flame Strike): one
  solid group with the chips joined by "+". Its `aria-label` is "Deals Bludgeoning and Cold damage".
- **Several separate effect rows** of different single types: one chip each, with duplicates removed.
- **Types known without effect rows:** shown from `damage_types` with their relation. A type is never invented.

## Card hierarchy

1. **Readiness pill** ("Prepared", "Always prepared", "Ready" for cantrips, "Known", "Innate", "Not prepared", "From
   level N"). Each has its own marker (● ★ ○ ◇), so it doesn't rely on color.
2. Spell name (a button that opens the details).
3. Level (top right).
4. School badge.
5. Damage, healing or temp HP chips.
6. Concentration, Ritual, and the slot ("Slot 3rd+", or "No slot" when a grant casts it without one).
7. Casting time, range, duration, components.
8. Source badges (class, lineage, item).
9. Save DC / attack bonus and the Prepared toggle.
10. Everything else stays in the detail dialog, which repeats the school badge and the damage chips.

Add Spell and catalog browsing stay in their own dialog, separate from "Your spells".

## Accessibility

- **Color is never the only signal.** School, damage type, effect, readiness, concentration and ritual are always words. The
  swatches are `aria-hidden`, and the groups carry `aria-label`s.
- **Contrast (dark theme):** every school and damage token is at least 3:1 against both panel colors, as a non-text marker.
  Text on a tinted card is at least 10.9:1 (normal text) and 4.7:1 (muted text). Chip text uses the normal text color, never
  the token.
- **Keyboard:** the card shows a focus ring in the school color whenever something inside it has focus. The name button opens
  the details with Enter, and Escape closes them.
- **No inline styles.** Colors come from tokens chosen by `data-school`, `data-dmg`, `data-effect` and `data-ready`.
- **Layout:** no hover-only information and no animation. At 390 px the cards stack, chips wrap, and there's no horizontal
  overflow (tested).

## Known data gap

Some catalog spells have damage or temp-HP text but no structured effect row (for example False Life has no `temp_hp` row).
They show their school only, until the catalog effect data is completed. No color is guessed.

## Redesign of 2026-10-22

- The **school icon** (illustrated, `assets/icons/spell-schools/`) now leads every spell card and every spell picker row.
  It is decorative, because the school badge keeps the name. The school colours, damage-type colours (Necromancy green,
  Necrotic deep green, Fire orange) and the precedence rules above are unchanged.
- Card order: icon + name + level → readiness chip (first chip), school, damage / healing chips, Concentration and Ritual
  (with icons and words), slot hint → casting time · range · duration → Save DC / to hit + Prepared → quiet source
  line. Components moved to the details dialog.
- The readiness chips no longer use symbol prefixes (●, ★, ○); the word carries the meaning.
- Picker rows show "Ritual" / "Conc." instead of the letters R / C.

## Primary icon: the school only (2026-10-22, corrected)

The first refinement pass made the primary icon damage first; that was reverted the same day. The rule now is:

**Spell school → one primary spell icon** (`resolveSpellIcon()` in `js/spell-icons.js`, the only resolver; every spell view
uses it).

| Spell data | Primary icon |
|---|---|
| one of the eight schools | that school (`spell.school.<school>`) |
| school missing or not recognised | generic spell icon; the badge says "School not resolved" |
| school icon missing or fails to load | generic spell icon; school name and colour stay |

- Damage stays structured data for the chips (`spellDamage()`): effect rows (`spell_effects.damage_mode` single /
  simultaneous / choice) where a view has them (spellbook, details, DM preview), otherwise the damage-type links (`always` /
  `choice`) of the catalog. Campaign custom spells get their effect rows attached in the catalog loader.
- Never the damage type, healing, temporary HP, control, defense, movement, summoning, utility, the spell name, class lists
  or automation status: Fireball and Cure Wounds both show the Evocation icon; Healing and Temp HP stay chips.
- The school stays visible: school badge (text), card edge and tint. Necromancy (school, green) and Necrotic (damage, deep
  green) stay separate: a Necromancy spell without damage shows the Necromancy icon and no damage chip; a non-Necromancy spell
  with Necrotic damage keeps its own school badge and edge.
- Relationship in text: "+" between types dealt together, "Choose one" with "or" for a choice, commas when the relationship is
  not stored (ambiguous). Compact picker rows add the damage in words (" · Fire", " · Bludgeoning + Cold", " · Choose one: …").
- Card order: school icon → name → level; readiness chip → school badge → damage chips → Concentration / Ritual → slot hint;
  casting time · range · duration; to hit / DC + Prepared; sources.
- Coverage report: `docs/SPELL_ICON_COVERAGE.md` (`scripts/local/spell_icon_coverage.py`). Data to review: Fire Shield is
  stored as fire + cold dealt together, although the caster chooses warm or chill; Destructive Wave stores thunder inside the
  choice although thunder is always dealt; 8 versions with separate damage rows are "ambiguous".

## Typography (2026-10-22, v5)

Spell names on cards use Cinzel from 701 px up and Inter on phones. Level, school badge, damage chips, casting time,
range, concentration, ritual, prepared state, descriptions and effect details stay in Inter. The primary icon is still the
school only, and damage types stay colored chips.

## v6 (2026-10-22)

Spell cards are unchanged. The spell name is Cinzel in warm white from 701 px up (not gold), and the school colour stays on
the badge and the card edge. Section headings in Spells follow the shared gold Cinzel rule. The primary icon is still the
school only.
