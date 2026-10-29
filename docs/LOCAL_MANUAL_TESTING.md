# Manual testing on your computer

A checklist for testing Tavern Ledger locally. Everything here runs only on this computer: the local Supabase in Docker
and the app on `http://127.0.0.1:5173/`. Nothing you do here touches the hosted site or its data.

Expected values for every demo character are in [LOCAL_TEST_CHARACTERS.md](LOCAL_TEST_CHARACTERS.md).

> **Sections since the redesign of 2026-10-22** (`docs/UI_MIGRATION_NOTES.md`): Combat → **Play**, Stats → **Abilities**,
> Features → **Build**, Resources → Play (Ready to use) and Build (resource details), Notes → **Bio**. Classes, lineage,
> background and the reminders (pending choices) moved from Bio to **Build**. On a phone the six sections are the bar at the
> bottom of the screen. The checklist below uses the new names; section 15 checks the redesign itself.

How to use the checklist: for each line tick **PASSED** or **FAILED** and write a note if something looks wrong.

```
[ ] PASSED  [ ] FAILED   Notes: ____________________
```

---

## 1. Startup

1. Start **Docker Desktop** and wait for "Engine running".
2. Double-click **`start-local.bat`** (or run `.\scripts\start-local.ps1` in PowerShell in the project folder).
3. Wait for "Tavern Ledger is running LOCALLY", then open **http://127.0.0.1:5173/**.
4. If the demo characters are missing (`.\scripts\status-local.ps1` shows "demo characters 0 of 9"), run
   `.\scripts\seed-local-demo.ps1` once.

- [ ] PASSED [ ] FAILED: start-local finishes with "migrations: 19 of 19" and a complete reference catalog. Notes:
- [ ] PASSED [ ] FAILED: the app opens at http://127.0.0.1:5173/. Notes:
- [ ] PASSED [ ] FAILED: Supabase Studio opens at http://127.0.0.1:54323 (database browser, only when you need it). Notes:

## 2. Login

Local-only synthetic accounts:
- `local-player@example.test` / `local-dev-password` (owns the nine demo characters)
- `local-dm@example.test` / `local-dev-password` (DM of "Local Demo Campaign")

Creating a new account: type any email (for example `me@example.test`) and a password of 6 or more characters, then click
**Create account**. Sign-in links and confirmation emails do not go out; they land in **Mailpit** at http://127.0.0.1:54324.

If login fails: run `.\scripts\status-local.ps1`. If the accounts are missing, run `.\scripts\seed-local-demo.ps1`.
After a `reset-local`, sign out in the browser (the old session no longer exists).

- [ ] PASSED [ ] FAILED: player login shows 9 demo characters. Notes:
- [ ] PASSED [ ] FAILED: DM login shows the same characters (read through the campaign). Notes:
- [ ] PASSED [ ] FAILED: a new local account can be created and sees no characters. Notes:

## 3. Inventory (Local Hero → Inventory tab)

- [ ] PASSED [ ] FAILED: **+ Add item**: search "rope", filter by kind / category / rarity, add 2. Notes:
- [ ] PASSED [ ] FAILED: − / + on Arrows changes the count; − on the last piece asks first. Notes:
- [ ] PASSED [ ] FAILED: equip and unequip (Leather instead of Chain Mail; Mace in the main hand). Notes:
- [ ] PASSED [ ] FAILED: move an item into the Backpack and back out. Notes:
- [ ] PASSED [ ] FAILED: use a Potion of Healing: the count goes 2 → 1 and the healing dice are shown (HP not changed automatically). Notes:
- [ ] PASSED [ ] FAILED: create a **private homebrew** item (only you see it). Notes:
- [ ] PASSED [ ] FAILED: as the DM, create a **campaign homebrew** item; the player can add it. Notes:
- [ ] PASSED [ ] FAILED: custom name and notes on an inventory item (the catalog item stays unchanged). Notes:
- [ ] PASSED [ ] FAILED: archive a homebrew item (hidden from search, still on characters that have it). Notes:
- [ ] PASSED [ ] FAILED: the legacy item "Old Lucky Coin" is shown with a dashed border; it can be linked or converted. Notes:

## 4. Armor and derived stats (Local Hero, Local Sidekick, Local Paladin)

- [ ] PASSED [ ] FAILED: no armor: AC = 10 + DEX (Local Hero 11, 13 with a shield). Notes:
- [ ] PASSED [ ] FAILED: light armor: Leather 11 + DEX. Notes:
- [ ] PASSED [ ] FAILED: medium armor: Scale Mail 14 + DEX, at most +2. Notes:
- [ ] PASSED [ ] FAILED: heavy armor: Chain Mail 16, DEX not added. Notes:
- [ ] PASSED [ ] FAILED: shield +2. Notes:
- [ ] PASSED [ ] FAILED: Strength requirement: Local Sidekick (STR 8) in Chain Mail has speed 20 and a warning. Notes:
- [ ] PASSED [ ] FAILED: Stealth disadvantage is noted for Chain Mail / Scale Mail. Notes:
- [ ] PASSED [ ] FAILED: missing proficiency: Local Sidekick shows the armor and weapon warnings; Longsword −1. Notes:
- [ ] PASSED [ ] FAILED: magic AC item: Ring of Protection +1 only while attuned. Notes:
- [ ] PASSED [ ] FAILED: tap the AC value: the breakdown lists every part; closing it returns to the AC button. Notes:

## 5. Lineages (Build tab)

- [ ] PASSED [ ] FAILED: Local Hero shows Mountain Dwarf; speed 25, darkvision, STR / CON +2. Notes:
- [ ] PASSED [ ] FAILED: change the lineage (e.g. to Elf, High Elf); values update everywhere. Notes:
- [ ] PASSED [ ] FAILED: remove the lineage; the stored ability scores were never changed. Notes:
- [ ] PASSED [ ] FAILED: Local Sidekick (Custom Lineage) shows 4 open choices; completing them clears the warning. Notes:
- [ ] PASSED [ ] FAILED: "ability bonuses already included" prevents double counting. Notes:
- [ ] PASSED [ ] FAILED: lineage spells (Local Spellcaster: Hellish Rebuke, Darkness) appear in the Spellbook. Notes:
- [ ] PASSED [ ] FAILED: export and import a character with a lineage (see section 10). Notes:

## 6. Spell catalog (any character → Spells → + Add spell)

- [ ] PASSED [ ] FAILED: search by name. Notes:
- [ ] PASSED [ ] FAILED: filter by school, level, ritual, concentration, damage type. Notes:
- [ ] PASSED [ ] FAILED: filter by class list (e.g. Artificer: Fireball is not on it). Notes:
- [ ] PASSED [ ] FAILED: spell details: components, source book and link, version (current / legacy / playtest). Notes:

## 7. Spellbook (Local Spellcaster → Spells)

- [ ] PASSED [ ] FAILED: add a spell to a source (known / prepared / always prepared). Notes:
- [ ] PASSED [ ] FAILED: Bless shows "Always prepared" (manual source). Notes:
- [ ] PASSED [ ] FAILED: source badges on every card (Class, Manual, Magic item, Lineage). Notes:
- [ ] PASSED [ ] FAILED: Thaumaturgy is one card with two sources. Notes:
- [ ] PASSED [ ] FAILED: Save DC / attack per source: Artificer 14 / +6, Manual 13 / +5, Tiefling 14 / +6. Notes:
- [ ] PASSED [ ] FAILED: the Wand source uses the fixed DC 15 (Fireball card). Notes:
- [ ] PASSED [ ] FAILED: Alarm (prepared ritual) shows the R marker. Notes:

## 8. Classes and spell slots

- [ ] PASSED [ ] FAILED: Bio → Classes → **+ Add class** on a new character; choose a version and a level. Notes:
- [ ] PASSED [ ] FAILED: total level and proficiency bonus follow the class levels; the Level field becomes read-only. Notes:
- [ ] PASSED [ ] FAILED: change a class level; the slots on Spells change with it. Notes:
- [ ] PASSED [ ] FAILED: Local Wizard: 4 / 3 / 2 slots; Use and Restore change the circles and the "x / y remaining" text. Notes:
- [ ] PASSED [ ] FAILED: Local Artificer has two 1st-level slots at level 1. Notes:
- [ ] PASSED [ ] FAILED: Local Paladin has no slots at level 1 and two at level 2. Notes:
- [ ] PASSED [ ] FAILED: Local Warlock: Pact Magic panel "Slot level: 3rd", 2 slots, separate from standard slots. Notes:
- [ ] PASSED [ ] FAILED: Local Multiclass: caster level 5 (4 / 3 / 2) plus a separate Pact pool (2 × 1st). Notes:
- [ ] PASSED [ ] FAILED: Local Multiclass: Fireball is refused for the Wizard source (Wizard 3 = up to 2nd level). Notes:
- [ ] PASSED [ ] FAILED: limits on each class source (cantrips / known / prepared); preparing beyond the limit is refused. Notes:
- [ ] PASSED [ ] FAILED: lowering a level keeps spells and shows "review" warnings. Notes:
- [ ] PASSED [ ] FAILED: Level Up (header) asks which class gains the level. Notes:

## 9. Rests (Local Warlock, Local Wizard, Local Multiclass)

- [ ] PASSED [ ] FAILED: the rest dialog lists what will be restored before you confirm. Notes:
- [ ] PASSED [ ] FAILED: Short Rest: Pact slots and short-rest trackers come back; standard slots stay used. Notes:
- [ ] PASSED [ ] FAILED: Long Rest: standard and Pact slots, all trackers, HP and hit dice come back; the temporary slot ends. Notes:

## 10. Export and import

- [ ] PASSED [ ] FAILED: Bio → **⬇ Download JSON** on Local Spellcaster (or Local Multiclass). Notes:
- [ ] PASSED [ ] FAILED: character list → **⬆ Import JSON** → the new character has the same inventory. Notes:
- [ ] PASSED [ ] FAILED: same lineage and choices. Notes:
- [ ] PASSED [ ] FAILED: same spells and sources (a spell the class can no longer take becomes a free-text spell, not lost). Notes:
- [ ] PASSED [ ] FAILED: same classes and levels. Notes:
- [ ] PASSED [ ] FAILED: same used slots. Notes:
- Warnings seen during import: ____________________

## 10b. Class features, choices and resources (Local Feature Tester; synthetic test class)

- [ ] PASSED [ ] FAILED: Build tab shows the class feature cards with status and automation badges; "Test fixture" label. Notes:
- [ ] PASSED [ ] FAILED: "1 class choice to make" (ASI); choose +2 STR → Stats shows STR 16; clear it again. Notes:
- [ ] PASSED [ ] FAILED: Optional Lore can be switched on and off (Elvish appears / disappears on Bio languages). Notes:
- [ ] PASSED [ ] FAILED: Keen Senses shows "Replaced" by Swift Reflexes; switching Swift Reflexes off restores Keen Senses (initiative +3 instead of +5). Notes:
- [ ] PASSED [ ] FAILED: Discipline → Body: the Element choice shows "Kept, inactive" and the fire resistance disappears; back to Elements restores it. Notes:
- [ ] PASSED [ ] FAILED: a skill choice with only one skill ticked is refused with a clear message. Notes:
- [ ] PASSED [ ] FAILED: "Forbidden Technique" warning disappears after ticking "My DM allows this" and saving. Notes:
- [ ] PASSED [ ] FAILED: Play → Ready to use (quick) and Build → Class features → "Resources: limits, dice and recovery": Use / Restore change the count; Use is disabled at 0. Notes:
- [ ] PASSED [ ] FAILED: Short Rest restores Surge and 1 Focus point, not Reserve; Long Rest restores all. Notes:
- [ ] PASSED [ ] FAILED: Combat shows Spirit Strike (+5, 1d8 + 2), "2 attacks", "critical 19–20"; Shortbow +7. Notes:
- [ ] PASSED [ ] FAILED: Spells: Detect Magic and Shield always prepared from "Engine Test Class features". Notes:
- [ ] PASSED [ ] FAILED: Bio level 5 → 2 shows the review (features deactivated, subclass kept but inactive); Cancel keeps 5; confirming keeps all choices as inactive. Notes:
- [ ] PASSED [ ] FAILED: Features → "Next level preview" lists Advanced Technique and Focus 5 → 6. Notes:
- [ ] PASSED [ ] FAILED: Export + import keeps choices, the replacement and resource usage. Notes:

## 10c. Wild Shape (Druid fixtures; docs/WILD_SHAPE_UI.md)

1. **Wild Shape Druid 2 → Combat:** the idle panel shows the limits. Choose a form…: only seen forms are usable. Under
   "All forms" the Giant Eagle is locked with its reasons. Mark the Boar seen: it becomes usable.
2. **Transform:**
   - Transform into the Wolf: the review shows cost, duration and equipment.
   - Confirm: the full form sheet appears, the header HP note shows, and the speed reads "Form: ...".
3. **Form HP:**
   - Damage 5: form HP drops and normal HP is unchanged.
   - Heal 2.
   - Adjust… (a reason is required).
   - Damage past 0: confirm the carry-over; the form ends and normal HP drops by the excess, once.
4. **Wild Shape Moon 2:**
   - Combat Wild Shape: choose a 1st-level slot and enter your roll 5. The form heals and the slot is spent.
   - Revert: no use is spent.
5. **Wild Shape Moon 6:** Web, then Use, Roll recharge (d6), Restore.
6. **Wild Shape Moon 10:** Earth Elemental, 0 / 2 uses. The picker has the Elemental group.
7. **Two windows on one character:** a change in one appears in the other (Realtime).
8. **Phone width (390 px):** search is visible, the filters are folded, and nothing scrolls sideways.

## 11. Persistence

1. Make a visible change (e.g. use a 2nd-level slot of Local Wizard, or write a note).
2. Double-click `stop-local.bat`, then `start-local.bat`.
3. Reload the app (sign in again if asked).

- [ ] PASSED [ ] FAILED: the change is still there. Notes:

To return the demo characters to their documented state afterwards: `.\scripts\seed-local-demo.ps1 -Repair`.

## 12. Reset (only when needed)

`reset-local.bat` (or `.\scripts\reset-local.ps1`) **deletes all local accounts and characters** and rebuilds the local
database from the migrations and seeds. It asks you to type `RESET`. Use it only when the local database is broken or
very old. It never touches the hosted Supabase project.
Afterwards: sign out in the browser, run `.\scripts\seed-local-demo.ps1`.

## Checking that traffic is local

Open the browser's developer tools → Network. Requests go to `127.0.0.1:5173` (the app) and `127.0.0.1:54321` (local
Supabase), and nothing else: fonts and the supabase-js library are self-hosted (V6 hardening). Nothing goes to
`*.supabase.co`, a CDN or Google Fonts.

<!-- 20261019 governance/feats/content -->
## 13. Campaign governance, approvals and the DM Space (docs/DM_SPACE.md)

Use two browsers (or a private window): the player `local-player@example.test` and the DM `local-dm@example.test`.

1. Player → **Standard Fighter**: change STR or take a level → the change is refused and "Ask your DM" opens; send it.
2. DM → DM Space → Approvals: open it, read the diff, return it with a note. Player: the note appears; revise and resend.
3. DM approves → the change appears on the sheet live; Audit log lists it.
4. DM changes the fighter's max HP, then opens an older pending request → it is marked stale; refresh it before approving.
5. Player → Features → + Add feat: filter, "Eligible only", badges; a playtest feat is refused in a Standard campaign.
6. Take Tough (approved) → the HP card shows "base + N from Tough"; heal fills to that maximum.
7. DM → Content: create a spell, validate (fix the message), preview, publish; Assign it to a character; it appears in the
   spellbook with the Campaign custom badge. New version, archive, restore.
8. DM → Assign the Ring of the Ashen Oath unidentified → the player sees only "Heavy iron ring"; identify it → true name,
   curse stays hidden.
9. DM → Party: lock **Strict Wizard** (progression) → the player sees the lock message; HP still works.
10. Player inventory: no "Create homebrew item" button (Ask your DM).
11. Phone width (≈ 390 px): DM Space sections become a select; no horizontal scrolling.

## 15. Player-first redesign (2026-10-22)

Compare with `docs/UI_DESIGN_SYSTEM.md`. Use a desktop window and a phone-sized window (DevTools device toolbar, 390 px).

- [ ] PASSED [ ] FAILED: Home: "My characters" grouped by campaign; every card shows a class emblem, "Class level · Lineage", HP and AC; Showcase Druid shows "Wild Shape: Brown Bear", Strict Wizard "Locked". Notes:
- [ ] PASSED [ ] FAILED: Home: the search box ("Find a character…") filters the cards as you type. Notes:
- [ ] PASSED [ ] FAILED: Text, buttons and numbers use a plain modern face (Inter); only the logo, page titles and the character name use the book serif (Alegreya). No all-caps labels. Notes:
- [ ] PASSED [ ] FAILED: Sheet header: name, "Paladin 6 (Devotion) · Human", chips (campaign, Requests, Wild Shape, choices to make); Short rest / Long rest. Notes:
- [ ] PASSED [ ] FAILED: Six sections Play · Abilities · Spells · Inventory · Build · Bio with icons; arrow keys move between them. Notes:
- [ ] PASSED [ ] FAILED: Scroll down a long section: the top bar shows the name, HP and AC; tapping it scrolls back up. Notes:
- [ ] PASSED [ ] FAILED: Play (Showcase Barbarian): Ready to use with Rage (Start / End), Attacks with the greataxe, Bonus actions list Rage. Notes:
- [ ] PASSED [ ] FAILED: Play (Showcase Paladin): Divine Smite "Spend a slot…" next to the attacks; Lay on Hands Spend in Ready to use. Notes:
- [ ] PASSED [ ] FAILED: Spells: each card starts with the school icon, then a readiness chip (Prepared / Always prepared / Not prepared); Necromancy is green, Fire orange. Notes:
- [ ] PASSED [ ] FAILED: Inventory: "Equipped" lists the filled slots; "Empty slots" is folded; items have category icons. Notes:
- [ ] PASSED [ ] FAILED: Build: Next steps on top with "Level up"; Strict Wizard shows a disabled Level up with "Your DM has paused progression…". Notes:
- [ ] PASSED [ ] FAILED: Wild Shape (Showcase Druid): the HP card shows "Wild Shape · Brown Bear 34 / 34" first and the normal HP as protected. Notes:
- [ ] PASSED [ ] FAILED: Phone (390 px): the sections are a bottom bar; nothing scrolls sideways; dialogs (Add a spell, Choose a feat) show the search and results first, filters folded under "Filters". Notes:
- [ ] PASSED [ ] FAILED: DM (local-dm): DM Space → Overview starts with "Needs you"; zero counters are dimmed; DM-only events carry a "DM only" chip. Notes:

## 16. UI refinement (2026-10-22)

- [ ] PASSED [ ] FAILED: Abilities: before reading the labels you can see five groups: Ability scores, Saving throws, Skills, Senses and movement (+ Hit dice), Proficiencies. Notes:
- [ ] PASSED [ ] FAILED: Sections are lighter than the page, cards are lighter than their section, details are darker insets; sections are further apart than cards. Notes:
- [ ] PASSED [ ] FAILED: Inventory (Showcase Paladin): Equipped and Items you carry are separate sections; empty slots are folded. Notes:
- [ ] PASSED [ ] FAILED: Build: Next steps is highlighted only when something is open; Classes, Class features, Lineage, Background and Feats have clear boundaries. Notes:
- [ ] PASSED [ ] FAILED: Spells (Local Wizard): Fire Bolt and Fireball show the fire icon, Magic Missile force, Shield abjuration, Light the evocation school icon; the school badge stays on every card. Notes:
- [ ] PASSED [ ] FAILED: + Add spell → Status Any → search "Ice Storm" (several types icon, "Bludgeoning + Cold") and "Chromatic Orb" (choose icon, "Choose one: …"); "Cure Wounds" shows the evocation school icon. Notes:
- [ ] PASSED [ ] FAILED: New character: no Race field; choose Elf → High Elf, a class, then the review lists lineage, sub-lineage, class, speed and senses and the open choices. Notes:
- [ ] PASSED [ ] FAILED: Showcase Paladin → Build → Lineage: "Legacy race has not been mapped to a Lineage", suggestion Human, the text kept under "Legacy race text". Notes:
- [ ] PASSED [ ] FAILED: Export a new character (Bio): the file has `lineage.version`, `lineage.subversion` and no `race`. Notes:
- [ ] PASSED [ ] FAILED: Phone (390 px): the same checks; sections keep visible edges; the new-character dialog keeps its buttons visible. Notes:

## 17. Vitals, six abilities, Skills and typography (2026-10-22, v5)

1. Open a character at desktop width. The vitals show HP largest, then AC (shield), Initiative, Speed and Proficiency.
   Conditions and up to six quick resources sit below.
2. Enter 5 and press Damage, then Heal. A short message confirms each. Pressing again with an empty field asks for an
   amount. Healing stops at the maximum including feats (e.g. Tough).
3. Press "Less" under the panel. One line remains: HP, Temp (if any), AC, Init, Speed, PB, conditions and Wild Shape.
   Switch tabs and reload; the panel stays collapsed. Press "More" to expand.
4. On a phone width (390 px) with no saved choice, the panel starts collapsed.
5. Abilities: STR DEX CON INT WIS CHA in one row. Narrow the window; the row scrolls sideways inside itself and the page
   does not. Tab through the six score fields.
6. Skills: six blocks (Constitution says it has no skills), with name, modifier and score on the left.
7. A druid in Wild Shape: form HP first in the vitals. STR, DEX and CON say "From form" and show the form scores; INT, WIS
   and CHA say "Retained from character".
8. Typography: the logo, character name, section titles and big numbers are Cinzel. Labels, buttons, inputs and text are
   Inter. The base maximum HP is edited on Build → Classes.

## 18. Original visual language (2026-10-22, v6)

1. Every major section title (Play, Abilities, Inventory, Build, DM Space) is gold Cinzel. "Notes", "Reminders" and
   dialog titles are plain white Inter.
2. Vitals: press "Less". The HP value with its bar, the AC shield and the Initiative, Speed and Proficiency cards remain,
   just smaller. Temp HP shows as "+N temp". Press "More".
3. Abilities:
   - four summary tiles: Proficiency, Passive Perception, Passive Insight, Inspiration;
   - the legend;
   - six cards: Strength, Dexterity, Constitution / Intelligence, Wisdom, Charisma;
   - each card has its saving throw (diamond) and its skills;
   - tap a skill mark granted by your class: the grant stays.
4. Proficiencies: granted tiles are gold; tapping one explains its source.
5. Inventory: four metric cards. Coins → Edit focuses the GP field; changing it updates the card.
6. Phone (390 px): one ability card per row, inventory cards 2 × 2, no sideways scrolling.

## 19. V6 product hardening (2026-10-22)

Quick checks of this pass (details: docs/V6_PRODUCT_HARDENING_REVIEW.md):

1. **Home:** the cards show "…" for maximum HP and AC until the real values load, never a stored "10". Every card is
   filled after about 1.5 s.
2. **Vitals:**
   - type 120 into current HP: it stops at the maximum;
   - damage to 0 shows "Down" and the death saves; heal 1 shows "Critical".
3. **Phone:** the collapse handle, the AC shield and the skill marks are easy to tap (≥ 24 px).
4. **A refused save** (a value the server rejects for validation or permission reasons; DM locks use the separate "Ask your
   DM" path): a toast says "Not saved: …" in plain words and the field shows the stored value again. Nothing retries in the
   background. The automated check is Z7 in the hardening suite.
5. **Network** (developer tools → Network): only `127.0.0.1` requests; supabase-js comes from `vendor/supabase-js/`.
6. **A build-locked character:** level up is disabled with "Your DM has locked the build …"; damage and healing still work.
7. **DM Space on a 360 px phone:** Campaign rules does not scroll sideways.

Test data cleanup: the browser suites use synthetic `ui-*@example.test` users (cleaned by `run_browser_local.sh`). The
local smoke test signs up `local-smoke-*@example.test`; remove it afterwards:

```
docker exec supabase_db_tavern_ledger psql -U postgres -c "delete from public.characters where owner_id in (select id from auth.users where email like 'local-smoke-%'); delete from public.items where owner_id in (select id from auth.users where email like 'local-smoke-%'); delete from auth.users where email like 'local-smoke-%';"
```


## 20. V6.2 adversarial hardening (2026-10-23)

Quick checks of this pass (details: docs/V62_ADVERSARIAL_HARDENING_REVIEW.md):

1. **Unidentified item (DM → player):**
   - As `local-dm`, assign a published custom item with "identified" off.
   - DM Space → History shows two lines: "Assigned item: &lt;disguise&gt;" (party) and "Assigned item (unidentified):
     &lt;true name&gt;" (DM only).
   - The player app has no audit screen. The leak was reachable through the API (for example from the browser's developer
     tools), so the player side is checked by SEC1–SEC7 in `v62_adversarial_api_test.py`. That includes the existing
     "Ring of the Ashen Oath" event in Local Standard Table.
2. **A wrong link:** open `#/c/00000000-0000-0000-0000-000000000000`. You get "This character could not be loaded …" with
   **Back to your characters**. There is no database text, and nothing of the sheet you had open before.
3. **Offline:** developer tools → Network → Offline, then change the character name. The status says "Offline — will
   sync". Go back online: it saves.
4. **Import a broken file** (any `.txt` renamed to `.json`): the preview says "That file is not valid JSON." and Import stays
   disabled.
5. **Reconnect:** with a sheet open, sleep the laptop (or stop the Wi-Fi) while someone else changes HP, then wake it. A
   toast says "Connection restored — showing the latest values." and the new HP is shown.
6. **DM content:** a feat effect with an unknown type, or a spell with an unknown damage type, is refused at Publish with a
   sentence, not a constraint name. A lineage without a short summary publishes.

Test data: the V6.2 suites run inside the isolation harness (docs/V62_TEST_ISOLATION.md). After a run, check:

```
cd supabase/tests/browser && python -c "import isolation; print(isolation.residue())"   # expect {}
```

## Production incident fix (2026-10-29): slow networks and quick switching

Developer tools → Network → throttling "Fast 4G" (or a custom 150 ms latency profile).

1. **Quick switching:** open character A, then B, then C within a second (Home cards or browser back/forward). C is shown,
   never A or B; in the Network tab the earlier characters' requests show as *(canceled)*; no error toast.
2. **HP without reloads:** change HP. The Network tab shows one `characters` PATCH and no `get_character_derived_stats`.
   Change an ability score: the derived stats are read again.
3. **Background picker:** Build → Choose background…. The dialog opens at once with "Loading backgrounds…", then the list.
   With Network → Offline before clicking: a sentence and a **Retry** button (no endless spinner); go online, Retry.
4. **Spells:** the spellbook loads when you open the Spells section (one `get_character_spellbook` request then).
5. **Reconnect:** stop the Wi-Fi for a few seconds twice in a row, then reconnect: one "Connection restored" toast, one reload.

Automated: `supabase/tests/browser/production_timeout_incident_test.py` (57 checks, 150 ms latency); diagnostic numbers:
`LATENCY_MS=150 OUT=probe.json python supabase/tests/browser/incident_probe.py`.
