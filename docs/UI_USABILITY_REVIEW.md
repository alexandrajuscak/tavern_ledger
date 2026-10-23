# UI usability review (2026-10-22)

The review was a structured walkthrough of the redesigned app. Nobody outside the project tested it. Setup:

- local stack, test frontend on `127.0.0.1:5191`;
- demo accounts `local-player` and `local-dm`, plus synthetic users for the steps that change data;
- widths 1920, 1366, 820 (tablet) and 390 px, plus keyboard-only checks.

The automated checks that back these findings are in `supabase/tests/browser/ux_redesign_ui_test.py` (29 checks). The
other browser suites were updated to the new structure.

Severity: **blocker**, **serious**, **moderate**, **polish**. All blocker and serious findings below are fixed.

## Player: new or casual

| Question | Result | Finding / fix |
|---|---|---|
| Can the player understand the home page? | Yes | "Your characters", one sentence of help, "My characters" grouped by campaign, recognisable cards (class emblem, class · lineage, HP, AC). **Serious, fixed:** the cards used to show base max HP; they now show the derived max HP (UX1). |
| Can they identify their current character? | Yes | Search box when there are more than 6 characters; state chips (Wild Shape, Locked, requests) on the cards. |
| Can they find HP, AC and attacks? | Yes | Vitals at the top of every section; Play opens on Attacks after Ready to use. |
| Can they identify available spells? | Yes | Spells → "Ready to cast" first; the readiness chip is the first chip on every card. |
| Can they understand resources? | Yes | Ready to use shows "2 / 3 left · Back after a short rest" with Use; the vitals strip shows pips. |
| Can they tell what needs DM approval? | Yes | Build → "Request level up" with an explanation; refused permanent changes open "Ask your DM"; header chip "1 waiting for your DM". |
| Can they recover from an error? | Mostly | Errors are toasts with `role=alert`; failed slot changes say "The slots were not changed"; the home list has a "Characters could not be loaded … Nothing was changed … Try again" state. **Moderate, open:** some engine messages still come straight from the server (they are already sentences, not codes). |

## Player: experienced

| Question | Result | Finding |
|---|---|---|
| Can they reach frequent controls quickly? | Yes | Damage / Heal, Use, slot Use / Restore and rests are each one tap from the section; the phone bottom bar reaches every section in one tap. |
| Can they access source and calculation details? | Yes | AC breakdown button, "How it is calculated", "Details and source", spell detail dialog, "Where do these come from?", resource limits and recovery under Build. |
| Are advanced options still available? | Yes | Hand-made attacks, hand-tracked resources, your own features, manual slots, free-text class/background: all kept, folded. |
| Is the interface slower than before? | No | One extra batched read on Home (badges) plus derived stats per card (3 at a time, cached per character version). The sheet does no extra requests; Play reuses the class feature data already loaded. |

## DM

| Question | Result | Finding |
|---|---|---|
| Are urgent approvals visible? | Yes | Overview → "Needs you", each with Review. |
| Is party state scannable? | Yes | Needs you lists down / low-HP characters; At the table lists forms, conditions and locks; Party is unchanged. |
| Is the custom content lifecycle understandable? | Partly | **Moderate, open:** the status filter is still a select; lifecycle chips (Draft / Needs validation / Published / Archived) are recorded as deferred. |
| Are secrets clearly separated? | Yes | "DM only" chip in the secret colour on timeline entries; the Hidden section is unchanged; players never see DM Space (UX24). |
| Are campaign-rule consequences understandable? | Yes | Preset texts are sentences; players see why Level up is unavailable. |

## Mobile (390 px)

| Question | Result | Finding |
|---|---|---|
| Can the sheet be used with one hand? | Yes | **Serious, fixed:** the top tab strip scrolled sideways and hid the 5th–8th tabs; it is now a fixed bottom bar with 54 px targets (UX16, UX18). |
| Are common actions reachable? | Yes | Damage / Heal are 44 px; Ready to use is first on Play. |
| Are dialogs readable? | Yes | **Serious, fixed:** the spell and feat pickers showed 8–10 filters before the first result; secondary filters are now folded under "Filters" on phones. |
| Do controls remain visible? | Yes | Modal footers are sticky; toasts float above the bottom bar; no sticky element covers content (the vitals bar is no longer sticky). |
| Is scrolling reasonable? | Mostly | **Moderate, open:** the vitals bar is ≈ 420 px tall on a phone (fold it with ⌃); the active Wild Shape sheet is long. |
| Horizontal overflow | None | All six sections at 390 px (UX17) and all dialogs probed (level up, feat, lineage, add spell, add item, condition, AC). |

## Keyboard and screen readers

- Skip link "Skip to content" is the first Tab stop.
- Section tabs follow the WAI-ARIA tabs pattern: one tab stop, arrow keys, Home / End, `aria-controls` → `tabpanel` (UX4–UX5).
- Focus ring: a 2 px `--focus` outline on every focusable control.
- Modals keep the existing focus trap and restore focus by `data-focus-key`.
- Live regions: the save status and slot / Wild Shape status are polite; toasts are polite and errors use `role=alert`.
- Icons: decorative icons have `alt=""` and `aria-hidden`; meaning is always in text (UX8).
- **Polish, fixed 2026-10-22:** every sheet section now starts with `h2` section titles and nested groups use `h3`
  (`docs/UI_REFINEMENT_REVIEW.md`); the browser test checks that no section skips a heading level.

## Visual review notes (for the user)

Subjective decisions that are easy to adjust through tokens (`docs/UI_VISUAL_TOKENS.md`):

1. Display face **Alegreya** for titles and names. Alternatives that keep readability: Fraunces, Spectral.
2. Gold is the only accent for selection and the primary action. It could be softened (`--accent`).
3. Section titles are warm off-white with an illustrated icon instead of gold small capitals.
4. The illustrated icons are colourful. If they feel busy, sizes can drop (section titles 22 → 18 px) without changing markup.
5. The vitals bar can be folded by default on phones (one line in `getCompact`).

## Follow-up (2026-10-22, refinement)

A second pass fixed the open findings about separation and structure: four surface levels and one section component, a damage-first
spell icon, a central icon registry with fallbacks, and the lineage-based new-character dialog. Findings and results:
`docs/UI_REFINEMENT_AUDIT.md`, `docs/UI_REFINEMENT_REVIEW.md`. Still open from this review: the vitals bar height on phones,
DM content lifecycle chips, verbatim server messages.

## Correction (2026-10-22, third pass)

The damage-first spell icon was replaced by a school-only primary icon (damage stays as chips), and the Skills section shows
the earlier ability blocks again inside its own section frame. Details: `docs/UI_REFINEMENT_REVIEW.md` "Correction".

## v5 (2026-10-22, fourth pass)

- HP, AC, Initiative, Speed and Proficiency are again the first thing on the sheet. On phones the collapsed summary uses
  about 70 px, and "More" brings back Damage and Heal (44 px targets).
- Collapsing is remembered per browser. A low-HP state is written out ("Critical", "Down"), not shown only as colour.
- All six abilities are always in the strip. On phones it scrolls sideways (touch, mouse wheel or trackpad, Tab through
  the score fields), and Charisma is never clipped.
- The Skills blocks are back for all six abilities, including Constitution, in the same 3×2 arrangement as before.
- Cinzel brings back the fantasy tone for the name, headings and big numbers. Labels, buttons, inputs and all
  descriptions stay in Inter.

## v6 (2026-10-22, fifth pass): original visual language

- **Vitals:** HP, AC, Initiative, Speed and PB are the first thing on the sheet, with the original weight. The collapsed
  panel keeps the same components, just smaller.
- **Abilities:** each skill sits under its ability again, with its saving throw. Passive Perception, Passive Insight and
  Inspiration are on the first screen of Abilities.
- **Headings:** there is one heading voice (gold Cinzel), so sections are easy to tell apart; functional headings are
  quieter.
- **Inventory:** the inventory status reads in seconds (4 metric cards). Coins has an Edit action that focuses the gold field.
