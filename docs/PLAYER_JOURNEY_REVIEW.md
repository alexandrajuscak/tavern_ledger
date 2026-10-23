# Player journey review

The main journeys were walked through on the local app at 1366 px and 390 px. The demo player was
`local-player@example.test`, and synthetic test users covered the steps that change data. Counts are from the moment
the character sheet is open (taps or clicks; typing an amount counts as one step). "Before" is the layout of
2026-10-21 and "After" is the redesign.

## Daily character use

| Step | Before | After | Notes |
|---|---|---|---|
| Open character | home → find the card among 34 identical cards (scroll) | home → search box or "My characters" by campaign; the class emblem and "Paladin 6 · Human" make the card recognisable | the home card shows the **derived** max HP and AC |
| Understand current state | header + sticky combat bar (≈300 px) | header chips (campaign, lock, requests, Wild Shape, choices) + compact vitals | |
| HP, AC, resources | visible in the combat bar | visible in the vitals; after scrolling, HP / AC stay in the top bar | |
| Find attacks | Combat tab: "Equipped weapons", "From your class features", "Attacks" + "Add a weapon" | Play → **Attacks**: weapons, feature attacks, riders (Divine Smite, Sneak Attack) in one section; hand-made attacks behind "Add … by hand" | |
| Find spells | Spells tab: sources → slots → spellbook | same order, compact source cards, readiness chip and school icon first | |
| Use a resource | Resources tab (separate) or Features → At a glance | Play → **Ready to use**: Use next to the resource (1 tap) | |
| Take damage / heal | type amount → Damage / Heal | same (44 px buttons); in Wild Shape the form HP is shown first | |
| Finish a rest | header button → dialog → summary | same, quieter buttons; also on Spells → Spell slots | |

Remaining friction: the vitals bar is tall on phones (HP card + tiles ≈ 420 px). Players can fold it with the ⌃ toggle.

## Character creation

| Step | Path after the redesign | Clicks |
|---|---|---|
| Create | Home → **+ New character** → name (+ race, class text, campaign) → Create | 3 |
| Lineage | Build → Next steps "No lineage chosen yet — Choose" → picker → review | 4–6 |
| Background | Build → Next steps "Choose" → picker → review, then the starting-equipment review | 5–8 |
| Class | Build → Classes → **+ Add class** → class + level → review (+ starting equipment) | 4–6 |
| Abilities | Abilities → type scores | 6 |
| Complete choices | header chip "N choices to make" → Build → Next steps → Choose (jumps to the choice) | 2 + choice |
| Equipment | Inventory → + Add item / the starting equipment dialogs | |
| Review incomplete setup | header chip and Build → Next steps list everything still open | 1 |

Before the redesign, the class, lineage and background lived on **Bio**, the choices on **Features**, and the open-choice
count only in a header badge. Build now gathers the permanent choices in one place, with a Next steps list on top.

## Level progression

| Step | After |
|---|---|
| See what the next level gives | Build → Class features → "Next level preview" (folded, one tap) |
| Begin level-up | Build → Next steps → **Level up** (or **Request level up** when the campaign needs approval) |
| Locked character | the button is disabled and says "Your DM has paused progression for this character."; the header shows "Progression locked" |
| Choices, ASI or feat, spells | the level-up wizard (unchanged), then Build → Next steps lists the new open choices |
| Submit to DM | a refused permanent change opens "Ask your DM" (add to pending changes / send now); the header chip shows "1 waiting for your DM" |

## Spellcasting

| Step | After |
|---|---|
| Currently available spells | Spells → Your spells → **Ready to cast** (by level); "Not prepared" and "Not available yet" are folded below |
| Prepare / unprepare | the **Prepared** checkbox on the card (1 tap); the limit is shown on the source card ("Prepared 3 / 6") |
| Concentration, ritual | text badges with icons on the card |
| Slots | Spells → Spell slots: Use / Restore per level, Pact Magic separate, recovery features (Arcane Recovery) under it |
| Source of a spell | quiet source line at the bottom of the card; full grants in the details dialog |

## Inventory

Find an item (category chips with icons, counts), equip (**Equip** on the row, or pick a slot), use a consumable (**Use**),
inspect effects, attunement and charges (item dialog), and spot custom content (the "Campaign custom" chip). Empty
equipment slots are folded, so the equipped items lead.

## Wild Shape

Find a form (Play → Wild Shape → choose a form; filters and comparison in the picker) → transform (review dialog). The
header chip and the vitals then show the form's HP first, with "Normal form 45 / 45" protected below it. Damage and Heal
apply to the form, and the form sheet (attacks, senses, saves) is on Play. Revert is on the form card.

On a phone the form card and the vitals are long, but every control is reachable without sideways scrolling (UX17).

## DM approval

| Step | Player | DM |
|---|---|---|
| Submit | change → "Ask your DM" dialog → send | Overview → **Needs you** lists the request with **Review** |
| Pending | header chip "1 waiting for your DM"; home card chip | Approvals → Pending |
| Returned | header chip "1 returned to you" → opens the request list with the DM's note | |
| Approved | toast "Your DM approved: …", and the sheet reloads | audit log |

## Summary of improvements and remaining friction

- Fewer destinations: 8 → 6 sections. Resources and notes merged where they are used.
- Gameplay controls are 1 tap away from any section on a phone (bottom bar).
- Build actions take more steps, by design.
- Remaining friction (recorded in `docs/UI_USABILITY_REVIEW.md`):
  - tall vitals on phones;
  - the Wild Shape form sheet is long;
  - the picker dialogs keep their own (older) layouts.
