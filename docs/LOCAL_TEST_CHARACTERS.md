# Local demo characters

Nine synthetic characters for manual testing, created by `.\scripts\seed-local-demo.ps1`. **Local only.**

- **Player account:** `local-player@example.test` (owns all nine)
- **DM account:** `local-dm@example.test` (DM of "Local Demo Campaign", sees all nine)
- **Password for both:** `local-dev-password`

These are synthetic accounts that exist only in the Supabase database on this computer.

The values below are what the app should show right after the seeder created (or `-Repair` reset) the characters. If you
changed a character and want the demo state back, run `.\scripts\seed-local-demo.ps1 -Repair`. Repair resets only these
nine characters, never characters you created yourself.

Abbreviations: PB = proficiency bonus, DC = Spell Save DC, ATK = Spell Attack Bonus.

---

## Local Hero: inventory, armor and AC

- **Class / level:** Fighter 3 (class row, so the level is read-only on Bio). PB +2.
- **Lineage:** Dwarf, Mountain Dwarf (all choices made). STR 17 (15 + 2), CON 16 (14 + 2), DEX 12. Speed 25 ft, darkvision 60 ft.
- **Proficiencies:** all armor, shields, simple and martial weapons.
- **Equipped:** Chain Mail (armor), Shield, Longsword (main hand).
- **Also carried:** Leather (light), Scale Mail (medium), Mace (simple), Shortbow, 20 Arrows, 2 Potions of Healing, Ring of
  Protection (not attuned), Backpack, legacy item "Old Lucky Coin", private homebrew "Local Moonblade".
- **Expected:** AC **18** (Chain Mail 16 + Shield 2; DEX not added); note: Stealth disadvantage (Chain Mail). Longsword
  **+5**, 1d8 + 3 slashing.
- **Try:**
  - Swap to Leather: AC 11 + DEX 1 = 12, plus Shield 14.
  - Swap to Scale Mail: AC 14 + DEX (max 2) = 15, plus Shield 17; Stealth disadvantage.
  - Equip and attune the Ring of Protection: +1 AC only while attuned.
  - Use a Potion of Healing: the count drops; HP is not changed automatically.
  - Move items into the Backpack.
  - Link or convert the legacy coin.
- **Rests:** no spell slots. Long rest restores HP and hit dice as before.

## Local Sidekick: warnings and an unfinished lineage

- **Class / level:** Rogue 3. PB +2. STR 8, DEX 16.
- **Lineage:** Custom Lineage with only the size chosen, so **4 open choices** show on Bio.
- **Proficiencies:** light armor and simple weapons only.
- **Equipped:** Chain Mail and Longsword, both deliberately wrong. Also carried: Leather, 2 Daggers.
- **Expected:**
  - AC **16** (Chain Mail, DEX not added).
  - Warnings: not proficient with the armor, Strength 13 required (speed **20** instead of 30), Stealth disadvantage,
    spellcasting restricted while wearing armor without proficiency.
  - Longsword **−1**, 1d8 − 1 (martial weapon without proficiency: no PB).
- **Try:** equip Leather instead (warnings disappear, AC 11 + 3 = 14); complete the Custom Lineage choices (ability
  increase, skill, feat or darkvision) and check that ability scores are not counted twice.

## Local Spellcaster: spellbook, sources and DCs

- **Class / level:** Artificer 5 (`artificer-tce`). PB +3.
- **Lineage:** Tiefling (Bloodline of Asmodeus): INT 17, CHA 16. Darkvision.
- **Sources and stats:**
  - **Artificer** (class, INT): DC **14**, ATK **+6**.
  - **Manual Spellcasting Source** (WIS, may mark always prepared): DC **13**, ATK **+5**.
  - **Wand of Fireballs (demo)** (item): fixed DC **15**, no attack.
  - **Tiefling (lineage, CHA):** DC **14**, ATK **+6**.
- **Spells:**
  - Fire Bolt (cantrip, damage)
  - Alarm (ritual, prepared: shows the **R** marker)
  - Cure Wounds (healing, prepared)
  - Faerie Fire (concentration, prepared)
  - Bless (manual, **always prepared**, concentration)
  - Thaumaturgy: **one card, two sources** (lineage and manual)
  - Hellish Rebuke and Darkness (lineage, innate)
  - Fireball (wand, DC 15)
- **Artificer limits:** cantrips 1 / 2, prepared **3 / 5** (INT 3 + half of 5).
- **Slots:** Artificer 5 has 1st × 4 and 2nd × 2.
- **Try:**
  - Filter the spellbook by source, ritual or concentration.
  - Add a spell from the Artificer list.
  - Try to add a 3rd-level spell to the Artificer source: it is refused, because Artificer 5 tops out at 2nd level.
  - Export and import the character.

## Local Wizard: standard spell slots

- **Class / level:** Wizard 5 (`wizard-phb`). PB +3. INT 16.
- **Stats:** DC **14**, ATK **+6**.
- **Slots:** 1st **3 / 4** (one used), 2nd 3 / 3, 3rd 2 / 2.
- **Spells:**
  - Cantrips: Fire Bolt, Mage Hand, Light.
  - Prepared: Magic Missile, Shield, Misty Step, Fireball.
  - Known, not prepared: Detect Magic (ritual from the spellbook, **R**).
- **Limits:** cantrips 3 / 4, prepared **4 / 8** (INT 3 + 5).
- **Expected:** Cone of Cold (5th level) is refused for the Wizard source ("can choose spells up to level 3").
- **Try:**
  - Use and Restore a slot.
  - Take a Long Rest: 1st level is back to 4 / 4.
  - Change the Wizard level on Bio to 3: slots become 4 / 2, and Fireball stays but is flagged "above your Wizard spell
    level". Set it back to 5.
  - Prepare more spells than the limit allows: refused at 8.

## Local Artificer: Artificer level 1

- **Class / level:** Artificer 1. PB +2. INT 16.
- **Stats:** DC **13**, ATK **+5**.
- **Slots:** **1st × 2 at level 1.** Paladin and Ranger have no slots at level 1.
- **Spells:**
  - Cantrips: Guidance, Mending (2 / 2).
  - Prepared: Cure Wounds, Sanctuary (2 / **3**; INT 3 + half of 1 rounded down = 3).
- **Try:** filter the Add Spell list by "Artificer spell list"; Fireball is not on it.

## Local Paladin: half caster, level 1 → 2

- **Class / level:** Paladin 1. PB +2. STR 16, CHA 16.
- **Equipped:** Chain Mail, Shield, Longsword.
- **Expected:**
  - **No spell slots** at level 1; the Paladin source says spellcasting starts at level 2.
  - AC **18**, Stealth disadvantage; Longsword +5.
- **Try:**
  - Set the Paladin level to 2 on Bio: 1st-level slots × 2 appear, prepared limit 3 + 1 = **4**, Bless can be added.
    Paladin has no cantrips.
  - Set the level back to 1: added spells stay but are flagged.

## Local Warlock: Pact Magic and rests

- **Class / level:** Warlock 5. PB +3. CHA 16.
- **Stats:** DC **14**, ATK **+6**.
- **Pact Magic:** **2 slots of 3rd level, 1 / 2 remaining.** No standard slots.
- **Spells (known):**
  - Cantrips: Eldritch Blast, Mage Hand, Prestidigitation.
  - Leveled: Hex, Armor of Agathys, Misty Step, Hunger of Hadar, Counterspell.
  - Counts: known 5 / 6, cantrips 3 / 3, highest spell level 3.
- **Resources tab:** "Short-rest charm (demo)" 0 / 2 (short rest) and "Long-rest charm (demo)" 0 / 1 (long rest).
- **Temporary slot:** "Demo spark (temporary)", 1st level, ends on a long rest.
- **Short Rest:** Pact 2 / 2, short-rest charm 2 / 2. The long-rest charm stays at 0, and the temporary slot stays.
- **Long Rest:** everything restored, the temporary slot disappears, and HP and hit dice are restored as before.

## Local Multiclass: multiclass slots and per-class spell access

- **Class / level:** Wizard 3 / Paladin 4 / Warlock 2 = level **9**, PB **+4**. INT 16, CHA 16, STR 14.
- **Stats:** every class source has DC **15** and ATK **+7** (8 + 4 + 3).
- **Standard slots:**
  - Caster level **5** = Wizard 3 + half of Paladin 4 (2); Warlock does not count.
  - 1st **3 / 4** (one used), 2nd 3 / 3, 3rd 2 / 2.
- **Pact Magic:** separate pool, 2 slots of 1st level, **1 / 2**.
- **Spell access per class:**
  - Wizard: up to **2nd** level, even though the character has 3rd-level slots.
  - Paladin: 1st level, prepared limit 5.
  - Warlock: 1st level, known 1 / 3.
- **Spells:** Fire Bolt, Magic Missile and Shield (prepared), Misty Step (Wizard); Bless (Paladin, prepared); Eldritch
  Blast and Hex (Warlock).
- **Try:** add Fireball to the Wizard source (refused: "a level 3 Wizard can choose spells up to level 2"); use a standard
  slot and a Pact slot; take a Short Rest (Pact back, standard not); take a Long Rest (both back).
- **Note:** a generic resource "Lay on Hands pool (demo resource)" (5 × Paladin level = 20) exists in the database. There is
  no screen for it yet; you can see it in Studio, in the table `character_resources`.

## Local Feature Tester: class feature engine (SYNTHETIC test class)

**Test content, not an official class.** "Engine Test Class" and its "Test Path" subclass come from
`supabase/tests/fixtures/class_feature_engine_fixture.sql` (loaded by `seed-local-demo.ps1`; never part of the seeds).
They are marked "Test fixture" in the app.

- **Class / level:** Engine Test Class 5, subclass Test Path. PB +3. STR 14, DEX 14, CON 12, INT 10, WIS 16, CHA 12.
  Equipped: Shortbow (+ 20 arrows). No armor.
- **Features tab:** about 20 feature cards. Status badges (Active / Not yet / Optional, not selected / Replaced) and
  automation badges (Automated / Partly automated / Informational).
  - **Replacement:** Swift Reflexes is selected and **replaces Keen Senses** (Keen Senses shows "Replaced").
  - **Optional feature not selected:** Optional Lore (button "Use this optional feature" → Elvish).
  - **Incomplete choice:** Ability Score Improvement (level 4) — "1 class choice to make". Options: +2 / +1 +1 / feat
    placeholder / "already in my scores".
  - **Prerequisite warning:** Test Discipline → Two techniques includes "Forbidden Technique" (needs DM permission):
    warning "confirm with your DM" until "My DM allows this" is ticked and saved.
  - **Dependent sub-choice:** Discipline = Elements → Element = Fire (resistance to fire).
  - **Choices made:** skills Athletics + Perception, expertise in both, fighting style Archery, cantrip Light.
  - **Informational feature:** Tactical Note (no Stealth advantage is applied).
  - **Next level preview** (level 6): Advanced Technique (needs the Test Path), Focus points 5 → 6.
- **Expected values:**
  - AC **15** (class formula 10 + DEX 2 + WIS 3, no armor). Initiative **+5** (DEX 2 + PB 3 from Swift Reflexes).
    Speed **35** ft (30 + 5, "class features").
  - Shortbow attack **+7** (DEX 2 + PB 3 + Archery 2). Spirit Strike **+5**, **1d8 + 2** force. Attack action: **2
    attacks**; critical hit on **19–20** (Path Precision).
  - Saving throws WIS and CON proficient (from the class). Athletics **+8** and Perception **+9** (expertise).
    Resistance: fire.
  - Spells: Detect Magic (always prepared, ritual) and Shield (always prepared, subclass), Light (cantrip) — source
    "Engine Test Class features" with WIS: DC **14**, attack **+6**.
- **Resources tab → Class resources:**

  | Resource | State | Recovery |
  |---|---|---|
  | Test Surge | 0 / 1 | short or long rest |
  | Test Inspiration | 1 / 1, die d8 | long rest |
  | Test Burst | 1 / 1 | short rest |
  | Test Focus Pool | 3 / 5 | long rest; 1 back on a short rest |
  | Test Reserve | 2 / 3 (= PB) | long rest |

- **Try:**
  - Short Rest: Surge 1 / 1, Focus 4 / 5; Reserve stays 2 / 3 (listed as not restored). Long Rest: everything full.
  - Bio → level 2: the review lists Extra Attack, Path features and resources deactivated and the subclass "kept but
    inactive"; confirm; the Features tab keeps every choice ("Kept, inactive"); set it back to 5.
  - Choose the ASI (+2 STR → STR 16) or tick "already included".
  - Export the character and import it again: choices, the replacement and resource state come back.

---

## Wild Shape scenarios (Druid fixtures)

These are created by the demo seeder (add-only). Open the **Combat** tab; the expected values come from the server.

| Character | Expect |
|---|---|
| Wild Shape Druid 2 | Idle. 2 / 2 uses, CR 1/4, swimming locked (Druid 4), flying locked (Druid 8). Seen forms **required**: Wolf, Cat and Riding Horse are usable; everything else is locked "not seen yet". Wolf favorite quick button |
| Wild Shape Druid 4 (Land) | Idle. CR 1/2, swimming allowed, flying locked. Crocodile, Reef Shark and Giant Goat are seen; Crocodile is a favorite |
| Wild Shape Druid 8 (Land) | **Giant Eagle** (CR 1, fly 80 ft), 26 / 26 form HP, 1 / 2 uses left, cannot cast |
| Wild Shape Moon 2 | **Brown Bear**, wounded at 19 / 34, normal HP 17 protected. Combat Wild Shape button: heal with a 1st-level slot. STR 19 (Form), Perception +5 (gained) |
| Wild Shape Moon 6 | **Giant Spider**, 26 / 26. Web shows "Recharge 5–6: available", DC 12 STR check, Restrained; Bite DC 11 CON. Attacks are magical (Primal Strike) |
| Wild Shape Moon 10 | **Earth Elemental** (Elemental Wild Shape), 126 / 126, 0 / 2 uses (cost 2). Burrow 30, tremorsense 60, resistances and immunities under Defense |
| Wild Shape Druid 20 (Land) | **Brown Bear**. Wild Shape **Unlimited** (Archdruid). "Can cast in this form" (Beast Spells / Archdruid) |
| Wild Shape Fighter Druid | Idle. "Druid level 4 (character level 7: Wild Shape uses the Druid level)", CR 1/2. Shield and leather equipped; the review offers merge (the default), drop or wear |

**Try:**
- damage the bear past 0 HP (the confirmation shows the carry-over);
- revert (no use spent);
- mark a form seen in the picker;
- compare two forms;
- export and import (the active form comes back as normal form).

---

## What "correct" looks like everywhere

- The level on Bio is read-only for characters with classes; the header shows e.g. "Wizard 3 / Paladin 4 / Warlock 2".
- Pact Magic is always its own panel, never mixed into the standard slot lines.
- A short rest never restores standard slots. A long rest restores both pools.
- Nothing is removed automatically: lowering a level or an ability score only shows warnings.

<!-- 20261019 governance/feats/content -->
## Governance demo campaigns (DM: local-dm@example.test; player: local-player@example.test)

Created by `scripts/local/seed_local_demo.py` only when the campaign does not exist yet (add-only; an existing campaign
is never changed). Character ids are stable (uuid5 of the name).

| Campaign (preset) | Character | What to test |
|---|---|---|
| Local Relaxed Table (relaxed) | Relaxed Ranger (Ranger 4) | everything player-managed; feats Alert (2024) and Observant (2014) side by side (distinct versions) |
| Local Standard Table (standard) | Standard Fighter (Fighter 4) | requests: pending (Tough), approved and applied (Alert), rejected (Lucky), returned (next level), cancelled (Skilled), draft in the tray (Savage Attacker), stale (Observant, the DM corrected max HP after it was sent); custom content: Ember Lance (spell), Ring of the Ashen Oath (unidentified, cursed), Ashwalker (campaign reward feat), Cinder Fox (Wild Shape beast, not granted), a draft spell, an archived item; a secret DM note and a hidden condition |
| Local Strict Table (strict) | Strict Wizard (Wizard 3) | a pending level-up request; progression locked "Between sessions" |
| Local Custom Table (custom on standard) | Custom Cleric (Cleric 4) | overrides: long rest player-managed, feats DM-only (no request offered) |
