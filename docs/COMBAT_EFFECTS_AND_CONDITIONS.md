# Combat Builder: conditions, effects, advantage, concentration

Everything here is one table, `combat_effects` ([COMBAT_DATA_MODEL.md](COMBAT_DATA_MODEL.md)), written by `combat_add_effect`,
`combat_update_effect`, `combat_end_effect` and `combat_resolve_concentration`. The DM stays the authority: **the tracker
reminds, it does not resolve.**

## Applied vs reminder

| Labelled | Meaning | What |
|---|---|---|
| **applied to the tracker** | The system changes a number it shows | AC modifiers (row badge `AC 15+2`, detail `15 +2 = 17`), Speed modifiers |
| **reminder** | Shown, never calculated | Conditions, attack / save / damage modifiers, Resistance / Immunity / Vulnerability, advantage states, custom text |

Three rules are applied automatically, and each shows a visible notice:
1. 2024 Initiative roll modes from conditions ([COMBAT_INITIATIVE_RULES.md](COMBAT_INITIATIVE_RULES.md)).
2. An Incapacitated-type condition on a concentrating combatant shows "Concentration on X ends" with an **End
   concentration** button. The DM confirms; nothing ends silently.
3. A condition the stat block is immune to shows "immune to … (stat block)". The condition is still recorded, because the
   DM decides.

## Conditions

The 15 SRD conditions per ruleset (`combat_conditions`, summaries in
[COMBAT_RULES_AND_LICENSING.md](COMBAT_RULES_AND_LICENSING.md)) appear in a picker with icon, name and summary. The
picker shows the encounter's ruleset only. Exhaustion takes a level (1–6).

Every applied condition stores:
- key, target, source, visibility (players / DM only);
- start round and the combatant whose turn it was;
- duration and expiry timing;
- optional repeated save (ability, DC, start or end of turn);
- concentration link, notes, active state.

Chips are compact (name, remaining rounds). A dashed border and the screen-reader text "(hidden from players)" mark
DM-only effects. The full summary is in the chip's title and the detail panel.

## Durations and expiry

| Duration | Clock |
|---|---|
| Until removed | none |
| Rounds | counts down at the **anchor's** turn start (default) or end; ends at 0. The anchor is the source (default) or the target |
| Minutes | stored as rounds (1 minute = 10 rounds) with the minutes kept for display |
| Until the start of a turn | ends at the anchor's next turn start |
| Until the end of a turn | ends at the end of the anchor's **next** turn. If applied during the anchor's own turn, the current turn's end is skipped. "This turn" ends it at the current turn's end |
| Until a save succeeds | a reminder "WIS save DC 14 against Hold" at the end (or start) of the target's turn; the DM removes it on a success |

Expired effects appear in the turn notes ("Blessed ended on Aria"). A ticking effect shows the rounds left.
Previous Turn puts clocks back when they were not changed since.

## Custom effects

Name, description, source, targets (one or several), visibility, duration, optional save reminder, and the following
optional parts:
- an **AC** or **Speed** modifier (applied);
- an attack, save or damage modifier (reminder);
- a Resistance / Immunity / Vulnerability reminder with a damage type;
- a concentration link.

Examples:
- *Blessed* on three targets, 1 minute, linked to the cleric's concentration on Bless;
- *Half cover* +2 AC (applied);
- *Hunter's Mark* (reminder, concentration);
- *Cannot take Reactions until end of next turn*.

## Advantage and Disadvantage

The detail panel has quick **Advantage** and **Disadvantage** buttons.

**Scopes:**
- next attack, attacks this turn, all attacks, melee attacks, ranged attacks;
- attacks against one target (choose it);
- attacks against it (incoming);
- saving throws, one saving throw (choose the ability);
- ability checks, one skill or check (type it);
- Initiative;
- other (note).

**Duration:** removed by hand (for example after the attack), end of this turn, start of its next turn, or a number of
rounds.

**Display:**
- per scope, the net state: **Advantage**, **Disadvantage**, or **Normal (both)** when both exist on the same scope
  (the 5e rule);
- source, target and duration in the detail panel.

Nothing is applied to unrelated rolls. The only calculation that uses a scope is the server's Initiative roll mode.

## Concentration

- **Start.**
  - On the combatant, choose Concentration and give the spell or effect name.
  - Or, when adding a condition or effect, tick "Depends on the source's Concentration" and name it. The effects are
    then linked.
- **Only one at a time.** A second one asks "X is already concentrating on Y. Replace it?". Replacing ends the old one
  and everything linked to it.
- **Damage.** Every damage to the concentrating combatant adds a pending check to the concentration with the ruleset's
  DC:
  - **2024:** max(10, ⌊damage / 2⌋), at most **30**;
  - **2014:** max(10, ⌊damage / 2⌋), no maximum.

  The detail panel shows "Took 13 damage: CON save DC 10" with **Success** / **Failure**. The roll is never automatic.
- **Failure or End concentration** ends the concentration and all linked effects (`concentration_ended`). It is audited
  and announced. Undo brings them back if nothing changed since.
- **Duration.** A concentration that runs out ends its linked effects too.
- **Manual linking** is always available. There is no automatic spell-to-condition mapping yet.

## Reactions and Legendary Actions

- **Reaction:** Available / Used toggle on each combatant. It comes back at the start of the combatant's turn, except on
  a 2014 surprised creature's first turn, where it stays unavailable until that turn ends. Monster reactions are listed
  in the stat block. A row with a used Reaction shows "R✕".
- **Legendary Actions** come from the snapshot:
  - **uses:** SRD 5.2.1 uses, "in lair" when chosen at add; SRD 5.1 from `creature_legendary_actions`; homebrew from
    the definition;
  - **controls:** pips, **Spend 1**, one button per costlier option (2014 "Costs 2 Actions"), **+1** to give a use
    back;
  - **reset** at the start of the creature's own turn;
  - **reminder** "Legendary Action available: …" after every other creature's turn while uses are left.

## Lair and environment reminders

`combat_reminders`: lair action, hazard, reinforcements, environment, custom. Each one has:
- a round (or every round) and repeat interval;
- an Initiative count (fires when the turn passes that count, so 20 fires after the creatures at 20 or more);
- a DM-only flag and an active flag.

It fires once per round into the turn notes, with a **Done** button that acknowledges it. Nothing is applied.

## Finish

Effects on player characters that may outlast the fight are listed for review:
- untimed, minutes, save-ends, or more than 10 rounds left;
- concentrations of player characters.

For each one the DM chooses:
- **End it**;
- **Keep** (listed in the summary as still running);
- **Move to the character sheet**: a condition on the character via `apply_character_condition`, hidden if the effect
  was DM-only.

Every other effect ends with the encounter. Nothing is removed from a player without this review, and HP and resources
are not touched.
