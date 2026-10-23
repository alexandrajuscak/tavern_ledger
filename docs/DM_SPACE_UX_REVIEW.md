# DM Space and governed sheet — UX review

Manual-style walkthrough of the DM / player scenario (task spec §63) on the restored local data plus the governance demo
fixtures (docs/LOCAL_TEST_CHARACTERS.md), as `local-dm@example.test` and `local-player@example.test`, at 1366 px and
390 px (Microsoft Edge, headless, scripted with Playwright so it can be repeated; read-only: nothing was approved or
edited). Date: 2026-10-19. Complements the automated `dm_space_ui_test.py` (50 checks).

## Scenario covered

| Step | Result |
|---|---|
| DM opens DM Space, switches to *Local Standard Table* | Overview leads with the numbers that need action (2 pending, 0 failed, 1 returned), then *Needs attention*, *Waiting for you*, *At the table* (hidden condition marked 👁), recent content. |
| DM opens the pending request (Tough) | Header (status, character, player, time, link to the sheet), requested change, reason, the campaign rule that required approval, and the **result on the sheet**: Maximum HP 32 → 40, + Tough (2024, Feat). Note fields say when a note is required. |
| DM opens the stale request (Observant) | Warning "The character changed after this request was made" with what changed (Maximum HP 30 → 32) and *Refresh request*; **Approve is disabled** until refreshed. |
| Approvals / Party / Content / Assign / Hidden / Rules / Audit | All load without errors; Party card shows HP, AC, hidden condition, 2 requests, 4 open choices, 1 hidden note; Hidden lists the secret note and the hidden curse with Reveal; Rules explains each preset in one sentence. |
| Player opens *Standard Fighter* | Governance bar: "1 change not sent yet — Review & send", "2 waiting for the DM", "1 returned to you", Requests. Feats card: Alert (Approved request) and Ashwalker (Campaign custom, Campaign reward). |
| Player opens *Strict Wizard* | Lock banner: "Your DM has paused progression … Gameplay still works." with the DM's reason (*Between sessions*); HP and resources stay usable. |
| Player opens *Custom Cleric* | Only the Requests entry (no pending work); feats are DM-only there, so no request is offered. |

No console errors in either role or width; no horizontal page overflow in any section at 390 px.

## Findings and what was done

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | Review dialog at 390 px: the footer actions (Reject, Return for changes, Edit, Approve, Close) ran off the left edge of the dialog ("…n for changes" visible). | High (mobile DM cannot reach *Return for changes*) | **Fixed**: `.modal-footer` wraps (`css/styles.css`). |
| 2 | Speed tile said "Now 35 ft (class features)" for a speed bonus that comes from the Ashwalker feat (feat effects share the class-effect row shape). | Medium (wrong explanation) | **Fixed**: the note names the feat(s) ("Now 35 ft (Ashwalker)"); mixed sources say "class features and feats". |
| 3 | Stale warning listed raw keys ("hp max: 30 → 32"); requested changes showed version ids ("Feat tough-2024"). | Medium (DM-facing jargon) | **Fixed**: readable labels ("Maximum HP: 30 → 32", "Feat Observant (2024)") in `js/request-ui.js` / `js/dm-space.js`. |
| 4 | Overview stat "1 characters". | Low | **Fixed** (singular / plural). |
| 5 | Found while running the browser suite: after typing in the feat search, the first click on a result did nothing (the search box's `change` on blur re-rendered the list under the pointer). Same bug in the background picker. | High (looks broken) | **Fixed** in both pickers. |
| 6 | Lineage feat choice (Variant Human / Custom Lineage): the feat chosen in the picker was not taken over by the lineage dialog (hidden input not read, no `change` event) and the card showed the raw id. | High | **Fixed**; lineage card and dialog show "Observant (2014)". |
| 7 | A double / triple click on a spell-slot button could spend two slots now that the server answers within the click interval. | Medium | **Fixed**: the 2nd / 3rd click of a multi-click is ignored (separate clicks still count). |
| 8 | Quick add-then-remove of a manual proficiency could leave the mark stored (writes raced). | Medium | **Fixed**: manual proficiency writes are serialized. |
| 9 | Locked character: *Level Up* stays enabled; clicking it is refused by the server with the friendly lock message. | Low | Open — recommendation: disable governed buttons from `get_character_governance` decisions (the data is already on the sheet). |
| 10 | Fixture realism: *Standard Fighter* shows "4 open choices" (the fixture sets the class without its choices). | Info | Intended: it gives the DM something in *Needs attention*. |
| 11 | The character list (home screen) shows the stored base maximum HP; the sheet and the DM Party show the feat-aware maximum. | Low | Open (the list has no derived stats; noted in the final report). |

## Accessibility notes

Dialogs trap focus and return it on close (checked by DS40); sections are tabs with `aria-selected` and become a select on
phones; the DM Space panel is an `aria-live` region; every control has an accessible name (DS41). Colour is never the
only signal: request states use text chips, hidden items carry 👁 plus the word "hidden".

## How to repeat

`scratchpad/gov/ux_walk.py <screenshot dir>` (kept with the builders in `tavern-ledger-local-backups/builders_2026-10-19/gov`)
signs in as both demo accounts against the frontend on port 5191 and writes screenshots plus `ux_notes.txt`; it changes
nothing.

## Redesign of 2026-10-22

- **Overview** leads with one **Needs you** list, most urgent first: requests waiting (each with Review), approvals that
  could not be applied, characters at 0 HP or low HP, open choices, characters in initial setup. When it is empty it says
  "Everything is up to date". The counters follow and are dimmed at zero. "At the table" links to the party.
- Content-type icons come from the shared icon family. The "Create" buttons of the Content library are a quiet toolbar.
  DM-only timeline entries carry a "DM only" chip (no eye emoji).
- The custom preset reads "Custom rules: each kind of change is set individually" instead of "Every action is set one by one".
- The DM Space title uses the display face like the player pages; all controls use the shared tokens and buttons.
- On a character card in the home list, a DM sees "1 to review" or "1 returned to the player" instead of the player's wording.
- Deferred: a stepped content editor and lifecycle chips (Draft / Needs validation / Published / Archived) instead of the
  Status select (`docs/UI_MIGRATION_NOTES.md`).
