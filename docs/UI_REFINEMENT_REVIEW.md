# UI refinement review (2026-10-22)

Manual review on the local stack (test frontend 127.0.0.1:5191, then the full browser suite on 5192), as `local-player`,
`local-dm` and synthetic users, at 1920, 1366, 820 and 390 px. Screenshots:
`%USERPROFILE%\tavern-ledger-local-backups\ui-refinement-2026-10-22\{before,after}\`. Findings: `docs/UI_REFINEMENT_AUDIT.md`.
Automated checks: `supabase/tests/browser/ui_refinement_ui_test.py` (68 checks).

## Abilities

Before reading labels the page shows five framed groups with a divider under each title: Ability scores (six cards with
score, modifier, item / lineage notes; proficiency bonus and inspiration on the header line), Saving throws (three columns,
diamond marks), Skills (the restored pre-refinement ability blocks, see "Correction" below), Senses and movement (walking
speed, other speeds, special senses, the three passive scores, then size / languages / resistances; manual base speed and
initiative bonus folded under "Adjust by hand") beside Hit dice and death saves, and Proficiencies (armor and weapon chips,
specific items, tools and languages; sources folded). Verified: SH1–SH6 (each section with its h2; headings never skip a level),
SH9 (page `rgb(14,14,18)`, section `rgb(23,23,30)`, card `rgb(35,35,45)`), SH9b (section gap > card gap + 6 px), SH11 (no nested
sections, no card three levels deep).

## Spells

Corrected the same day: the primary icon is the spell's school only (see "Correction" below). Current expectations:

| Spell | Primary icon | School badge | Damage chips | Result |
|---|---|---|---|---|
| Fireball | Evocation | Evocation | Fire (orange) | as expected (SI13, SI25, I1, I12) |
| Cure Wounds | Evocation | Evocation | none (Healing chip) | as expected (SI20, I2) |
| Shield | Abjuration | Abjuration | none | as expected (SI18, I3) |
| Detect Magic | Divination | Divination | none | as expected (SI19, I4) |
| Misty Step | Conjuration | Conjuration | none | as expected (I5) |
| Hold Person | Enchantment | Enchantment | none | as expected (I6) |
| Chill Touch | Necromancy | Necromancy | Necrotic (deep green) | as expected (SI14, SI26, I7, I12) |
| Minor Illusion | Illusion | Illusion | none | as expected (I8) |
| Polymorph | Transmutation | Transmutation | none | as expected (I9) |
| Ice Storm | Evocation | Evocation | Bludgeoning + Cold | as expected (SI21, SI22, I10, I13) |
| Chromatic Orb | Evocation | Evocation | Choose one: Acid or Cold or Fire or Lightning or Poison or Thunder | as expected (SI23, SI24, I11, I13) |
| Campaign custom "Grave Summons" (Conjuration, Necrotic damage) | Conjuration | Conjuration | Necrotic | as expected (I18) |
| Campaign custom "Quiet Omen" (Divination, no damage) | Divination | Divination | none | as expected (I19) |
| Campaign custom "Ember Lance" (Evocation, Fire) / "Warding Hum" (Abjuration) | Evocation / Abjuration | same | Fire / none | as expected (SI30, SI31) |

The icon helps scanning without overpowering the name (34 px on cards, 22 px in the picker); colour stays on the school edge,
the school badge and the small damage swatches, so cards are not more colourful than before. The text stays authoritative:
every damage type and the school are words (SI58), and the primary icon has an accessible label, the school name (SI27).

## Inventory

Equipped and the item list are separate sections with their own headers; item cards are lighter than their section; empty
slots stay folded; Attunement, Quick use, Containers and Old sheet items appear only when they have something (no empty panels).
The summary tiles sit on the page, above the sections. Verified: SH7, SH7b.

## Build

Next steps is a highlighted section only while something is open (Showcase Paladin: one feat choice, no lineage); otherwise it is
one quiet "Up to date" row with Level up. Classes, Class features, Lineage | Background (side by side from 900 px), Feats
(grouped by source with h3 group titles), Reminders and Your own features have their own frames. Verified: SH8, SH8b.

## New character

Created "Nova": Identity (name, campaign, level, optional portrait link) → Lineage (search "aasimar": the legacy Volo's version
is marked "Legacy content is not allowed in this campaign" and disabled; search "elf", first click opens Elf) → Lineage choices
(Player's Handbook version shown with Current badge, High Elf chosen, choices listed, "Still to choose" announced, saved anyway
after the confirmation) → Class (Wizard) → Review (Elf · High Elf, Wizard 1, speed, darkvision, open choices warning). The
database has `elf-phb` / `elf-high` and an empty race (CC38–CC48). Export carries the exact version and no invented race;
importing it restores the lineage; importing an old file with only "Tabaxi Ranger" keeps the text, maps nothing and warns
(CC52–CC53). At 390 px the search, the first tap and the footer buttons work without overflow (CC59).

## Old character with legacy race

"Legacy Human" (campaign, set up, standard rules): the Lineage section says "Legacy race has not been mapped to a Lineage",
suggests Human (exact name), and grants nothing (no lineage, no lineage-derived values: CC49, CC50). Review Human… opens the
picker on Human with its traits (the mechanical preview); saving is refused by the campaign (approval needed) and the sheet
offers Ask your DM; the race text stays (CC51b, CC54). "Legacy Gnome" (no campaign): Review Gnome… → Rock Gnome → saved; the lineage
is `gnome-phb` / `gnome-rock` and the old text is kept in the folded legacy detail (CC51). "Legacy Wood Elf": no suggestion
(ambiguous), keyboard-only search + Enter opens Dwarf, Escape returns focus to Choose lineage (CC49b, CC55, CC56).

## Mobile (390 px)

Sections keep a 1 px edge, 12 px radius and an 18 px gap; padding drops to 14 px (no tall empty margins); no horizontal overflow
on Abilities, Spells, Inventory or Build (SH10, SH12). Spell icon and name fit; damage chips wrap; the school badge stays readable.

## Issues found during the review and fixed

| Issue | Severity | Fix |
|---|---|---|
| The L2 card rule overrode the school-coloured left edge of spell cards | serious | `border-left-color: var(--school)` kept |
| The new-character dialog cleared the browser cache keys (tab preference, local connection) | serious | removed the cache clear |
| The local static server refused connections under parallel module loads (listen backlog 5) | serious (dev only) | backlog 128; the browser runner uses the project server |
| Lineage traits in Abilities were folded and easy to miss | moderate | shown under Senses and movement |
| Heading skips in Class features ("Next actions") and the Wild Shape panel; free-text spell groups | moderate | h3 / h4 |

## Open (moderate or polish)

- The attunement / neck artwork is thin at small sizes (no better asset in the collection).
- Sub-lineage versions are not checked against the content policy (the server checks the base version only); the picker does not
  mark them either.
- The vitals bar is still tall on phones (from the first review).
- Eight spell versions have an ambiguous damage relationship; Fire Shield and Destructive Wave data need a source review.

## Correction (2026-10-22, third pass)

Two parts of the refinement were reverted on request; nothing else changed. Automated checks:
`supabase/tests/browser/skills_spell_icon_ui_test.py` (44 checks). Screenshots: `%USERPROFILE%\tavern-ledger-local-backups\skills-icon-fix-2026-10-22\\`
(`preferred/` = before the refinement, `unwanted/` = after the refinement, `after/` = restored).

**Skills.** The refinement had replaced the Skills component with a flat, alphabetical three-column list with an ability tag on
each row. The user preferred the earlier design. The outer section stays (`#abilities-skills`: h2 "Skills", icon, count,
own surface and gaps, "How the proficiency marks work"); inside it the pre-refinement blocks are back: one `.ab-block` per
ability that has skills (Strength, Dexterity, Intelligence, Wisdom, Charisma), with the ability name (gold) and modifier on
the left behind a divider, and that ability's skills on the right (round mark, bonus, name, disadvantage badge), three blocks
per row on desktop, two on tablet, one on phones. Same CSS as before (`.ab-grid`, `.ab-block`, `.ab-left`, `.ab-list`), same
marks, titles (sources), keyboard cycling and focus restore. Differences from the old blocks, all because Ability scores and
Saving throws are now their own sections: no saving-throw row at the top of a block, no score input under the modifier, and no
Constitution block (it has no skills). Values come from the current read model (`skillBonus`, Wild Shape `form_total`, class /
lineage / background / feat / manual sources); no calculation changed.

**Spell icons.** Every spell's primary icon is its school (`spell.school.<school>`), from `resolveSpellIcon()` in
`js/spell-icons.js`; a missing or unknown school gets the generic spell icon. Damage, healing and other effects never pick
the icon; damage stays as colored chips (Fire orange, Necrotic deep green, "+" and "Choose one … or …"). Coverage:
`docs/SPELL_ICON_COVERAGE.md` (577 versions, 0 unresolved, 0 fallbacks, 0 missing / broken / blank).

## v5 (2026-10-22, fourth pass)

After the correction the user still saw "five abilities": the restored Skills blocks left out Constitution, so the
Abilities page showed five ability blocks with modifiers. v5 restores all six blocks. It also restores the six-ability strip,
the preferred vitals panel with a collapsed state, and the Cinzel display face. See docs/UI_VITALS_AND_ABILITIES_REVIEW.md.
