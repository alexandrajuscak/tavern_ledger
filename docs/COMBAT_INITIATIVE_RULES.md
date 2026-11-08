# Combat Builder: Initiative

The rules behind this page are in [COMBAT_RULES_AND_LICENSING.md](COMBAT_RULES_AND_LICENSING.md) (SRD 5.1 for 2014,
SRD 5.2.1 for 2024). Every value lives on the participant (`initiative`, `initiative_mod`, `initiative_roll`,
`initiative_mode`, `initiative_tiebreak`, `initiative_order`).

## Modifiers

| Combatant | Initiative modifier | Tie-break value |
|---|---|---|
| Player character | The sheet's value, sent when the character is added: DEX modifier (derived score, so lineage, ASI and items count) + misc Initiative bonus + item/feature Initiative bonus (derived stats). Without the derived read: DEX modifier + misc bonus | Dexterity score |
| SRD 5.2.1 monster | The printed Initiative modifier (e.g. Goblin Warrior +2; Adult Red Dragon +12) | Dexterity score |
| SRD 5.1 monster | DEX modifier (the 2014 stat block has no Initiative line) | Dexterity score |
| Homebrew | The definition's `initiative_bonus`, or the DEX modifier | Dexterity score |
| Typed-in | As entered | 10 |

The DM can change a modifier per combatant (`combat_update_participant {initiative_mod, tiebreak}`).

## Getting values: every value is a FINAL total

Players roll at the table and dictate the result. The value the DM types is the **final Initiative**: d20 + Dexterity +
every bonus and penalty already included. The app stores it exactly as typed and **never adds the modifier** (the modifier
column is shown as "reference" only). Values -20 to 60 are accepted, including 0 and negatives.

| Action | Behaviour |
|---|---|
| Player row | Name, modifier (reference), an input labelled **Final Initiative** (helper text: "Enter the total the player rolled, including all bonuses"; numeric keyboard on phones). Type `17`, press **Enter**: the value is saved and the focus moves to the next combatant still missing a value (then to Start). No Roll button: a player's Initiative is never rolled by the app. Stored as `initiative_mode = player` |
| Monster row: **Auto roll** (default) | `combat_roll_initiative`: d20 + modifier rolled on the server (advantage / disadvantage per `_combat_init_mode`); the row shows the final value and how it was made ("d20 12 + 2"); Reroll before Start. With the 2024 encounter setting the option reads **Fixed score** and uses the printed score |
| Monster row: **Manual total** | the same Final Initiative input as players; stored as typed (`initiative_mode = manual`) |
| Mode switch | UI only. Every stored value is a final total in both modes, so switching never reinterprets a value: a manual 14 stays 14 until the DM rolls; a rolled 14 stays 14 when the row switches to Manual. A stored manual value opens the row in Manual mode after a refresh |
| Group initiative | Copies added together share a `group_key` ("One roll for the group"; "Each rolls" turns it off). **Rolling** one member rolls the whole group once; a **manual total** typed for one member is given to every active member of the group in the same transaction (`combat_set_initiative`, since 20261107000200), so a second DM window never sees a split group |
| Individual initiative | "Each rolls" copies have no group key: each is rolled or typed on its own |
| Correction after Start | detail panel > Initiative > **Correct**: final total + a required reason; the combatant (or its group) moves to its new place; the event `initiative_changed` keeps the old values and the reason; Undo restores them |
| Duplicate protection | every request carries a request id (applied once); an unchanged value is not sent again (Enter + change event) |
| Clear | Before combat only: all values or monsters only |

The RPC `combat_roll_initiative(..., {"include_characters": true})` can still roll for a character when called directly
(API compatibility); the UI no longer offers it.

## Order

`_combat_sorted`, used by **Sort** and by **Start** unless the DM reordered by hand. It orders by:
1. Initiative, high to low;
2. a higher Initiative modifier (reference only: the final total itself is never recalculated);
3. a higher Dexterity score;
4. **player characters before monsters**;
5. group key (members of a group stay together), then name, letter and creation time.

This is a deterministic default, not a rule. Both SRDs leave ties to the people at the table:
- the GM decides among tied monsters;
- the players decide among tied characters;
- the GM decides between a monster and a character.

So the default is shown, never applied silently:
- the builder warns when ties exist;
- **Start** stops once with a **tie review** that lists every tie group (final Initiative, modifier, Dexterity, player or monster) with its default order and arrows to change it,
  then "Accept order and start" (`p_accept_ties`, recorded as `settings.ties_confirmed`);
- members of one group tied with each other are not a tie to review.

The optional 2014 d20 roll-off is not automated; the DM can type a value or reorder.

**Manual order.**
- Before combat: the ▲▼ arrows (`combat_reorder`, `settings.manual_order`); Start keeps it.
- During combat: allowed, needs the current turn revision (a stale reorder is refused) and is audited (`order_changed`).
  The order is otherwise locked once combat starts: Sort is refused.

## Start

`combat_start` requires:
- at least one active combatant;
- an Initiative for every active combatant who takes part in round 1 (it lists who is missing).

Combatants with `joins_round` > 1 may start without one and get one when they join.

It then:
- sets Round 1 and makes the first combatant who can act the current turn;
- resets turn counters and Legendary uses;
- processes that combatant's start of turn;
- fires reminders that are due at the start of round 1.

## Hidden, late and delayed combatants

| | |
|---|---|
| Hidden | Takes its turns (the DM runs it); invisible to players; "Reveal to players" when it appears |
| Delayed entry | `joins_round`: skipped until that round; shown greyed with "joins in round N" |
| Late participant | Added during combat with a typed Initiative or a server roll (a group joins on its group's value) and placed at its Initiative (after equal values); the round order is renumbered |
| Removed | Leaves the order (history kept); a removed current combatant is skipped by the next Next |
| "Skip its turns" | `active = false`: stays listed, never gets a turn until "Back in the order" |

## Turn moves

| Move | Effect |
|---|---|
| End turn · Next (`N`) | End of turn → next combatant who can act → round +1 after the last → start of turn (details in [COMBAT_BUILDER_ARCHITECTURE.md](COMBAT_BUILDER_ARCHITECTURE.md)) |
| Skip | `combat_next_turn(mode = skip)`: the same clocks, recorded as skipped |
| Previous (`P`) | Undoes the latest turn move. Restores effect clocks, Reactions and Legendary uses that did not change since; lists the others; asks first when clocks would change |
| Choose turn | Points the turn at any combatant (and round), with no clock changes; audited |
| Duplicate Next | The same click's request id is applied once; a Next from another window that saw an older turn gets "The turn already moved…" and the view reloads |

**Not implemented: a "Delay" action.** Neither SRD defines one for these rulesets. The DM can move a combatant in the
order (audited) or use Choose turn.

## Accessibility and mobile (2026-11-07)

- Inputs: `aria-label` "Final Initiative of <name>", `aria-describedby` = the helper text, `inputmode=numeric`,
  `enterkeyhint=next`; the modifier has a screen-reader text "Initiative modifier +3, reference only".
- Mode select: "Initiative mode of <name> (whole group of 3)"; Roll button: "Roll / Reroll Initiative for <name>".
- 390 px and 360 px: the table becomes one card per combatant; the Final Initiative field is at least 44 px tall; no
  horizontal page scroll (browser test I15/I16).
- Tests: `supabase/tests/combat_initiative_tests.sql` (32), `combined_followup_ui_test.py` I1–I18, Combat UI suite.
