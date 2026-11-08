# Active class feature audit (2026-11-07)

Scope: every class feature in the local catalog for the 13 implemented classes (274 unlocks, generated from
`class_feature_unlocks` / `class_feature_versions` / `class_feature_resources` / `class_feature_choices`; the test class
`engine-test` is left out). Presentation rules: `docs/ACTIVE_CLASS_FEATURE_PRESENTATION.md`.

## Classification used

| Class | Meaning | Where it appears |
|---|---|---|
| PASSIVE | always on, nothing to activate | Build; in Play only as a combat reminder when its option says so (`play: reminder`) |
| ACTION / BONUS ACTION / REACTION | structured `activation` on the feature | Play group of that timing, with its uses |
| FREE / SPECIAL | used during play outside the action types (Action Surge, Metamagic, a maneuver when you hit) | Play > Free and special |
| RESOURCE | limited uses (`class_feature_resources`) | Play > Ready to use (counter, Use, rest recovery) |
| CHOICE | a selected option changes what you can do | the option's own timing (`data.activation`, migration `20261107000400`) |
| SPELL-GRANTING | adds spells or free casts | Spells (granted spells; non-automated option casts in "From your class options") |
| ITEM-BOUND | bound to an item (Artificer infusions) | Inventory badge on the item, Play > Infused items, Build card |
| REMINDER | `automation = informational`: not applied by the app | tagged "reminder" in Play; never a fake Use button |

## Findings

| # | Finding | Status |
|---|---|---|
| 1 | Features with a structured timing (Rage, Second Wind, Action Surge, Channel Divinity, Wild Shape, Lay on Hands, Cunning Action, …) were already in Play groups, and their resources in Ready to use. | kept |
| 2 | **Selected options had no timing at all**, so Invocations, Metamagic, Fighting Styles, Battle Master maneuvers, Hunter options, Pact Boon and Fiendish Resilience never appeared in Play (only as chosen values on Build). | **fixed**: targeted catalog patch adds `activation` (+ `play: reminder` for combat passives) to 208 named options of 12 choice features; Play renders them from the already loaded class-feature read |
| 3 | **Artificer infusions** were visible only on the Build card; the item in Inventory showed a raw modifier id ("Infusion-enhanced-weapon-l2"), Play showed nothing. | **fixed**: "Infused: <name>" badge (attunement state in the title), Play > Infused items with the infusion text and target item |
| 4 | An option that is also an attack rider (Eldritch Smite) would appear twice. | **fixed**: options already shown under Attacks are not repeated |
| 5 | Invocations that cast a spell at will (Armor of Shadows, Mask of Many Faces …) are automated grants and already appear in Spells as granted spells. Daily casts that are not automated (Bewitching Whispers, Sign of Ill Omen …) were not listed anywhere outside Build. | **fixed**: Spells > "From your class options" lists only the non-automated ones (no duplicate spell source) |
| 6 | Favored Enemy, Natural Explorer and Dragon Ancestor are permanent choices with no in-combat action. | intentionally Build only (no timing set) |
| 7 | Many passive features are `informational` (reminders). | not shown in Play unless they are options flagged as combat reminders (no clutter) |
| 8 | Separate defect seen, not in scope: deleting a character whose item holds an infusion is refused by the managed-modifier guard unless the flag is set (`inventory_item_modifiers_before_write`). | documented in `V6_KNOWN_LIMITATIONS.md`; the test cleanup sets the flag |

## Version notes

Only the 2014 PHB / TCE / XGE class versions exist locally (and the 2014 Druid Wild Shape). No 2024 class version is in the
catalog; nothing here invents 2024 mechanics. Option timings were taken from each option's own rules text in the catalog.

## Per-feature table

### Artificer (18 features)

| Lvl | Feature | Source / version | Timing | Resource | Choice | Automation | Play | Spells | Inventory | Build | Note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Magical Tinkering | Tasha's Cauldron of Everything · `artificer-tce` | ACTION · REMINDER | — | — | reminder only | Action group | — | — | listed |  |
| 1 | Spellcasting | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 1 | Proficiencies | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE | — | skill,tool | automatic | — (Build only) | — | — | choice |  |
| 2 | Infuse Item | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE · CHOICE, ITEM-BOUND | — | option | partly automatic | Build: Infused items card; Inventory: "Infused: <name>" badge; Play: Infused items section | — | infused item badge | choice |  |
| 3 | Artificer Specialist | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE | — | subclass | automatic | — (Build only) | — | — | choice |  |
| 3 | The Right Tool for the Job | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 4 | Ability Score Improvement | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 6 | Tool Expertise | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 7 | Flash of Genius | Tasha's Cauldron of Everything · `artificer-tce` | REACTION · RESOURCE | Flash of Genius (long_rest) | — | partly automatic | Reaction group | — | — | listed |  |
| 8 | Ability Score Improvement | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 10 | Magic Item Adept | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE | — | — | partly automatic | — (Build only) | — | — | listed |  |
| 11 | Spell-Storing Item | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE · RESOURCE | Spell-Storing Item (long_rest) | — | partly automatic | Ready to use (uses) | — | — | listed |  |
| 12 | Ability Score Improvement | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 14 | Magic Item Savant | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE | — | — | partly automatic | — (Build only) | — | — | listed |  |
| 16 | Ability Score Improvement | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 18 | Magic Item Master | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 19 | Ability Score Improvement | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 20 | Soul of Artifice | Tasha's Cauldron of Everything · `artificer-tce` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |

### Barbarian (22 features)

| Lvl | Feature | Source / version | Timing | Resource | Choice | Automation | Play | Spells | Inventory | Build | Note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Rage | Player's Handbook · `barbarian-phb` | BONUS ACTION · RESOURCE | Rage (long_rest) | — | partly automatic | Bonus Action group | — | — | listed |  |
| 1 | Unarmored Defense | Player's Handbook · `barbarian-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 1 | Proficiencies | Player's Handbook · `barbarian-phb` | PASSIVE | — | skill | automatic | — (Build only) | — | — | choice |  |
| 2 | Reckless Attack | Player's Handbook · `barbarian-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 2 | Danger Sense | Player's Handbook · `barbarian-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 3 | Primal Path | Player's Handbook · `barbarian-phb` | PASSIVE | — | subclass | automatic | — (Build only) | — | — | choice |  |
| 3 | Primal Knowledge | Tasha's Cauldron of Everything · `barbarian-phb` | PASSIVE | — | skill | automatic | — (Build only) | — | — | choice |  |
| 4 | Ability Score Improvement | Player's Handbook · `barbarian-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 5 | Fast Movement | Player's Handbook · `barbarian-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 5 | Extra Attack | Player's Handbook · `barbarian-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 7 | Feral Instinct | Player's Handbook · `barbarian-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 7 | Instinctive Pounce | Tasha's Cauldron of Everything · `barbarian-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 8 | Ability Score Improvement | Player's Handbook · `barbarian-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 9 | Brutal Critical | Player's Handbook · `barbarian-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 10 | Primal Knowledge | Tasha's Cauldron of Everything · `barbarian-phb` | PASSIVE | — | skill | automatic | — (Build only) | — | — | choice |  |
| 11 | Relentless Rage | Player's Handbook · `barbarian-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 12 | Ability Score Improvement | Player's Handbook · `barbarian-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 15 | Persistent Rage | Player's Handbook · `barbarian-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 16 | Ability Score Improvement | Player's Handbook · `barbarian-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 18 | Indomitable Might | Player's Handbook · `barbarian-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 19 | Ability Score Improvement | Player's Handbook · `barbarian-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 20 | Primal Champion | Player's Handbook · `barbarian-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |

### Bard (25 features)

| Lvl | Feature | Source / version | Timing | Resource | Choice | Automation | Play | Spells | Inventory | Build | Note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Bardic Inspiration | Player's Handbook · `bard-phb` | BONUS ACTION · RESOURCE | Bardic Inspiration (long_rest) | — | partly automatic | Bonus Action group | — | — | listed |  |
| 1 | Spellcasting | Player's Handbook · `bard-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 1 | Proficiencies | Player's Handbook · `bard-phb` | PASSIVE | — | skill,tool | automatic | — (Build only) | — | — | choice |  |
| 2 | Jack of All Trades | Player's Handbook · `bard-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 2 | Song of Rest | Player's Handbook · `bard-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 2 | Magical Inspiration | Tasha's Cauldron of Everything · `bard-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 3 | Bard College | Player's Handbook · `bard-phb` | PASSIVE | — | subclass | automatic | — (Build only) | — | — | choice |  |
| 3 | Expertise | Player's Handbook · `bard-phb` | PASSIVE | — | expertise | automatic | — (Build only) | — | — | choice |  |
| 4 | Bardic Versatility | Tasha's Cauldron of Everything · `bard-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 4 | Ability Score Improvement | Player's Handbook · `bard-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 5 | Font of Inspiration | Player's Handbook · `bard-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 6 | Countercharm | Player's Handbook · `bard-phb` | ACTION · REMINDER | — | — | reminder only | Action group | — | — | listed |  |
| 8 | Ability Score Improvement | Player's Handbook · `bard-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 8 | Bardic Versatility | Tasha's Cauldron of Everything · `bard-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 10 | Magical Secrets | Player's Handbook · `bard-phb` | PASSIVE · SPELL-GRANTING | — | spell | automatic | — (Build only) | yes (granted spells) | — | choice |  |
| 10 | Expertise | Player's Handbook · `bard-phb` | PASSIVE | — | expertise | automatic | — (Build only) | — | — | choice |  |
| 12 | Bardic Versatility | Tasha's Cauldron of Everything · `bard-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 12 | Ability Score Improvement | Player's Handbook · `bard-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 14 | Magical Secrets | Player's Handbook · `bard-phb` | PASSIVE · SPELL-GRANTING | — | spell | automatic | — (Build only) | yes (granted spells) | — | choice |  |
| 16 | Ability Score Improvement | Player's Handbook · `bard-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 16 | Bardic Versatility | Tasha's Cauldron of Everything · `bard-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 18 | Magical Secrets | Player's Handbook · `bard-phb` | PASSIVE · SPELL-GRANTING | — | spell | automatic | — (Build only) | yes (granted spells) | — | choice |  |
| 19 | Bardic Versatility | Tasha's Cauldron of Everything · `bard-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 19 | Ability Score Improvement | Player's Handbook · `bard-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 20 | Superior Inspiration | Player's Handbook · `bard-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |

### Cleric (18 features)

| Lvl | Feature | Source / version | Timing | Resource | Choice | Automation | Play | Spells | Inventory | Build | Note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Divine Domain | Player's Handbook · `cleric-phb` | PASSIVE | — | subclass | automatic | — (Build only) | — | — | choice |  |
| 1 | Spellcasting | Player's Handbook · `cleric-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 1 | Proficiencies | Player's Handbook · `cleric-phb` | PASSIVE | — | skill | automatic | — (Build only) | — | — | choice |  |
| 2 | Turn Undead | Player's Handbook · `cleric-phb` | ACTION · REMINDER | — | — | reminder only | Action group | — | — | listed |  |
| 2 | Harness Divine Power | Tasha's Cauldron of Everything · `cleric-phb` | BONUS ACTION · RESOURCE | Harness Divine Power (long_rest) | — | partly automatic | Bonus Action group | — | — | listed |  |
| 2 | Channel Divinity | Player's Handbook · `cleric-phb` | ACTION · RESOURCE | Channel Divinity (short_or_long_rest) | — | partly automatic | Action group | — | — | listed |  |
| 4 | Cantrip Versatility | Tasha's Cauldron of Everything · `cleric-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 4 | Ability Score Improvement | Player's Handbook · `cleric-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 5 | Destroy Undead | Player's Handbook · `cleric-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 8 | Cantrip Versatility | Tasha's Cauldron of Everything · `cleric-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 8 | Ability Score Improvement | Player's Handbook · `cleric-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 10 | Divine Intervention | Player's Handbook · `cleric-phb` | ACTION · RESOURCE | Divine Intervention (manual) | — | partly automatic | Action group | — | — | listed |  |
| 12 | Ability Score Improvement | Player's Handbook · `cleric-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 12 | Cantrip Versatility | Tasha's Cauldron of Everything · `cleric-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 16 | Cantrip Versatility | Tasha's Cauldron of Everything · `cleric-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 16 | Ability Score Improvement | Player's Handbook · `cleric-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 19 | Ability Score Improvement | Player's Handbook · `cleric-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 19 | Cantrip Versatility | Tasha's Cauldron of Everything · `cleric-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |

### Druid (19 features)

| Lvl | Feature | Source / version | Timing | Resource | Choice | Automation | Play | Spells | Inventory | Build | Note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Proficiencies | Player's Handbook · `druid-phb` | PASSIVE | — | skill | automatic | — (Build only) | — | — | choice |  |
| 1 | Druidic | Player's Handbook · `druid-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 1 | Spellcasting | Player's Handbook · `druid-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 2 | Wild Companion | Tasha's Cauldron of Everything · `druid-phb` | PASSIVE | — | — | partly automatic | — (Build only) | — | — | listed |  |
| 2 | Druid Circle | Player's Handbook · `druid-phb` | PASSIVE | — | subclass | automatic | — (Build only) | — | — | choice |  |
| 2 | Wild Shape | Player's Handbook · `druid-phb` | ACTION · RESOURCE | Wild Shape (short_or_long_rest) | — | partly automatic | Action group | — | — | listed | quality reference (dedicated panel); overflow fixed |
| 4 | Ability Score Improvement | Player's Handbook · `druid-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 4 | Cantrip Versatility | Tasha's Cauldron of Everything · `druid-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 8 | Cantrip Versatility | Tasha's Cauldron of Everything · `druid-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 8 | Ability Score Improvement | Player's Handbook · `druid-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 12 | Ability Score Improvement | Player's Handbook · `druid-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 12 | Cantrip Versatility | Tasha's Cauldron of Everything · `druid-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 16 | Cantrip Versatility | Tasha's Cauldron of Everything · `druid-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 16 | Ability Score Improvement | Player's Handbook · `druid-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 18 | Timeless Body | Player's Handbook · `druid-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 18 | Beast Spells | Player's Handbook · `druid-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 19 | Cantrip Versatility | Tasha's Cauldron of Everything · `druid-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 19 | Ability Score Improvement | Player's Handbook · `druid-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 20 | Archdruid | Player's Handbook · `druid-phb` | PASSIVE | — | — | partly automatic | — (Build only) | — | — | listed |  |

### Fighter (21 features)

| Lvl | Feature | Source / version | Timing | Resource | Choice | Automation | Play | Spells | Inventory | Build | Note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Proficiencies | Player's Handbook · `fighter-phb` | PASSIVE | — | skill | automatic | — (Build only) | — | — | choice |  |
| 1 | Second Wind | Player's Handbook · `fighter-phb` | BONUS ACTION · RESOURCE | Second Wind (short_or_long_rest) | — | partly automatic | Bonus Action group | — | — | listed |  |
| 1 | Fighting Style | Player's Handbook · `fighter-phb` | PASSIVE · RESOURCE, CHOICE | Superiority die (Superior Technique) (short_or_long_rest) | option | partly automatic | Fighting Style / maneuver in Play by option timing; combat passives in Reminders | — | — | choice |  |
| 2 | Action Surge | Player's Handbook · `fighter-phb` | FREE / SPECIAL · RESOURCE | Action Surge (short_or_long_rest) | — | partly automatic | Free / Special group | — | — | listed |  |
| 3 | Martial Archetype | Player's Handbook · `fighter-phb` | PASSIVE | — | subclass | automatic | — (Build only) | — | — | choice |  |
| 4 | Martial Versatility | Tasha's Cauldron of Everything · `fighter-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 4 | Ability Score Improvement | Player's Handbook · `fighter-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 5 | Extra Attack | Player's Handbook · `fighter-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 6 | Martial Versatility | Tasha's Cauldron of Everything · `fighter-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 6 | Ability Score Improvement | Player's Handbook · `fighter-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 8 | Martial Versatility | Tasha's Cauldron of Everything · `fighter-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 8 | Ability Score Improvement | Player's Handbook · `fighter-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 9 | Indomitable | Player's Handbook · `fighter-phb` | FREE / SPECIAL · RESOURCE | Indomitable (long_rest) | — | partly automatic | Free / Special group | — | — | listed |  |
| 12 | Martial Versatility | Tasha's Cauldron of Everything · `fighter-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 12 | Ability Score Improvement | Player's Handbook · `fighter-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 14 | Martial Versatility | Tasha's Cauldron of Everything · `fighter-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 14 | Ability Score Improvement | Player's Handbook · `fighter-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 16 | Ability Score Improvement | Player's Handbook · `fighter-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 16 | Martial Versatility | Tasha's Cauldron of Everything · `fighter-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 19 | Martial Versatility | Tasha's Cauldron of Everything · `fighter-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 19 | Ability Score Improvement | Player's Handbook · `fighter-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |

### Monk (28 features)

| Lvl | Feature | Source / version | Timing | Resource | Choice | Automation | Play | Spells | Inventory | Build | Note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Proficiencies | Player's Handbook · `monk-phb` | PASSIVE | — | skill,tool | automatic | — (Build only) | — | — | choice |  |
| 1 | Martial Arts | Player's Handbook · `monk-phb` | PASSIVE | — | — | partly automatic | — (Build only) | — | — | listed |  |
| 1 | Unarmored Defense | Player's Handbook · `monk-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 2 | Unarmored Movement | Player's Handbook · `monk-phb` | PASSIVE | — | — | partly automatic | — (Build only) | — | — | listed |  |
| 2 | Ki | Player's Handbook · `monk-phb` | PASSIVE · RESOURCE | Ki (short_or_long_rest) | — | partly automatic | Ready to use (uses) | — | — | listed |  |
| 2 | Dedicated Weapon | Tasha's Cauldron of Everything · `monk-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 3 | Deflect Missiles | Player's Handbook · `monk-phb` | REACTION · REMINDER | — | — | reminder only | Reaction group | — | — | listed |  |
| 3 | Ki-Fueled Attack | Tasha's Cauldron of Everything · `monk-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 3 | Monastic Tradition | Player's Handbook · `monk-phb` | PASSIVE | — | subclass | automatic | — (Build only) | — | — | choice |  |
| 4 | Quickened Healing | Tasha's Cauldron of Everything · `monk-phb` | ACTION · REMINDER | — | — | reminder only | Action group | — | — | listed |  |
| 4 | Slow Fall | Player's Handbook · `monk-phb` | REACTION · REMINDER | — | — | reminder only | Reaction group | — | — | listed |  |
| 4 | Ability Score Improvement | Player's Handbook · `monk-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 5 | Stunning Strike | Player's Handbook · `monk-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 5 | Extra Attack | Player's Handbook · `monk-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 5 | Focused Aim | Tasha's Cauldron of Everything · `monk-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 6 | Ki-Empowered Strikes | Player's Handbook · `monk-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 7 | Stillness of Mind | Player's Handbook · `monk-phb` | ACTION · REMINDER | — | — | reminder only | Action group | — | — | listed |  |
| 7 | Evasion | Player's Handbook · `monk-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 8 | Ability Score Improvement | Player's Handbook · `monk-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 10 | Purity of Body | Player's Handbook · `monk-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 12 | Ability Score Improvement | Player's Handbook · `monk-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 13 | Tongue of the Sun and Moon | Player's Handbook · `monk-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 14 | Diamond Soul | Player's Handbook · `monk-phb` | PASSIVE | — | — | partly automatic | — (Build only) | — | — | listed |  |
| 15 | Timeless Body | Player's Handbook · `monk-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 16 | Ability Score Improvement | Player's Handbook · `monk-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 18 | Empty Body | Player's Handbook · `monk-phb` | ACTION · REMINDER | — | — | reminder only | Action group | — | — | listed |  |
| 19 | Ability Score Improvement | Player's Handbook · `monk-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 20 | Perfect Self | Player's Handbook · `monk-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |

### Paladin (25 features)

| Lvl | Feature | Source / version | Timing | Resource | Choice | Automation | Play | Spells | Inventory | Build | Note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Proficiencies | Player's Handbook · `paladin-phb` | PASSIVE | — | skill | automatic | — (Build only) | — | — | choice |  |
| 1 | Divine Sense | Player's Handbook · `paladin-phb` | ACTION · RESOURCE | Divine Sense (long_rest) | — | partly automatic | Action group | — | — | listed |  |
| 1 | Lay on Hands | Player's Handbook · `paladin-phb` | ACTION · RESOURCE | Lay on Hands (long_rest) | — | partly automatic | Action group | — | — | listed |  |
| 2 | Fighting Style | Player's Handbook · `paladin-phb` | PASSIVE · CHOICE, SPELL-GRANTING | — | option,spell | partly automatic | as Fighting Style (Blessed Warrior cantrips: Spells) | yes (granted spells) | — | choice |  |
| 2 | Divine Smite | Player's Handbook · `paladin-phb` | PASSIVE | — | — | partly automatic | — (Build only) | — | — | listed |  |
| 2 | Spellcasting | Player's Handbook · `paladin-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 3 | Channel Divinity | Player's Handbook · `paladin-phb` | ACTION · RESOURCE | Channel Divinity (short_or_long_rest) | — | partly automatic | Action group | — | — | listed |  |
| 3 | Sacred Oath | Player's Handbook · `paladin-phb` | PASSIVE | — | subclass | automatic | — (Build only) | — | — | choice |  |
| 3 | Harness Divine Power | Tasha's Cauldron of Everything · `paladin-phb` | BONUS ACTION · RESOURCE | Harness Divine Power (long_rest) | — | partly automatic | Bonus Action group | — | — | listed |  |
| 3 | Divine Health | Player's Handbook · `paladin-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 4 | Martial Versatility | Tasha's Cauldron of Everything · `paladin-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 4 | Ability Score Improvement | Player's Handbook · `paladin-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 5 | Extra Attack | Player's Handbook · `paladin-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 6 | Aura of Protection | Player's Handbook · `paladin-phb` | PASSIVE | — | — | partly automatic | — (Build only) | — | — | listed |  |
| 8 | Martial Versatility | Tasha's Cauldron of Everything · `paladin-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 8 | Ability Score Improvement | Player's Handbook · `paladin-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 10 | Aura of Courage | Player's Handbook · `paladin-phb` | PASSIVE | — | — | partly automatic | — (Build only) | — | — | listed |  |
| 11 | Improved Divine Smite | Player's Handbook · `paladin-phb` | PASSIVE | — | — | partly automatic | — (Build only) | — | — | listed |  |
| 12 | Martial Versatility | Tasha's Cauldron of Everything · `paladin-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 12 | Ability Score Improvement | Player's Handbook · `paladin-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 14 | Cleansing Touch | Player's Handbook · `paladin-phb` | ACTION · RESOURCE | Cleansing Touch (long_rest) | — | partly automatic | Action group | — | — | listed |  |
| 16 | Ability Score Improvement | Player's Handbook · `paladin-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 16 | Martial Versatility | Tasha's Cauldron of Everything · `paladin-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 19 | Ability Score Improvement | Player's Handbook · `paladin-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 19 | Martial Versatility | Tasha's Cauldron of Everything · `paladin-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |

### Ranger (28 features)

| Lvl | Feature | Source / version | Timing | Resource | Choice | Automation | Play | Spells | Inventory | Build | Note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Deft Explorer | Tasha's Cauldron of Everything · `ranger-phb` | PASSIVE · RESOURCE | Tireless (long_rest) | expertise,language | partly automatic | Ready to use (uses) | — | — | choice |  |
| 1 | Favored Foe | Tasha's Cauldron of Everything · `ranger-phb` | PASSIVE · RESOURCE | Favored Foe (long_rest) | — | partly automatic | Ready to use (uses) | — | — | listed |  |
| 1 | Proficiencies | Player's Handbook · `ranger-phb` | PASSIVE | — | skill | automatic | — (Build only) | — | — | choice |  |
| 1 | Natural Explorer | Player's Handbook · `ranger-phb` | PASSIVE · CHOICE, REMINDER | — | option | reminder only | — (Build only) | — | — | choice |  |
| 1 | Favored Enemy | Player's Handbook · `ranger-phb` | PASSIVE · CHOICE | — | language,option | partly automatic | — (Build only) | — | — | choice |  |
| 2 | Spellcasting | Player's Handbook · `ranger-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 2 | Fighting Style | Player's Handbook · `ranger-phb` | PASSIVE · CHOICE, SPELL-GRANTING | — | option,spell | partly automatic | as Fighting Style (Druidic Warrior cantrips: Spells) | yes (granted spells) | — | choice |  |
| 2 | Spellcasting Focus | Tasha's Cauldron of Everything · `ranger-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 3 | Primal Awareness | Tasha's Cauldron of Everything · `ranger-phb` | PASSIVE · RESOURCE | Primal Awareness (free casts) (long_rest) | — | partly automatic | Ready to use (uses) | — | — | listed |  |
| 3 | Primeval Awareness | Player's Handbook · `ranger-phb` | ACTION · REMINDER | — | — | reminder only | Action group | — | — | listed |  |
| 3 | Ranger Conclave | Player's Handbook · `ranger-phb` | PASSIVE | — | subclass | automatic | — (Build only) | — | — | choice |  |
| 4 | Martial Versatility | Tasha's Cauldron of Everything · `ranger-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 4 | Ability Score Improvement | Player's Handbook · `ranger-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 5 | Extra Attack | Player's Handbook · `ranger-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 8 | Martial Versatility | Tasha's Cauldron of Everything · `ranger-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 8 | Ability Score Improvement | Player's Handbook · `ranger-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 8 | Land's Stride | Player's Handbook · `ranger-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 10 | Nature's Veil | Tasha's Cauldron of Everything · `ranger-phb` | BONUS ACTION · RESOURCE | Nature's Veil (long_rest) | — | partly automatic | Bonus Action group | — | — | listed |  |
| 10 | Hide in Plain Sight | Player's Handbook · `ranger-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 12 | Martial Versatility | Tasha's Cauldron of Everything · `ranger-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 12 | Ability Score Improvement | Player's Handbook · `ranger-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 14 | Vanish | Player's Handbook · `ranger-phb` | BONUS ACTION · REMINDER | — | — | reminder only | Bonus Action group | — | — | listed |  |
| 16 | Ability Score Improvement | Player's Handbook · `ranger-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 16 | Martial Versatility | Tasha's Cauldron of Everything · `ranger-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 18 | Feral Senses | Player's Handbook · `ranger-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 19 | Martial Versatility | Tasha's Cauldron of Everything · `ranger-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 19 | Ability Score Improvement | Player's Handbook · `ranger-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 20 | Foe Slayer | Player's Handbook · `ranger-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |

### Rogue (21 features)

| Lvl | Feature | Source / version | Timing | Resource | Choice | Automation | Play | Spells | Inventory | Build | Note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Expertise | Player's Handbook · `rogue-phb` | PASSIVE | — | expertise | automatic | — (Build only) | — | — | choice |  |
| 1 | Proficiencies | Player's Handbook · `rogue-phb` | PASSIVE | — | skill | automatic | — (Build only) | — | — | choice |  |
| 1 | Sneak Attack | Player's Handbook · `rogue-phb` | PASSIVE | — | — | partly automatic | — (Build only) | — | — | listed |  |
| 1 | Thieves' Cant | Player's Handbook · `rogue-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 2 | Cunning Action | Player's Handbook · `rogue-phb` | BONUS ACTION · REMINDER | — | — | reminder only | Bonus Action group | — | — | listed |  |
| 3 | Steady Aim | Tasha's Cauldron of Everything · `rogue-phb` | BONUS ACTION · REMINDER | — | — | reminder only | Bonus Action group | — | — | listed |  |
| 3 | Roguish Archetype | Player's Handbook · `rogue-phb` | PASSIVE | — | subclass | automatic | — (Build only) | — | — | choice |  |
| 4 | Ability Score Improvement | Player's Handbook · `rogue-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 5 | Uncanny Dodge | Player's Handbook · `rogue-phb` | REACTION · REMINDER | — | — | reminder only | Reaction group | — | — | listed |  |
| 6 | Expertise | Player's Handbook · `rogue-phb` | PASSIVE | — | expertise | automatic | — (Build only) | — | — | choice |  |
| 7 | Evasion | Player's Handbook · `rogue-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 8 | Ability Score Improvement | Player's Handbook · `rogue-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 10 | Ability Score Improvement | Player's Handbook · `rogue-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 11 | Reliable Talent | Player's Handbook · `rogue-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 12 | Ability Score Improvement | Player's Handbook · `rogue-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 14 | Blindsense | Player's Handbook · `rogue-phb` | PASSIVE | — | — | partly automatic | — (Build only) | — | — | listed |  |
| 15 | Slippery Mind | Player's Handbook · `rogue-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 16 | Ability Score Improvement | Player's Handbook · `rogue-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 18 | Elusive | Player's Handbook · `rogue-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 19 | Ability Score Improvement | Player's Handbook · `rogue-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 20 | Stroke of Luck | Player's Handbook · `rogue-phb` | FREE / SPECIAL · RESOURCE | Stroke of Luck (short_or_long_rest) | — | partly automatic | Free / Special group | — | — | listed |  |

### Sorcerer (17 features)

| Lvl | Feature | Source / version | Timing | Resource | Choice | Automation | Play | Spells | Inventory | Build | Note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Sorcerous Origin | Player's Handbook · `sorcerer-phb` | PASSIVE | — | subclass | automatic | — (Build only) | — | — | choice |  |
| 1 | Proficiencies | Player's Handbook · `sorcerer-phb` | PASSIVE | — | skill | automatic | — (Build only) | — | — | choice |  |
| 1 | Spellcasting | Player's Handbook · `sorcerer-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 2 | Font of Magic | Player's Handbook · `sorcerer-phb` | BONUS ACTION · RESOURCE | Sorcery Points (long_rest) | — | automatic | Bonus Action group | — | — | listed |  |
| 3 | Metamagic | Player's Handbook · `sorcerer-phb` | PASSIVE · CHOICE, REMINDER | — | option | reminder only | Metamagic options in Play > Free and special (with point cost) | — | — | choice |  |
| 4 | Sorcerous Versatility | Tasha's Cauldron of Everything · `sorcerer-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 4 | Ability Score Improvement | Player's Handbook · `sorcerer-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 5 | Magical Guidance | Tasha's Cauldron of Everything · `sorcerer-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 8 | Sorcerous Versatility | Tasha's Cauldron of Everything · `sorcerer-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 8 | Ability Score Improvement | Player's Handbook · `sorcerer-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 12 | Sorcerous Versatility | Tasha's Cauldron of Everything · `sorcerer-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 12 | Ability Score Improvement | Player's Handbook · `sorcerer-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 16 | Sorcerous Versatility | Tasha's Cauldron of Everything · `sorcerer-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 16 | Ability Score Improvement | Player's Handbook · `sorcerer-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 19 | Ability Score Improvement | Player's Handbook · `sorcerer-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 19 | Sorcerous Versatility | Tasha's Cauldron of Everything · `sorcerer-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 20 | Sorcerous Restoration | Player's Handbook · `sorcerer-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |

### Warlock (20 features)

| Lvl | Feature | Source / version | Timing | Resource | Choice | Automation | Play | Spells | Inventory | Build | Note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Otherworldly Patron | Player's Handbook · `warlock-phb` | PASSIVE | — | subclass | automatic | — (Build only) | — | — | choice |  |
| 1 | Proficiencies | Player's Handbook · `warlock-phb` | PASSIVE | — | skill | automatic | — (Build only) | — | — | choice |  |
| 1 | Pact Magic | Player's Handbook · `warlock-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 2 | Eldritch Invocations | Player's Handbook · `warlock-phb` | PASSIVE · RESOURCE, CHOICE | Bewitching Whispers (long_rest), Bond of the Talisman (long_rest), Cloak of Flies (short_or_long_rest), Dreadful Word (long_rest), Ghostly Gaze (short_or_long_rest), Gift of the Depths (Water Breathing) (long_rest), Minions of Chaos (long_rest), Mire the Mind (long_rest), Protection of the Talisman (long_rest), Sculptor of Flesh (long_rest), Sign of Ill Omen (long_rest), Thief of Five Fates (long_rest), Tomb of Levistus (short_or_long_rest), Trickster's Escape (long_rest), Undying Servitude (long_rest) | option | partly automatic | Invocations: by option timing (Actions / Bonus / Reactions / Special, combat passives in Reminders, spell casts in Spells) | option casts | — | choice |  |
| 3 | Pact Boon | Player's Handbook · `warlock-phb` | PASSIVE · RESOURCE, CHOICE, SPELL-GRANTING | Talisman (1d4 to a failed check) (long_rest) | option,spell | partly automatic | Pact Boon option in Play by timing (Chain / Tome: Spells) | yes (granted spells) | — | choice |  |
| 4 | Ability Score Improvement | Player's Handbook · `warlock-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 4 | Eldritch Versatility | Tasha's Cauldron of Everything · `warlock-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 8 | Eldritch Versatility | Tasha's Cauldron of Everything · `warlock-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 8 | Ability Score Improvement | Player's Handbook · `warlock-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 11 | Mystic Arcanum (6th level) | Player's Handbook · `warlock-phb` | PASSIVE · RESOURCE, SPELL-GRANTING | Mystic Arcanum (6th) (long_rest) | spell | partly automatic | Ready to use (uses) | yes (granted spells) | — | choice |  |
| 12 | Eldritch Versatility | Tasha's Cauldron of Everything · `warlock-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 12 | Ability Score Improvement | Player's Handbook · `warlock-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 13 | Mystic Arcanum (7th level) | Player's Handbook · `warlock-phb` | PASSIVE · RESOURCE, SPELL-GRANTING | Mystic Arcanum (7th) (long_rest) | spell | partly automatic | Ready to use (uses) | yes (granted spells) | — | choice |  |
| 15 | Mystic Arcanum (8th level) | Player's Handbook · `warlock-phb` | PASSIVE · RESOURCE, SPELL-GRANTING | Mystic Arcanum (8th) (long_rest) | spell | partly automatic | Ready to use (uses) | yes (granted spells) | — | choice |  |
| 16 | Ability Score Improvement | Player's Handbook · `warlock-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 16 | Eldritch Versatility | Tasha's Cauldron of Everything · `warlock-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 17 | Mystic Arcanum (9th level) | Player's Handbook · `warlock-phb` | PASSIVE · RESOURCE, SPELL-GRANTING | Mystic Arcanum (9th) (long_rest) | spell | partly automatic | Ready to use (uses) | yes (granted spells) | — | choice |  |
| 19 | Eldritch Versatility | Tasha's Cauldron of Everything · `warlock-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 19 | Ability Score Improvement | Player's Handbook · `warlock-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 20 | Eldritch Master | Player's Handbook · `warlock-phb` | FREE / SPECIAL · RESOURCE | Eldritch Master (long_rest) | — | automatic | Free / Special group | — | — | listed |  |

### Wizard (12 features)

| Lvl | Feature | Source / version | Timing | Resource | Choice | Automation | Play | Spells | Inventory | Build | Note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Spellcasting | Player's Handbook · `wizard-phb` | PASSIVE | — | — | automatic | — (Build only) | — | — | listed |  |
| 1 | Proficiencies | Player's Handbook · `wizard-phb` | PASSIVE | — | skill | automatic | — (Build only) | — | — | choice |  |
| 1 | Arcane Recovery | Player's Handbook · `wizard-phb` | FREE / SPECIAL · RESOURCE | Arcane Recovery (long_rest) | — | partly automatic | Free / Special group | — | — | listed |  |
| 2 | Arcane Tradition | Player's Handbook · `wizard-phb` | PASSIVE | — | subclass | automatic | — (Build only) | — | — | choice |  |
| 3 | Cantrip Formulas | Tasha's Cauldron of Everything · `wizard-phb` | PASSIVE · REMINDER | — | — | reminder only | — (Build only) | — | — | listed |  |
| 4 | Ability Score Improvement | Player's Handbook · `wizard-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 8 | Ability Score Improvement | Player's Handbook · `wizard-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 12 | Ability Score Improvement | Player's Handbook · `wizard-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 16 | Ability Score Improvement | Player's Handbook · `wizard-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 18 | Spell Mastery | Player's Handbook · `wizard-phb` | PASSIVE · SPELL-GRANTING | — | spell | partly automatic | — (Build only) | yes (granted spells) | — | choice |  |
| 19 | Ability Score Improvement | Player's Handbook · `wizard-phb` | PASSIVE | — | asi | partly automatic | — (Build only) | — | — | ASI / feat choice |  |
| 20 | Signature Spells | Player's Handbook · `wizard-phb` | PASSIVE · RESOURCE, SPELL-GRANTING | Signature Spells (free casts) (short_or_long_rest) | spell | partly automatic | Ready to use (uses) | yes (granted spells) | — | choice |  |
