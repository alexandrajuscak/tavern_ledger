# Wild Shape UX review (2026-10-17)

This was a manual gameplay review on the local stack (Edge, 1366 × 900 and 390 × 844). It used the demo player's Wild
Shape fixtures ([LOCAL_TEST_CHARACTERS.md](LOCAL_TEST_CHARACTERS.md)) and the automated walkthrough in
`supabase/tests/browser/wild_shape_ui_test.py`. No console errors appeared and there was no non-local network traffic.

## Scenarios played

| Scenario | What was checked | Result |
|---|---|---|
| Druid 2: pick a form | Limits are readable at a glance (CR 1/4, 🔒 swim from 4, 🔒 fly from 8, seen required). The Wolf is a favorite quick button | clear |
| Moon 6: Brown Bear turn | Choose → review → transform. Bite / Claws ready with hit and damage. Take 10, heal 5, take lethal damage (confirmation shows the carry-over) | about 4 clicks from idle to attacking |
| Moon 6: Giant Spider | Web with recharge 5–6: Use → Roll recharge; DC 12 STR check and the Restrained chip; Bite DC 11 CON with the poison clause | clear |
| Moon 2: wounded bear, Combat Wild Shape | slot choice (no default), own roll, toast with the result; slot spent once | clear |
| Moon 10: Earth Elemental | Elemental kicker, 2 uses spent, resistances and immunities listed under Defense, burrow and tremorsense | clear |
| Druid 20 | Unlimited uses, Beast Spells / Archdruid can cast | clear |
| Fighter 3 / Druid 4 | "Druid level 4 (character level 7: Wild Shape uses the Druid level)"; equipment merge by default | clear |
| Second page open | Realtime updates the form HP | works |

## Issues found and fixed during the review

1. **Header HP looked like it applied to the character.** A note under the HP card now says the form takes damage and
   healing, and normal HP is protected. The main Damage / Heal buttons route to the form.
2. **The header speed showed the character's speed.** It now shows "Form: walk 40 ft · climb 30".
3. **Long ability source labels wrapped** ("From Brown Bear"). They are now short Form / Kept labels, with the full
   source in the title and for screen readers.
4. **Mobile picker:** the filters filled the first screen. Search stays visible; the filters fold under 600 px, so the
   first form card is on the first screen (tested, WSU73).
5. **Desktop card grid left half a row empty.** It now uses at most two columns.
6. **Ability modifiers wrapped inconsistently** ("8 −1" vs "20 / +5"). The modifier now has its own line.
7. **Octopus Ink Cloud showed "+0 to hit".** The source had a spurious bonus on a non-attack. The generator now keeps a
   bonus only for real attacks.
8. **Enforce-mode bug** (engine): an unseen form was allowed through a NULL `allowed` value. Fixed, and covered by SQL
   tests.

## Accepted as is

- **Printed SRD attack bonuses that differ from STR/DEX + PB** (Brown Bear +5, Black Bear +3) are shown exactly as
  printed. They are listed in [WILD_SHAPE_COVERAGE.md](WILD_SHAPE_COVERAGE.md) so a DM can compare them with their book.
  The app never "corrects" them.
- **Mechanics are not applied to targets:** the conditions and DCs are a reference for the table.
- **Pact slots for Combat Wild Shape** are offered as a table option with a note, not as a default.

## Follow-up ideas (not done)

- A "last used" chip on the idle panel.
- An optional compact "battle card" view hiding the traits and retained features.
- Initiative order integration.
