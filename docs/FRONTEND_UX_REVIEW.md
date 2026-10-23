# Frontend UX review: classes and spellcasting

Review of the class, spellcasting and multiclass UI after the "all official classes" task (2026-10-17), done on the 13
showcase characters ([CLASS_TEST_CHARACTERS.md](CLASS_TEST_CHARACTERS.md)) at 1366 px and 390 px, with the keyboard, and
with an automated accessible-name sweep. API: [CLASS_FRONTEND_API.md](CLASS_FRONTEND_API.md).

## What changed

| Area | Before | Now |
|---|---|---|
| Choosing a class | a bare form; "Class features are not added"; subclass list only for spellcasting progressions; two class ids hardcoded in the card | guided **Choose class / Add class (multiclass)**: live preview (features, proficiencies, choices to make, slots / Pact Magic, resources), prerequisites of every class with the scores checked, DM override checkbox for unmet prerequisites, subclass when the level allows; starting equipment review for the first class (one option per group, concrete weapons for "any martial weapon", added to the inventory once) |
| Class page (Features tab) | long feature list | overview, Next actions (jump to the open choice), **At a glance** (attacks, critical range, riders with dice, feature DCs such as Ki save DC, states with Start / End, quick resources), subclass block, levels folded, finished choices folded, drafts kept across refreshes |
| Spells tab | free text first | spellcasting summary with DC / attack first, slots with class actions (recover slots, Flexible Casting, Eldritch Master), "Your spells" by readiness, spellbook acquisition |
| Combat tab | weapons only | class riders with *Spend a slot…* (Divine Smite, Eldritch Smite), active states (Rage), the Wild Shape panel |
| Resources | Use / Restore one at a time | pools and points spent by an amount (Lay on Hands, Ki); state-spent resources live on the state card |
| Wild Shape | not available | form picker (search, "only forms I can take", reasons for the others, cost), stat block, form hit points with Damage / Heal and carry-over, Return to normal form |
| Companions | not available | Companions card (catalog creature or custom), HP tracking, attacks, remove |
| Infusions | not available | Infused items card (count / limit), Infuse dialog with qualifying items and reasons for the others, replicate, homunculus, end, "Update infusions" after a level change |
| Saving throws | manual only | aura bonuses included, the source in the tooltip |
| Stats tab | class defenses invisible without a lineage | speed, senses, resistances and immunities from classes are listed even without a lineage |

## Findings fixed during the review

- `lineage-ui`: condition immunities became objects and printed as `[object Object]`; immunities from the lineage were
  overwritten by the class list (server fix: merged names plus a separate source list).
- Infuse dialog: a field named `item` collided with `form.elements.item()` and sent no item (renamed).
- Transformation refusals showed internal codes; they now explain the reason in words.
- The Wild Shape panel was titled after the first rule (Circle Forms); it now uses the resource name.
- The quick *Use* button of Rage spent a use without starting Rage; that resource now lives on the Rage card only.

## Accessibility (section 42)

- Accessible-name sweep: 0 unnamed buttons, inputs, selects or images on the class page, Combat, Spells, the form picker,
  Add companion and Add class dialogs (5 showcase characters).
- Every dialog closes with Escape and returns focus; dynamic status lines use `aria-live="polite"`; option lists use
  `aria-pressed`; disabled options carry the reason as text, not only color.
- Keyboard paths are covered by browser tests (End Rage with Enter, Escape on dialogs, focus kept by `data-focus-key`).
- No horizontal overflow at 390 px on the class page, Combat tab, form picker and Add class dialog (tested).

## Open follow-ups (not blocking)

- The Combat tab's legacy "Bonus actions / Reactions" lists only show free-text features; class features with an
  activation are not listed there yet (they are on the class page).
- The header speed card shows the stored speed with "Now 40 ft (class features)"; showing the derived value first
  would be clearer.
- Beast forms do not yet replace the character's physical scores in skill and save totals (shown as a rule).
- Wild Shape's quick *Use* button stays (Wild Companion spends a use without changing shape).

## Review: slots, proficiencies, spell visuals, backgrounds (2026-10-17, second task)

| Area | Before | Now |
|---|---|---|
| Slot Use / Restore | double spends on a double click; the count jumped back at 0.4–0.9 s click pace; focus lost at the maximum; Manual adjust closed after every click; short rest said "Nothing to restore" | one request per slot line (busy state, keeps focus), late answers ignored, slots-only Realtime refresh, status line, focus moves to the sibling button, open panels stay open; a rest ends with a summary dialog (Restored / Not restored / Ended). Details: [SPELL_SLOT_BUG_AUDIT.md](SPELL_SLOT_BUG_AUDIT.md) |
| Proficiency chips | class and lineage grants showed as unchecked; class items had a Remove button that did nothing | granted / manual / inactive states with source badges; a granted chip explains its source and links to it; Remove only for manual marks; skill and save tooltips name every source. [PROFICIENCY_RESOLUTION.md](PROFICIENCY_RESOLUTION.md) |
| Spell cards | plain grey; school as muted text; no damage information | school edge, tint and badge; damage chips (choose-one and dealt-together groups); readiness first; slot badge; tokens only. [SPELL_VISUAL_SYSTEM.md](SPELL_VISUAL_SYSTEM.md) |
| Background | free text only | Background card and picker (2024 / legacy, playtest on request), ability allocation with compatibility mode, choices, duplicates with replacement, equipment review, characteristics with Roll. [BACKGROUNDS.md](BACKGROUNDS.md) |

Findings fixed during this review:

- **Background picker:** the first click after typing in the search box was lost, because the blur's `change` event rebuilt
  the list under the pointer. The list is now only replaced when it changes.
- **Search fields across the app** (`type="search"`: spell filters, proficiency search, the background picker) had no styling.
  They now use the shared input style.
- **Inputs without a `type`** got no styling. The characteristics fields now set `type="text"`.
- **Stacked badges hid "Manual"** behind a "+1" badge. Chips now show 3 badges, and the overflow badge has a tooltip.

Open follow-ups:

- Other pickers that rebuild a list on `change` (lineage, add spell) should get the same "replace only when changed" guard.
  Not observed in tests, but the pattern is the same.
- Origin feats are references only; a feat engine would automate Alert, Tough, Skilled and others.

## Player-first redesign (2026-10-22)

The whole frontend was reviewed as a player and as a DM. The audit is in `docs/UX_INFORMATION_ARCHITECTURE_AUDIT.md`, the
journeys in `docs/PLAYER_JOURNEY_REVIEW.md` and the result in `docs/UI_DESIGN_SYSTEM.md`. In short:

- **Typography:** Cinzel (all capitals, old-style figures) is gone. Inter is used for all text, controls and numbers
  (tabular figures, distinct `Il1`). Alegreya is used only for the logo, page titles and the character name. Labels are
  sentence case.
- **Sections:** 8 tabs became 6: Play · Abilities · Spells · Inventory · Build · Bio. Gameplay (Play) and permanent build
  choices (Build) are separate. On phones the sections are a bottom bar.
- **Header and vitals:** a compact header with state chips (campaign, lock, requests, Wild Shape, choices). Level Up
  moved to Build, where it says "Request level up" when the campaign needs approval and is disabled with the reason when
  locked. The vitals bar is no longer sticky; the top bar shows HP and AC once the vitals scroll away.
- **Play:** Ready to use (states, DCs, quick resources), Attacks (with riders such as Divine Smite), and catalog class
  features grouped by timing (Action / Bonus action / Reaction / Free and special). Before, only free-text features
  appeared there. Passive features stay in Build.
- **Icons:** one illustrated family (`assets/icons`, `docs/UI_ICON_SYSTEM.md`) replaces the emoji.
- **Home:** cards show the derived maximum HP (feat bonuses included) and AC, plus state chips; there is a search box.
- **Spells / Inventory / Feats:** school icon first on spell cards; empty equipment slots folded; feats grouped by source.
- **Pickers:** search and results first; secondary filters under "Filters" (folded on phones).
- **Accessibility:** WAI-ARIA tabs with arrow keys, a global focus ring, a skip link, error toasts as alerts, ≥ 44 px
  touch targets on the phone navigation and HP controls, reduced motion respected, `--text-3` raised to AA contrast.

Manual findings and their status: `docs/UI_USABILITY_REVIEW.md`.
