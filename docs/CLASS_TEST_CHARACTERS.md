# Class showcase characters

Thirteen synthetic characters, one per official class, made by the local demo seeder together with the demo characters of
[LOCAL_TEST_CHARACTERS.md](LOCAL_TEST_CHARACTERS.md). **Local only.**

```
.\scripts\seed-local-demo.ps1            # create what is missing (existing characters are left as they are)
.\scripts\seed-local-demo.ps1 -Repair    # re-apply the showcase setup to these characters only
```

- **Account:** `local-player@example.test` (owner), `local-dm@example.test` (campaign DM); password `local-dev-password`.
- Every showcase character has a fixed id derived from its name; the seeder never touches any other character. A character
  you made yourself with the same name is reported and skipped.
- Everything is set through the same RPCs the app uses (subclass, optional replacements, choices, states, Wild Shape,
  companions, infusions), so each character also exercises the API.

Abbreviations: PB = proficiency bonus, DC = save DC.

| Character | Class / subclass | What to look at |
|---|---|---|
| Showcase Barbarian | Barbarian 6, Path of the Berserker | **Rage is active**: Combat tab shows *End Rage*; greataxe 1d12 + 5 (STR +3, Rage +2); resistances bludgeoning / piercing / slashing and immunity to charmed / frightened on the Stats tab. End Rage: greataxe 1d12 + 3. AC 15 without armor (Unarmored Defense 10 + DEX 2 + CON 3). Speed 40 (Fast Movement). Rage 4 / 4 (the seeder starts Rage without spending a use). |
| Showcase Bard | Bard 6, College of Lore | Bardic Inspiration d8 (CHA uses, short rest from 5); Expertise in Performance and Persuasion; Jack of All Trades on other skills; Cutting Words; Additional Magical Secrets Fireball and Counterspell (any list, castable level 3). |
| Showcase Cleric | Cleric 5, Life Domain | Life Domain spells always prepared (not counted); Channel Divinity 1; Disciple of Life note; Destroy Undead CR 1/2; heavy armor proficiency. |
| Showcase Druid | Druid 6, Circle of the Moon | **In Wild Shape as a brown bear** (Combat tab and class page: form HP 34 / 34, Damage / Heal, Return to normal form); Wild Shape 1 / 2 left; Choose a form lists CR up to 2 (no flying forms before level 8). Companions: owl "Pip" (Wild Companion, optional feature on). |
| Showcase Fighter | Fighter 5, Champion | Defense style (+1 AC: chain mail 16 + shield 2 + 1 = 19); 2 attacks; critical hit on 19–20; Second Wind and Action Surge. |
| Showcase Monk | Monk 6, Way of the Open Hand | AC 16 (10 + DEX 3 + WIS 3); speed 45; Martial Arts 1d6 + 3 unarmed strike; Ki 6 / 6 spent by an amount; Ki save DC 14; Wholeness of Body 1 / 1. Equip a shield: AC and speed bonus go away. |
| Showcase Paladin | Paladin 6, Oath of Devotion | Aura of Protection +3 on every save (hover the save for the source); Divine Smite *Spend a slot…* (2d8 per 1st-level slot); Lay on Hands 30 spent by an amount; immune to disease; Defense style (AC 19). |
| Showcase Ranger | Ranger 5, Hunter | Tasha's replacements on: Favored Foe (1d4 rider, PB uses) and Deft Explorer (Survival expertise, Elvish and Sylvan, speed +5 from 6); Colossus Slayer 1d8 rider; Archery style (+2 to the longbow). |
| Showcase Rogue | Rogue 5, Thief | Sneak Attack 3d6; Expertise in Stealth and thieves' tools; Cunning Action, Uncanny Dodge; Fast Hands / Second-Story Work reminders. |
| Showcase Sorcerer | Sorcerer 6, Draconic Bloodline (red) | Sorcery points 6, Flexible Casting dialog; Quickened and Twinned Metamagic; AC 15 without armor (13 + DEX 2); Elemental Affinity (fire) rider. |
| Showcase Warlock | Warlock 5, the Fiend | Pact Magic 2 × 3rd level (separate panel); Pact of the Blade; invocations Devil's Sight (darkvision 120), Eldritch Smite (*Spend a slot…* from the Pact pool), Thirsting Blade (2 attacks with the pact weapon, reminder); Fiend expanded spells on the Warlock list. |
| Showcase Wizard | Wizard 6, School of Evocation | Spellbook summary (free spells by level); Arcane Recovery (3 slot levels) dialog; Sculpt Spells / Potent Cantrip reminders. |
| Showcase Artificer | Artificer 6, Alchemist | Infused items 3 / 3: Enhanced Weapon on the mace (+1, applied while equipped), Enhanced Defense on the scale mail (+1 AC), Homunculus Servant (companion, 1 + INT 4 + level 6 = 11 HP; INT 18 after the ASI). Experimental Elixir 2; Alchemist spells always prepared. Attunement limit 3 (4 from level 10). |

### Backgrounds of the showcase characters

The seeder adds a background only when the character has none (never overwritten). The 2024 versions use "My stored
ability scores already include this background bonus", because the showcase scores above are the final values. Untick it in
the Background card to see the increases added on top.

| Character | Background | What to look at |
|---|---|---|
| Showcase Barbarian | Folk Hero (legacy, PHB) | Rustic Hospitality feature, smith's tools and land vehicles, characteristics with Roll |
| Showcase Bard | Entertainer (2024) | Musician origin feat reference, lute, compatibility mode |
| Showcase Cleric | Acolyte (2024) | Magic Initiate (Cleric) reference, calligrapher's supplies |
| Showcase Druid | Hermit (2024) | Healer feat reference, herbalism kit |
| Showcase Fighter | Soldier (2024) | duplicate Athletics (also Fighter), Replace a duplicate…; dice set |
| Showcase Monk | Wayfarer (2024) | +1 to three abilities; the equipment review asks for "any gaming set" |
| Showcase Paladin | Noble (2024) | dragonchess set, History / Persuasion |
| Showcase Ranger | Outlander (legacy) | Wanderer feature, flute, Sylvan |
| Showcase Rogue | Criminal (2024) | Stealth / thieves' tools duplicates with the class |
| Showcase Sorcerer | Far Traveler (legacy, SCAG, Forgotten Realms) | All Eyes on You, lute, Draconic |
| Showcase Warlock | Haunted One (legacy, VRGR and CoS) | two exotic languages, Heart of Darkness |
| Showcase Wizard | Sage (2024) | Magic Initiate (Wizard) reference |
| Showcase Artificer | Artisan (2024) | Crafter reference, smith's tools (also Artificer) |

## Checks per class

- Class page: no unfinished choice except where the table says so; Next actions empty; At a glance shows the class's
  combat facts (attacks, riders, DCs, quick resources, states).
- Level change review (Bio tab, level select): shows what changes before anything is stored.
- Rests: a short rest restores short-rest resources and ends Rage; Wild Shape keeps its form (it lasts hours).
- Export JSON / import: classes, choices, resources and spells survive (Bio tab, Backup & sharing).
