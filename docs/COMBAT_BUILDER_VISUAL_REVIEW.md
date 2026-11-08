# Combat Builder: visual review

The screenshots come from `supabase/tests/browser/combat_builder_ui_test.py` (synthetic campaign "UI Combat Campaign",
Microsoft Edge headless). They are stored **outside the repository**, in
`%USERPROFILE%\tavern-ledger-local-backups\combat-builder-2026-11-06\screens\` (`cb_*.png`). The full regression run writes
its own copies to `…\full-run-screens\`.

## Screens captured

| Screen | Files |
|---|---|
| Combat Home (empty, then with prepared and finished encounters) | `cb_home_empty_1366.png`, `cb_home_1366.png` |
| Encounter builder | `cb_builder_1920.png`, `cb_initiative_setup_1366.png` (Initiative setup with ties), `cb_builder_1024.png`, `cb_builder_390.png` |
| Monster Library | `cb_library_1366.png` (Goblin Warrior preview, Add form, attribution) |
| Tie review | `cb_tie_review.png` |
| Round 1, the current player turn, the current monster turn | `cb_round1_1366.png`, `cb_player_turn_1366.png`, `cb_monster_turn_1366.png` |
| Several conditions, Advantage + Disadvantage, concentration check | `cb_concentration_1366.png` |
| Hidden legendary creature with its stat block and Legendary pips | `cb_legendary_hidden_1366.png` |
| Live tracker at every width | `cb_live_1920.png`, `cb_live_1024.png`, `cb_live_820.png`, `cb_live_390.png`, `cb_live_360.png` |
| Detail drawer (tablet and phones) | `cb_drawer_820.png`, `cb_drawer_390.png`, `cb_drawer_360.png` |
| Reconnect / offline state | `cb_offline_1366.png` |
| Homebrew creature editor with validation errors | `cb_homebrew_editor_1366.png` |
| Completed encounter summary | `cb_summary_1366.png` |
| Error (unknown encounter: friendly message, Retry, Combat Home) | `cb_error_1366.png` |
| Loading (1.5 s latency: the labelled spinner) | `cb_loading_1366.png` |

Empty states ("No combat is running", "Add the party and the monsters…", "No creature matches…") appear in
`cb_home_empty_1366.png` and the library shots; loading and error have their own screenshots above.

## Review

What works:
- **Hierarchy.** The current turn is visible in under a second from across the table. The gold-bordered row with the
  arrow and "CURRENT TURN" pill, the round in large Cinzel, and the current name in the top bar agree.
- **Density.** Rows stay compact: Initiative, avatar, name and kind, HP bar with numbers and state, AC, at most four
  chips. Ten buttons per row were avoided: only − and + show (on hover, focus, the selected and the current row, and
  always on touch).
- **Fantasy, not admin.** The look comes from the existing tokens:
  - dark surfaces with the warm gold radial;
  - gold Cinzel section titles;
  - stat blocks with a deep-red top rule;
  - condition icons from the curated set.

  Controls and dense data stay in Inter.
- **Tablet (820).** One column with the detail as a bottom drawer above the sticky dock. The top bar wraps into two
  rows.
- **Phones (390 / 360).**
  - The current turn sits in the top block.
  - The dock keeps a wide **End turn · Next** with icon-only Previous, Undo and Effect (labelled).
  - The builder's Initiative table becomes one card per combatant, with the Initiative field first.

## Issues found and fixed

| Severity | Issue | Fix |
|---|---|---|
| Blocker | The effect dialog did not close after Apply (the button reference was lost after `await`), so the next click hit the dialog | Capture the button before awaiting (all dialogs) |
| Serious | 390 px builder: the Initiative table pushed the page 261 px wide. Its visually hidden header labels were positioned against the page | `.cb-table-wrap { position: relative }` and a card layout below 600 px |
| Serious | 360 px: the top bar (Combat + DM Space + name + Sign out) overflowed by 25 px | ≤ 400 px with the Combat link: no brand text, tighter icon links |
| Serious | Icon-only buttons on phones (Finish, Reminders, History, Previous, Undo, Effect) had no accessible name | `aria-label` on each; browser check A3 at 1366 and 390 px |
| Serious | The "turn" announcement was cleared by the next re-render | One persistent live region per mount |
| Serious | On a slow device a background re-render (character summaries arriving) closed an open quick-damage popover and cleared an amount typed in the detail panel (found by the perf probe at 4× CPU) | `repaint()` keeps the popover (value, mode) and the typed amount (value, focus, preview); an outside click still closes the popover |
| Minor | Speed listed "fly 80 ft, 40 ft, climb 40 ft" (walk not first) | Walk first |
| Minor | Quick −/+ stacked vertically made every row taller | Side by side |
| Minor | The summary's "Major events" repeated "Combatants joined" from the preparation | Only joins during the fight are major |
| Minor | History items started lower-case ("combat finished") | Capitalized |
| Minor | A result toast covered the dock (Undo / End turn) | Toasts rise above the dock while the tracker is open |

## Remaining (accepted)

- The live top bar takes about a third of a 390 × 844 screen. That is acceptable, because the dock keeps the main action
  reachable. A compact top bar would be a later refinement.
- Long names wrap rather than truncate (intentional: a truncated "Goblin Warrior …" is ambiguous at the table).
