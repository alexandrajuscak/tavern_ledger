# Combat Builder: rules and licensing

This page lists the combat rules the Combat Builder implements and where each one comes from. It also says what
content the catalog may contain, and how 2014 and 2024 rules are kept apart.

Every rule fact below was checked against the text of the two official PDFs (retrieved 2026-11-06 with `pdftotext`):

| Source | File | Licence |
|---|---|---|
| **SRD 5.2.1** (2024 rules) | https://media.dndbeyond.com/compendium-images/srd/5.2/SRD_CC_v5.2.1.pdf (sha256 in `data/raw/srd_5.2.1/_manifest.json`) | CC-BY-4.0 |
| **SRD 5.1** (2014 rules) | https://media.wizards.com/2023/downloads/dnd/SRD_CC_v5.1.pdf | CC-BY-4.0 |

## Attribution

The Combat Builder shows the following statement on the Monster Library and on every SRD 5.2.1 stat block. It is stored with
the seed (`supabase/seed/combat_monsters.sql`) and in `data/raw/srd_5.2.1/_manifest.json`:

> This work includes material from the System Reference Document 5.2.1 ("SRD 5.2.1") by Wizards of the Coast LLC, available at
> https://www.dndbeyond.com/srd. The SRD 5.2.1 is licensed under the Creative Commons Attribution 4.0 International License,
> available at https://creativecommons.org/licenses/by/4.0/legalcode.

The SRD 5.2.1 legal page asks for no other attribution to Wizards. The pages therefore carry only this statement for SRD 5.2.1
content, and the existing SRD 5.1 credit for SRD 5.1 content ([CREATURE_CATALOG.md](CREATURE_CATALOG.md)).

## What the catalog may contain

| Content | Allowed | Where it lives |
|---|---|---|
| SRD 5.2.1 stat blocks (2024) | yes: a focused set of 73 (see below) | `public.combat_monsters`, `rules_version = '2024'` |
| SRD 5.1 stat blocks (2014) | yes: the 334 creatures already in Tavern Ledger | `public.creatures` (unchanged) |
| SRD 5.1 Legendary Actions (2014) | yes: the 32 legendary creatures | `public.creature_legendary_actions` (from the cached dnd5eapi.co JSON) |
| DM homebrew creatures | yes: user-authored | `dm_content` (type `creature`), materialized into `creatures` with campaign scope |
| Non-SRD monsters from commercial books | **no** | a DM may type their own version as homebrew |
| D&D Beyond account-only material | **no** | never fetched |
| Invented "official" statistics | **no** | — |

Every catalog row carries a stable id, name, rules version, source label, licence, a source reference, and whether attribution
is required. SRD 5.2.1 ids are prefixed `srd52-` (e.g. `srd52-goblin-warrior`), so they never collide with SRD 5.1 ids
(`goblin`).

### The SRD 5.2.1 set (73 stat blocks)

The set covers CR 0 to 21 and every common encounter role, picked from the 330 stat blocks of the SRD's "Monsters A-Z" and
"Animals" chapters:

- **Humanoids (18):** Commoner, Bandit, Bandit Captain, Cultist, Cultist Fanatic, Guard, Guard Captain, Scout, Tough, Tough Boss,
  Warrior Infantry, Warrior Veteran, Berserker, Knight, Priest Acolyte, Priest, Mage, Assassin.
- **Fey (6):** Goblin Minion, Goblin Warrior, Goblin Boss, Hobgoblin Warrior, Hobgoblin Captain, Bugbear Warrior. In SRD 5.2.1
  goblinoids are Fey.
- **Dragons (5):** White Dragon Wyrmling, Red Dragon Wyrmling, Young Red Dragon, Adult Red Dragon (legendary), and Kobold Warrior,
  which SRD 5.2.1 types as a Dragon.
- **Other types:**
  - Gnoll Warrior (fiend);
  - beasts: Wolf, Dire Wolf, Giant Spider, Brown Bear, Giant Rat, Swarm of Rats, Boar, Giant Wolf Spider;
  - undead: Skeleton, Zombie, Ghoul, Ghast, Shadow, Specter, Wight, Mummy, Vampire Spawn, Vampire (legendary), Lich (legendary);
  - fiends: Imp, Quasit, Lemure, Dretch, Hell Hound;
  - elementals: Air, Earth, Fire and Water Elemental, Magma Mephit;
  - constructs: Animated Armor, Flesh Golem;
  - oozes: Gelatinous Cube, Gray Ooze, Ochre Jelly, Black Pudding;
  - Owlbear, Basilisk, Mimic, Manticore, Ogre, Hill Giant, Troll, Aboleth (legendary).

`scripts/data-migration/combat_monsters_srd521.py --all <text>` parses 327 of the 330 SRD stat blocks without error. Two white
dragons and the Giant Centipede have column layouts it does not read, and none of the three is in the set. The set can grow
later by adding names to `PICK`.

**These rows are combat-only.** They are not in `public.creatures`, so they never appear as Wild Shape forms or companions.
This keeps the 2014 Wild Shape rules ([WILD_SHAPE_RULES.md](WILD_SHAPE_RULES.md)) exactly as they are: there are no
duplicate "Wolf" forms with 2024 numbers.

### What each SRD 5.2.1 row stores

The following are stored as printed:
- size, type, subtype, alignment;
- AC;
- HP and the hit dice formula;
- Initiative, both the modifier and the fixed score in parentheses;
- speeds;
- the six scores, saving throws that differ from the modifier, and skills;
- resistances, vulnerabilities, damage and condition immunities;
- senses and Passive Perception, and languages;
- CR, XP (and XP in lair) and PB;
- traits, actions, Bonus Actions, Reactions;
- Legendary Action uses (and uses in lair) with their options;
- spellcasting DC and attack bonus.

Each entry keeps its SRD text, which the licence allows with the attribution above. It also gets a structured digest:
- attack kind, to-hit, reach or range;
- save ability, DC and half-on-success;
- damage dice and types;
- recharge or per-day usage;
- the conditions it mentions.

## Rulesets: never combined silently

Every encounter stores exactly one ruleset: `2014` or `2024`. The builder's "Campaign default" choice resolves to a concrete
value when the encounter is created, using the campaign's `content_rulesets`
([CAMPAIGN_CONTENT_POLICY.md](CAMPAIGN_CONTENT_POLICY.md)):
- a campaign that allows only one ruleset gets that one;
- a campaign that allows both gets 2024, the current SRD.

The encounter records `ruleset_source = 'campaign_default'` and the DM can change the ruleset while the encounter is a draft.

Mixing rulesets is allowed but never silent. Adding a 2014 (SRD 5.1) monster to a 2024 encounter, or the reverse, shows the
monster's own rules version on its row and a "different rules version" badge. The participant keeps its own stat block. The
encounter-level rules (Initiative, surprise, concentration DC, condition summaries, difficulty) always follow the encounter's
ruleset.

## Rules implemented, by ruleset

| Topic | 2014 (SRD 5.1) | 2024 (SRD 5.2.1) | Combat Builder |
|---|---|---|---|
| **Initiative roll** | Dexterity check; the GM rolls once for a group of identical creatures | Same; the GM rolls for monsters, once per group of identical creatures | Server-side d20 + modifier; group initiative rolls once per group |
| **Monster Initiative modifier** | Not printed: the Dexterity modifier | Printed in the stat block ("Initiative +2 (12)") | 2014: DEX modifier; 2024: the printed modifier, and the score in parentheses can be used instead of rolling ("Use fixed score") |
| **Surprise** | A surprised creature can't move or take an action on its first turn, and can't take a reaction until that turn ends | A surprised combatant has Disadvantage on its Initiative roll | 2014: marker + reminder on its first turn, Reaction shown as unavailable until that turn ends, cleared at the end of it. 2024: the roll uses Disadvantage; no lost turn |
| **Invisible at Initiative** | — | Advantage on the Initiative roll | 2024: applied when the participant has an active Invisible condition at the roll |
| **Incapacitated at Initiative** | — | Disadvantage on the Initiative roll | 2024: applied when the participant has an active Incapacitated, Paralyzed, Petrified, Stunned or Unconscious condition at the roll |
| **Ties** | The GM decides among tied GM-controlled creatures, the players among their characters, the GM between a monster and a PC; optional d20 roll-off | The GM decides among tied monsters, the players among tied characters, the GM between a monster and a PC | Deterministic default (see [COMBAT_INITIATIVE_RULES.md](COMBAT_INITIATIVE_RULES.md)), every tie group highlighted for the DM, manual reorder before and (audited) during combat. No automatic roll-off |
| **Order during combat** | The initiative order stays the same from round to round | Same | The order is locked at Start; a manual move during combat is an audited event |
| **Delay action** | Not in SRD 5.1 | Not in SRD 5.2.1 | **Not implemented** as a rule. The DM can move a participant in the order (audited) |
| **Concentration DC** | DC 10 or half the damage taken, whichever is higher (no maximum) | DC 10 or half the damage taken (round down), whichever is higher, **up to a maximum of 30** | Calculated per damage instance with the encounter's ruleset; the DM marks Success or Failure |
| **Concentration ends** | Another concentration spell; failed save; incapacitated or killed | Another Concentration effect; failed save; Incapacitated or dead | Ends on Failure, on manual end, and when the concentrator gets an Incapacitated-type condition (with a confirmation notice) |
| **Bloodied** | No such term | "A creature is Bloodied while it has half its Hit Points or fewer remaining" | The tracker uses the app's existing labels (Healthy / Bloodied ≤ 50 % / Critical ≤ 25 % / Down / Defeated) for both rulesets; "Bloodied" also applies in 2014 as a display state only |
| **Legendary Actions** | "Only at the end of another creature's turn"; regains spent legendary actions at the start of its turn; options may cost 2 or 3 | "Immediately after another creature's turn"; regains all uses at the start of each of its turns; "Legendary Action Uses: 3 (4 in Lair)" | Uses counter per instance, reset at the start of the creature's turn, reminder after each other creature's turn; 2014 costs shown and spent; 2024 "in lair" uses chosen per participant |
| **Lair Actions** | Part of some SRD 5.1 lore (initiative count 20) | No separate Lair Action block; "in Lair" variants of uses and XP | Encounter reminders only ("Lair Action at Initiative 20", round/initiative triggers); never automated |
| **Reactions** | One reaction, regained at the start of your turn | Same ("You can take one Reaction ... until the start of your next turn") | Available/Used marker per participant, reset at the start of its turn |
| **Damage** | Temporary HP absorbs first; resistance halves, vulnerability doubles | Same; order: bonuses, then Resistance, then Vulnerability | Temporary HP first (monsters and linked characters). Resistance, Vulnerability and Immunity are **shown as reminders**; the DM enters the final number (no automatic halving) |
| **0 HP, player** | Unconscious, death saves | Same | "Down"; never removed or killed automatically; death saves stay on the sheet |
| **0 HP, monster** | Dies (GM may knock out) | Same | "Defeated", skipped in the turn order; the DM can restore |
| **Encounter difficulty** | Not in SRD 5.1 (the XP thresholds are in the 2014 DMG, not the SRD) | "Combat Encounter Difficulty": XP Budget per Character by party level, Low / Moderate / High (p. 202) | 2024 only: informational estimate from the party's levels and the monsters' XP. 2014 shows "Not available in the 2014 SRD". Homebrew without XP is listed as "not counted" |

### 2024 XP Budget per Character (SRD 5.2.1 p. 202)

| Level | Low | Moderate | High | | Level | Low | Moderate | High |
|---|---|---|---|---|---|---|---|---|
| 1 | 50 | 75 | 100 | | 11 | 1,900 | 2,900 | 4,100 |
| 2 | 100 | 150 | 200 | | 12 | 2,200 | 3,700 | 4,700 |
| 3 | 150 | 225 | 400 | | 13 | 2,600 | 4,200 | 5,400 |
| 4 | 250 | 375 | 500 | | 14 | 2,900 | 4,900 | 6,200 |
| 5 | 500 | 750 | 1,100 | | 15 | 3,300 | 5,400 | 7,800 |
| 6 | 600 | 1,000 | 1,400 | | 16 | 3,800 | 6,100 | 9,800 |
| 7 | 750 | 1,300 | 1,700 | | 17 | 4,500 | 7,200 | 11,700 |
| 8 | 1,000 | 1,700 | 2,100 | | 18 | 5,000 | 8,700 | 14,200 |
| 9 | 1,300 | 2,000 | 2,600 | | 19 | 5,500 | 10,700 | 17,200 |
| 10 | 1,600 | 2,300 | 3,100 | | 20 | 6,400 | 13,200 | 22,000 |

The budget is the sum of the per-character values for each linked player character's level, so a mixed-level party is
supported. The estimate always says "Estimate (2024 SRD guidance). Terrain, action economy and tactics matter more than the
number."

## Conditions

The condition catalog `public.combat_conditions` holds 15 conditions per ruleset. These are: Blinded, Charmed, Deafened,
Exhaustion (levels), Frightened, Grappled, Incapacitated, Invisible, Paralyzed, Petrified, Poisoned, Prone, Restrained,
Stunned and Unconscious. Each row has a short summary written by the project from the SRD text of its ruleset, plus a source
reference. The SRD text itself is not copied. Differences that matter at the table:

| Condition | 2014 (SRD 5.1) | 2024 (SRD 5.2.1) |
|---|---|---|
| Exhaustion | Six levels with a table: disadvantage on checks, halved speed, disadvantage on attacks and saves, halved HP maximum, speed 0, death | Cumulative levels: every D20 Test −2 × level, Speed −5 ft × level, death at level 6; a Long Rest removes 1 level |
| Grappled | Speed 0 | Speed 0 and Disadvantage on attacks against targets other than the grappler |
| Incapacitated | No actions or reactions | No action, Bonus Action or Reaction; Concentration is broken; can't speak; Disadvantage on Initiative |
| Invisible | Can't be seen without special means; attacks against it have disadvantage, its attacks advantage | The same plus Advantage on Initiative; not affected by effects that require seeing the target |
| Stunned | Incapacitated, can't move, speaks only falteringly; fails STR/DEX saves; attacks against it have advantage | Incapacitated; fails STR/DEX saves; attacks against it have Advantage |

The condition chips are **reminders**. The tracker never changes a calculation because of a condition, with three
exceptions, which are labelled "applied" in the UI:
- the Initiative roll modifiers above;
- "Incapacitated ends Concentration", which ends it after the DM confirms;
- Unconscious, which marks a linked character at 0 HP as Down.

## Advantage and Disadvantage

Both rulesets: if circumstances give a roll both Advantage and Disadvantage, they cancel and the roll is normal. The tracker
stores scoped states:
- next attack;
- attacks this turn;
- attacks against a target;
- incoming attacks;
- ability checks or one skill;
- saving throws or one save;
- Initiative;
- custom.

It shows the net result per scope ("Advantage", "Disadvantage" or "Normal (both)"). Nothing is applied to unrelated rolls, and
the DM can always set or clear a scope by hand.

## Excluded on purpose

- Non-SRD monsters, and any monster text from commercial books or D&D Beyond pages.
- Automatic damage calculation from Resistance, Vulnerability or Immunity: these are shown, and the DM enters the final number.
- Automatic saving throws, automatic attack resolution and target selection.
- Battle map, tokens, movement, line of sight, VTT features.
- A "Delay" turn action (in neither SRD).
- 2014 encounter difficulty (not in the 2014 SRD).
