# Active gameplay feature audit (2026-11-09)

Question this audit answers for every implemented feature: **what can the character use, trigger or remember during actual
play, and where does Tavern Ledger show it?** Scope: every official catalog version available to characters — 13 classes
(274 class feature unlocks, 208 class options), 839 lineage traits, 408 feat versions, 30 background versions — plus campaign
custom content (DM Space) and item-bound Artificer infusions. Only mechanics already in the project catalog are used; nothing
was added from source books. Tables below are generated from the local catalog, which equals production for every id used
(checked read-only: all 157 timing ids exist in production).

## Classification

| Class | Meaning | Where it appears |
|---|---|---|
| PASSIVE (applied) | always on and applied by the app (speed, resistance, proficiency, ability bonus) | Build; not repeated in Play |
| ACTION / BONUS ACTION / REACTION | the catalog text or structured `activation` states the timing | Play card in that group |
| FREE / SPECIAL | used outside the action types ("once per turn when you hit", "when you drop to 0 HP") | Play > Free and special |
| RESOURCE | limited uses (class resource, lineage counter, feat counter) | Play > Ready to use (counter, Use, recovery) |
| TOGGLE / ACTIVE MODE | Rage-style states, Wild Shape | Play > Ready to use (state card) / Wild Shape panel |
| SPELL-GRANTING | adds a known / prepared / free-use spell | Spells, under the granting source |
| ITEM-BOUND | lives on an item (Artificer infusions) | Inventory badge, Play > Infused items, Build card |
| CHOICE-BASED | depends on a saved player choice | the option's own timing; Build shows missing choices as Next step |
| REMINDER ONLY | matters in play but is not automated | Play > Passive and reminders (one line), tagged "reminder only" |
| NON-GAMEPLAY | descriptive or configuration only ("See the source for the benefits") | Build only |

Automation status shown on every Play card: **automatic** / **partly automatic** / **reminder only**. A reminder-only feature
never gets a Use button; a counter's Use button lives in Ready to use only.

## How Play is built (one read model, no extra request)

`js/active-features.js` builds the compact card model from reads the sheet already loads in its single progressive
`get_character_reads` wave (class features, resources, lineage, feats, infusions) plus one small catalog table read once per page
session (`catalog_play_timing`, migration `20261109000200`, 157 rows, ~6 KB). Cards carry: feature id, version, name, source
type and name, timing, concise summary, current / maximum uses, recovery, selected option, target item, granted spells, automation
and state. Full descriptions stay on Build. No RPC per card and no rules evaluation per card; lineage, feat and timing reads
re-render only the timing groups and Ready to use (`rerenderPlayFeatures`). The Combat Builder loads the same model for one linked
character on request (one `get_character_reads`, server-cached per revision) and refreshes only that character after one of its
build or resource revisions.

## Findings

| # | Finding | Status |
|---|---|---|
| 1 | Class features with a structured timing and the 208 class options (Invocations, Metamagic, Fighting Styles, maneuvers, Hunter options, Pact Boon) are in Play since 20261107000400. | verified, kept (audit of that patch below) |
| 2 | **Lineage traits had no timing**: Breath Weapon, Healing Hands, Rabbit Hop, Relentless Endurance, Fury of the Small, Shell Defense … were readable only on Build; only their counters appeared in Ready to use. | **fixed**: 135 traits classified from their own catalog text (61 cards, 5 counters, 69 reminders); Play cards under their timing |
| 3 | **Feats had no Play presence** (Interception, Protection, Defensive Duelist, Telekinetic shove, Savage Attacker, Mage Slayer …). | **fixed**: 22 feat versions classified (14 cards, 8 reminders); feat counters (Chef treats) now in Ready to use; the card names its source (Feat / Background: … / Lineage: … / Fighter: ASI) |
| 4 | Feat free casts (Fey Touched, Magic Initiate …) | already in Spells under the feat's own source with the free-cast counter; not repeated in Play |
| 5 | Background features (2014 "Feature" entries) are descriptive. | NON-GAMEPLAY: Build only; a background's feat appears through its feat card with source "Background: …" |
| 6 | Combat Builder showed AC / HP / speed / passives of a linked character but not what it can do. | **added**: "Active features" in the combatant detail (actions, bonus actions, reactions, free/special, limited uses), loaded on request |
| 7 | Campaign custom lineages / feats have no `catalog_play_timing` row. | by design: their counters appear in Ready to use; their text stays on Build (no timing invented) |
| 8 | Artificer infusions: no infusion in the catalog grants a spell; all 16 are item-bound. | verified: Inventory badge, Play > Infused items (with the infusion text, which states any action / reaction), Build card; no Spells entry (correct) |

## Targeted catalog patches

### 20261107000400_class_option_activation (already in production since 2026-11-08) — re-audited

| Check | Result |
|---|---|
| Keyed by stable ids | yes: `class_feature_choice_options (choice_id, option_id)` of 12 named choice features |
| Expected / matched rows | 208 / 208 (local and production) |
| Change | adds `data.activation` (+ `data.play = reminder` for combat passives) only; no mechanic, no custom row, no display-name match |
| Idempotent | yes (second run changes 0 rows); derived values unchanged (golden equal, 2026-11-08 release) |

### 20261109000200_active_feature_timing (this release)

| Check | Result |
|---|---|
| Kind | ADDITIVE: new table `catalog_play_timing`; **no existing row of any table is updated** |
| Keyed by | (source_kind, stable catalog id); official rows only (`content_version_id is null`) |
| Expected matched rows | 157 (135 lineage traits + 22 feat versions); production read-only match: **157** |
| Inserted / updated / skipped | first run 157 / 0 / 0; second run 0 / 0 / 157 (idempotent) |
| Guard | the migration refuses to apply if the matched count differs from 157 |
| Effect on mechanics | none: presentation only; derived values unchanged |
| Source of each timing | the trait's / feat's own catalog summary ("Bonus action: …", "as an action", "Reaction: …", "once per turn …"); a trait with uses but no stated timing is RESOURCE; Mage Slayer 2014 ("React to adjacent casters") set to REACTION by hand |

## Summary counts

| Source | Total | Play card | Resource only | Reminder | Passive applied | Non-gameplay |
|---|---|---|---|---|---|---|
| Lineage traits | 839 | 61 | 5 | 69 | 609 | 95 |
| Feat versions | 408 | 14 | 4 (+ counters of carded feats) | 8 | 8 + 202 ability-only + 8 spell-granting + 6 choice-based | 162 |
| Background versions | 30 | 0 | 0 | 0 | proficiencies / ability choices | features (descriptive) |
| Class feature unlocks | 274 | 53 with timing | class resources | options flagged `play: reminder` | 217 passive | none |

## Class features (13 classes)

Classes, subclasses and their options are unchanged in this release; the per-feature class table (274 unlocks, timing,
resource, choice, automation, Play / Spells / Inventory / Build visibility) is `docs/ACTIVE_CLASS_FEATURE_AUDIT.md`
(generated 2026-11-07 from the same catalog; re-checked: `class_feature_versions.activation` counts action 21, bonus action 15,
reaction 6, special 11, passive 217). Representative checks per class, all covered by the class suites and browser tests:

| Class | Play (verified) |
|---|---|
| Artificer | Infusions known / active / target item / attunement; Inventory "Infused: …" badge; Play > Infused items; replacement and removal remove only that infusion's modifier (artificer_tests.sql, class_artificer_ui_test.py) |
| Barbarian | Rage state card with uses and Rage damage; Reckless Attack / subclass actions by timing |
| Bard | Bardic Inspiration counter (die, recovery) + Bonus action card |
| Cleric | Channel Divinity counter + domain options by timing; domain spells in Spells |
| Druid | Wild Shape (uses, active form, form HP, overflow damage) — the quality reference |
| Fighter | Second Wind, Action Surge, Fighting Style reminders, maneuvers + Superiority Dice |
| Monk | Ki points with costed Bonus actions (Flurry, Patient Defense, Step of the Wind), Deflect Missiles reaction |
| Paladin | Lay on Hands pool, Channel Divinity, Divine Smite rider (spends a slot), aura reminders |
| Ranger | Hunter options by timing, Favored Enemy / Natural Explorer Build only, spells in Spells |
| Rogue | Cunning Action, Uncanny Dodge, Sneak Attack rider |
| Sorcerer | Sorcery Points + Metamagic options with point cost in Free and special |
| Warlock | Invocations by timing; spell-granting invocations in Spells once (no duplicate source); Pact Boon |
| Wizard | Arcane Recovery counter; school features only when gameplay-relevant; spellbook in Spells |

Unsupported (documented, not invented): 2024 class versions are not in the catalog; subclass mechanics whose catalog text says
"See the source" stay Build-only reminders.

## Lineage traits with a Play presentation (135 of 839)

The remaining traits are PASSIVE (applied by the lineage engine: speed, senses, resistances, languages, proficiencies,
ability bonuses) or NON-GAMEPLAY (size, age, descriptive text) and stay on Build.

| Trait id | Lineage version | Trait | Lvl | Classification | Uses | Recovery | Play | Spells | Build | Automation |
|---|---|---|---|---|---|---|---|---|---|---|
| `aarakocra-eepc:talons` | Aarakocra | Talons | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `aarakocra-mpmm:talons` | Aarakocra | Talons | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `aasimar-fallen:necrotic-shroud` | Fallen Aasimar | Necrotic Shroud | 3 | ACTION + RESOURCE | 1 | long_rest | card under Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `aasimar-mpmm:celestial-resistance` | Aasimar | Celestial Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `aasimar-mpmm:healing-hands` | Aasimar | Healing Hands | 1 | ACTION + RESOURCE | 1 | long_rest | card under Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `aasimar-mpmm:celestial-revelation` | Aasimar | Celestial Revelation | 3 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | partly automatic |
| `aasimar-protector:radiant-soul` | Protector Aasimar | Radiant Soul | 3 | ACTION + RESOURCE | 1 | long_rest | card under Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `aasimar-scourge:radiant-consumption` | Scourge Aasimar | Radiant Consumption | 3 | ACTION + RESOURCE | 1 | long_rest | card under Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `aasimar-vgm:celestial-resistance` | Aasimar | Celestial Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `aasimar-vgm:healing-hands` | Aasimar | Healing Hands | 1 | ACTION + RESOURCE | 1 | long_rest | card under Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `bugbear-mpmm:fey-ancestry` | Bugbear | Fey Ancestry | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `centaur-ggr:charge` | Centaur | Charge | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `centaur-ggr:hooves` | Centaur | Hooves | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `centaur-mot:charge` | Centaur | Charge | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `centaur-mot:hooves` | Centaur | Hooves | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `centaur-mpmm:charge` | Centaur | Charge | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `centaur-mpmm:hooves` | Centaur | Hooves | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `changeling-erlw:shapechanger` | Changeling | Shapechanger | 1 | ACTION | — | — | card under Action | — | Build (lineage card) | reminder only |
| `changeling-mpmm:shapechanger` | Changeling | Shapechanger | 1 | ACTION | — | — | card under Action | — | Build (lineage card) | reminder only |
| `deep-gnome-mpmm:svirfneblin-camouflage` | Deep Gnome | Svirfneblin Camouflage | 1 | RESOURCE | pb | long_rest | Ready to use (counter) | — | Build (lineage card) | partly automatic |
| `dragonborn-chromatic:breath-weapon` | Chromatic Dragonborn | Breath Weapon | 1 | ACTION + RESOURCE | pb | long_rest | card under Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `dragonborn-chromatic:draconic-resistance` | Chromatic Dragonborn | Draconic Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `dragonborn-chromatic:chromatic-warding` | Chromatic Dragonborn | Chromatic Warding | 5 | ACTION + RESOURCE | 1 | long_rest | card under Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `dragonborn-draconblood:forceful-presence` | Draconblood | Forceful Presence | 1 | RESOURCE | 1 | long_rest | Ready to use (counter) | — | Build (lineage card) | partly automatic |
| `dragonborn-gem:breath-weapon` | Gem Dragonborn | Breath Weapon | 1 | ACTION + RESOURCE | pb | long_rest | card under Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `dragonborn-gem:draconic-resistance` | Gem Dragonborn | Draconic Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `dragonborn-gem:gem-flight` | Gem Dragonborn | Gem Flight | 5 | BONUS ACTION + RESOURCE | 1 | long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `dragonborn-metallic:breath-weapon` | Metallic Dragonborn | Breath Weapon | 1 | ACTION + RESOURCE | pb | long_rest | card under Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `dragonborn-metallic:draconic-resistance` | Metallic Dragonborn | Draconic Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `dragonborn-metallic:metallic-breath-weapon` | Metallic Dragonborn | Metallic Breath Weapon | 5 | RESOURCE | 1 | long_rest | Ready to use (counter) | — | Build (lineage card) | partly automatic |
| `dragonborn-phb:breath-weapon` | Dragonborn | Breath Weapon | 1 | ACTION + RESOURCE | 1 | short_or_long_rest | card under Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `dragonborn-phb:damage-resistance` | Dragonborn | Damage Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `dragonborn-ravenite:vengeful-assault` | Ravenite | Vengeful Assault | 1 | REACTION + RESOURCE | 1 | short_or_long_rest | card under Reaction + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `duergar-mpmm:dwarven-resilience` | Duergar | Dwarven Resilience | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `duergar-mpmm:psionic-fortitude` | Duergar | Psionic Fortitude | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `duergar-scag:dwarven-resilience` | Duergar | Dwarven Resilience | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `duergar-scag:duergar-resilience` | Duergar | Duergar Resilience | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `dwarf-phb:dwarven-resilience` | Dwarf | Dwarven Resilience | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `eladrin-mpmm:fey-ancestry` | Eladrin | Fey Ancestry | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `eladrin-mpmm:fey-step` | Eladrin | Fey Step | 1 | BONUS ACTION + RESOURCE | pb | long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `eladrin-mtf:fey-ancestry` | Eladrin | Fey Ancestry | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `eladrin-mtf:fey-step` | Eladrin | Fey Step | 1 | BONUS ACTION + RESOURCE | 1 | short_or_long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `elf-phb:fey-ancestry` | Elf | Fey Ancestry | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `firbolg-mpmm:hidden-step` | Firbolg | Hidden Step | 1 | BONUS ACTION + RESOURCE | pb | long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `firbolg-vgm:hidden-step` | Firbolg | Hidden Step | 1 | BONUS ACTION + RESOURCE | 1 | short_or_long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `genasi-air-mpmm:lightning-resistance` | Air Genasi | Lightning Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `genasi-earth-mpmm:merge-with-stone` | Earth Genasi | Merge with Stone | 1 | BONUS ACTION + SPELL-GRANTING | — | — | card under Bonus Action | yes | Build (lineage card) | partly automatic |
| `genasi-fire-eepc:fire-resistance` | Fire Genasi | Fire Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `genasi-fire-mpmm:fire-resistance` | Fire Genasi | Fire Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `genasi-water-eepc:acid-resistance` | Water Genasi | Acid Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `genasi-water-mpmm:acid-resistance` | Water Genasi | Acid Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `githyanki-mpmm:psychic-resilience` | Githyanki | Psychic Resilience | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `githzerai-mpmm:mental-discipline` | Githzerai | Mental Discipline | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `githzerai-mpmm:psychic-resilience` | Githzerai | Psychic Resilience | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `githzerai-mtf:mental-discipline` | Githzerai | Mental Discipline | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `goblin-dankwood:nimble-escape` | Dankwood Goblin | Nimble Escape | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `goblin-mpmm:fey-ancestry` | Goblin | Fey Ancestry | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `goblin-mpmm:fury-of-the-small` | Goblin | Fury of the Small | 1 | FREE / SPECIAL + RESOURCE | pb | long_rest | card under Free / Special + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `goblin-mpmm:nimble-escape` | Goblin | Nimble Escape | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `goblin-vgm:fury-of-the-small` | Goblin | Fury of the Small | 1 | RESOURCE | 1 | short_or_long_rest | Ready to use (counter) | — | Build (lineage card) | partly automatic |
| `goblin-vgm:nimble-escape` | Goblin | Nimble Escape | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `goliath-eepc:stones-endurance` | Goliath | Stone's Endurance | 1 | REACTION + RESOURCE | 1 | short_or_long_rest | card under Reaction + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `goliath-eepc:mountain-born` | Goliath | Mountain Born | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `goliath-mpmm:mountain-born` | Goliath | Mountain Born | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `goliath-mpmm:stones-endurance` | Goliath | Stone's Endurance | 1 | REACTION + RESOURCE | pb | long_rest | card under Reaction + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `grung-oga:poison-immunity` | Grung | Poison Immunity | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `half-elf-mark-of-storm:storms-boon` | Mark of Storm | Storm's Boon | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `half-elf-phb:fey-ancestry` | Half-Elf | Fey Ancestry | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `half-orc-phb:relentless-endurance` | Half-Orc | Relentless Endurance | 1 | FREE / SPECIAL + RESOURCE | 1 | long_rest | card under Free / Special + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `half-orc-phb:savage-attacks` | Half-Orc | Savage Attacks | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | reminder only |
| `halfling-phb:lucky` | Halfling | Lucky | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | reminder only |
| `halfling-phb:brave` | Halfling | Brave | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `halfling-stout:stout-resilience` | Stout | Stout Resilience | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `harengon-mpmm:lucky-footwork` | Harengon | Lucky Footwork | 1 | REACTION | — | — | card under Reaction | — | Build (lineage card) | reminder only |
| `harengon-mpmm:rabbit-hop` | Harengon | Rabbit Hop | 1 | BONUS ACTION + RESOURCE | pb | long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `harengon-wbw:lucky-footwork` | Harengon | Lucky Footwork | 1 | REACTION | — | — | card under Reaction | — | Build (lineage card) | reminder only |
| `harengon-wbw:rabbit-hop` | Harengon | Rabbit Hop | 1 | BONUS ACTION + RESOURCE | pb | long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `hobgoblin-mpmm:fey-ancestry` | Hobgoblin | Fey Ancestry | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `hobgoblin-mpmm:fey-gift` | Hobgoblin | Fey Gift | 1 | BONUS ACTION + RESOURCE | pb | long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `hobgoblin-mpmm:fortune-from-the-many` | Hobgoblin | Fortune from the Many | 1 | FREE / SPECIAL + RESOURCE | pb | long_rest | card under Free / Special + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `hobgoblin-vgm:saving-face` | Hobgoblin | Saving Face | 1 | FREE / SPECIAL + RESOURCE | 1 | short_or_long_rest | card under Free / Special + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `human-mark-of-sentinel:vigilant-guardian` | Mark of Sentinel | Vigilant Guardian | 1 | REACTION + RESOURCE | 1 | long_rest | card under Reaction + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `kenku-mpmm:kenku-recall` | Kenku | Kenku Recall | 1 | RESOURCE | pb | long_rest | Ready to use (counter) | — | Build (lineage card) | partly automatic |
| `kobold-mpmm:draconic-cry` | Kobold | Draconic Cry | 1 | BONUS ACTION + RESOURCE | pb | long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `kobold-vgm:grovel-cower-and-beg` | Kobold | Grovel, Cower, and Beg | 1 | ACTION + RESOURCE | 1 | short_or_long_rest | card under Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `lizardfolk-mpmm:bite` | Lizardfolk | Bite | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `lizardfolk-mpmm:hungry-jaws` | Lizardfolk | Hungry Jaws | 1 | BONUS ACTION + RESOURCE | pb | long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `lizardfolk-vgm:bite` | Lizardfolk | Bite | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `lizardfolk-vgm:hungry-jaws` | Lizardfolk | Hungry Jaws | 1 | BONUS ACTION + RESOURCE | 1 | short_or_long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `locathah-lr:leviathan-will` | Locathah | Leviathan Will | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `minotaur-ggr:horns` | Minotaur | Horns | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `minotaur-ggr:goring-rush` | Minotaur | Goring Rush | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `minotaur-ggr:hammering-horns` | Minotaur | Hammering Horns | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `minotaur-mot:horns` | Minotaur | Horns | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `minotaur-mot:goring-rush` | Minotaur | Goring Rush | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `minotaur-mot:hammering-horns` | Minotaur | Hammering Horns | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `minotaur-mpmm:horns` | Minotaur | Horns | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `minotaur-mpmm:goring-rush` | Minotaur | Goring Rush | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `minotaur-mpmm:hammering-horns` | Minotaur | Hammering Horns | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `orc-egw:aggressive` | Orc | Aggressive | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `orc-erlw:aggressive` | Orc | Aggressive | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `orc-mpmm:adrenaline-rush` | Orc | Adrenaline Rush | 1 | BONUS ACTION + RESOURCE | pb | long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `orc-mpmm:relentless-endurance` | Orc | Relentless Endurance | 1 | FREE / SPECIAL + RESOURCE | 1 | long_rest | card under Free / Special + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `orc-vgm:aggressive` | Orc | Aggressive | 1 | BONUS ACTION | — | — | card under Bonus Action | — | Build (lineage card) | reminder only |
| `satyr-mot:ram` | Satyr | Ram | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `satyr-mot:magic-resistance` | Satyr | Magic Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `satyr-mpmm:ram` | Satyr | Ram | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `satyr-mpmm:magic-resistance` | Satyr | Magic Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `sea-elf-mpmm:child-of-the-sea` | Sea Elf | Child of the Sea | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `sea-elf-mpmm:fey-ancestry` | Sea Elf | Fey Ancestry | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `sea-elf-mtf:fey-ancestry` | Sea Elf | Fey Ancestry | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `shadar-kai-mpmm:blessing-of-the-raven-queen` | Shadar-Kai | Blessing of the Raven Queen | 1 | BONUS ACTION + RESOURCE | pb | long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `shadar-kai-mpmm:fey-ancestry` | Shadar-Kai | Fey Ancestry | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `shadar-kai-mpmm:necrotic-resistance` | Shadar-Kai | Necrotic Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `shadar-kai-mtf:fey-ancestry` | Shadar-Kai | Fey Ancestry | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `shadar-kai-mtf:necrotic-resistance` | Shadar-Kai | Necrotic Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `shadar-kai-mtf:blessing-of-the-raven-queen` | Shadar-Kai | Blessing of the Raven Queen | 1 | BONUS ACTION + RESOURCE | 1 | long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `shifter-erlw:shifting` | Shifter | Shifting | 1 | BONUS ACTION + RESOURCE | 1 | short_or_long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `shifter-mpmm:shifting` | Shifter | Shifting | 1 | BONUS ACTION + RESOURCE | pb | long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `shifter-swiftstride:shifting-feature` | Swiftstride | Shifting Feature | 1 | REACTION | — | — | card under Reaction | — | Build (lineage card) | reminder only |
| `shifter-wildhunt:mark-the-scent` | Wildhunt | Mark the Scent | 1 | BONUS ACTION + RESOURCE | 1 | short_or_long_rest | card under Bonus Action + counter in Ready to use | — | Build (lineage card) | partly automatic |
| `tabaxi-mpmm:cats-claws` | Tabaxi | Cat's Claws | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `tabaxi-vgm:cats-claws` | Tabaxi | Cat's Claws | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `tiefling-phb:hellish-resistance` | Tiefling | Hellish Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `tortle-mpmm:claws` | Tortle | Claws | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `tortle-mpmm:shell-defense` | Tortle | Shell Defense | 1 | ACTION | — | — | card under Action | — | Build (lineage card) | reminder only |
| `tortle-ttp:claws` | Tortle | Claws | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `tortle-ttp:shell-defense` | Tortle | Shell Defense | 1 | ACTION | — | — | card under Action | — | Build (lineage card) | reminder only |
| `triton-mpmm:guardian-of-the-depths` | Triton | Guardian of the Depths | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `triton-vgm:guardians-of-the-depths` | Triton | Guardians of the Depths | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |
| `verdan-ai:black-blood-healing` | Verdan | Black Blood Healing | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | reminder only |
| `yuan-ti-mpmm:magic-resistance` | Yuan-Ti | Magic Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `yuan-ti-mpmm:poison-resilience` | Yuan-Ti | Poison Resilience | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `yuan-ti-vgm:magic-resistance` | Yuan-Ti Pureblood | Magic Resistance | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | partly automatic |
| `yuan-ti-vgm:poison-immunity` | Yuan-Ti Pureblood | Poison Immunity | 1 | REMINDER ONLY | — | — | Passive and reminders | — | Build (lineage card) | automatic |

## Feats (all 408 official versions)

Columns: classification (first = primary), choices (kinds), spell grants, resource grants, Play / Spells visibility,
automation, how many backgrounds grant it, defect. Feat lifecycle, choice states and removal: `docs/FEAT_SYSTEM_AUDIT.md`.

| Feat version | Name | Rules | Status | Classification | Choices | Spell grants | Resources | Play | Spells | Automation | Granted by | Defect |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `aberrant-anatomy-2024` | Aberrant Anatomy | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `aberrant-dragonmark-2014` | Aberrant Dragonmark | 2014 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `aberrant-dragonmark-2024` | Aberrant Dragonmark | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `ability-score-improvement-2024` | Ability Score Improvement | 2024 | official | ABILITY + CHOICE-BASED | asi_points | 0 | 0 | — | — | automatic | — | — |
| `abjuration-adept-2024` | Abjuration Adept | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `acrobat-2014` | Acrobat (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `actor-2014` | Actor | 2014 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `actor-2024` | Actor | 2024 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `adept-of-the-black-robes-2014` | Adept of the Black Robes | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `adept-of-the-black-robes-ua-2014` | Adept of the Black Robes (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `adept-of-the-red-robes-2014` | Adept of the Red Robes | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `adept-of-the-red-robes-ua-2014` | Adept Of The Red Robes (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `adept-of-the-white-robes-2014` | Adept of the White Robes | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `adept-of-the-white-robes-ua-2014` | Adept Of The White Robes (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `agent-of-order-2014` | Agent of Order | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `agent-of-order-ua-2014` | Agent Of Order (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `alchemist-2014` | Alchemist (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `alert-2014` | Alert | 2014 | official | REMINDER ONLY | — | 0 | 0 | Passive and reminders | — | partly automatic | — | — |
| `alert-2024` | Alert | 2024 | official | PASSIVE (applied) | — | 0 | 0 | — | — | partly automatic | bg ×2 | — |
| `animal-handler-2014` | Animal Handler (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `arcane-artist-2024` | Arcane Artist | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `arcane-eloquence-2024` | Arcane Eloquence | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `arcane-infiltrator-2024` | Arcane Infiltrator | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `arcane-omens-2024` | Arcane Omens | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `arcane-overload-2024` | Arcane Overload | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `arcane-safeguard-2024` | Arcane Safeguard | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `arcane-undertaker-2024` | Arcane Undertaker | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `arcane-warrior-2024` | Arcane Warrior | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `arcanist-2014` | Arcanist (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `archery-2024` | Archery | 2024 | official | PASSIVE (applied) | — | 0 | 0 | — | — | automatic | — | — |
| `artificer-initiate-2014` | Artificer Initiate | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `athlete-2014` | Athlete | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `athlete-2024` | Athlete | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `baleful-scion-2014` | Baleful Scion | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `baleful-scion-ua-2014` | Baleful Scion (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `barbed-hide-2014` | Barbed Hide (UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `blade-mastery-2014` | Blade Mastery (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `blind-fighting-2024` | Blind Fighting | 2024 | official | PASSIVE (applied) | — | 0 | 0 | — | — | automatic | — | — |
| `bloodlust-2024` | Bloodlust | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `bomber-2024` | Bomber | 2024 | unverified | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-blazing-dawn-2024` | Boon of Blazing Dawn | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-bloodshed-2024` | Boon of Bloodshed | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-bountiful-health-2024` | Boon of Bountiful Health | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-combat-prowess-2024` | Boon of Combat Prowess | 2024 | official | FREE / SPECIAL + ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | card under Free / Special | — | partly automatic | — | — |
| `boon-of-communication-2024` | Boon of Communication | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-desperate-resilience-2024` | Boon of Desperate Resilience | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-dimensional-travel-2024` | Boon of Dimensional Travel | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-energy-resistance-2024` | Boon of Energy Resistance | 2024 | official | FREE / SPECIAL + ABILITY + CHOICE-BASED | ability_increase,damage_type | 0 | 0 | card under Free / Special | — | partly automatic | — | — |
| `boon-of-erupting-spellpower-2024` | Boon of Erupting Spellpower | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-exquisite-radiance-2024` | Boon of Exquisite Radiance | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-fate-2024` | Boon of Fate | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-fluid-forms-2024` | Boon of Fluid Forms | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-fortitude-2024` | Boon of Fortitude | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-fortune-s-favor-2024` | Boon of Fortune's Favor | 2024 | official | ABILITY + CHOICE-BASED + REMINDER ONLY | ability_increase | 0 | 0 | Passive and reminders | — | partly automatic | — | — |
| `boon-of-irresistible-offense-2024` | Boon of Irresistible Offense | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-looming-shadows-2024` | Boon of Looming Shadows | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-magic-school-mastery-2024` | Boon of Magic School Mastery | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-misty-escape-2024` | Boon of Misty Escape | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-poison-mastery-2024` | Boon of Poison Mastery | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-recovery-2024` | Boon of Recovery | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-revelry-2024` | Boon of Revelry | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-siberys-2024` | Boon of Siberys | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-skill-2024` | Boon of Skill | 2024 | official | CHOICE-BASED + PROFICIENCY | expertise | 0 | 0 | — | — | automatic | — | — |
| `boon-of-speed-2024` | Boon of Speed | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-spell-recall-2024` | Boon of Spell Recall | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-terror-2024` | Boon of Terror | 2024 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-the-bright-sun-2024` | Boon of the Bright Sun | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-the-furious-storm-2024` | Boon of the Furious Storm | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-the-iron-mind-2024` | Boon of the Iron Mind | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-the-night-spirit-2024` | Boon of the Night Spirit | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-the-soul-drinker-2024` | Boon of the Soul Drinker | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `boon-of-truesight-2024` | Boon of Truesight | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | automatic | — | — |
| `bountiful-luck-2014` | Bountiful Luck | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `brawny-2014` | Brawny (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `burglar-2014` | Burglar (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `cartomancer-2014` | Cartomancer | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `cartomancer-ua-2014` | Cartomancer (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `charger-2014` | Charger | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `charger-2024` | Charger | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `chef-2014` | Chef | 2014 | official | ABILITY + RESOURCE + CHOICE-BASED + PROFICIENCY | ability_increase | 0 | 1 | counter in Ready to use | — | partly automatic | — | — |
| `chef-2024` | Chef | 2024 | official | ABILITY + RESOURCE + CHOICE-BASED + PROFICIENCY | ability_increase | 0 | 1 | counter in Ready to use | — | partly automatic | — | — |
| `child-of-the-sun-2024` | Child of the Sun | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `cloying-mists-2024` | Cloying Mists | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `cohort-of-chaos-2014` | Cohort of Chaos | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `cohort-of-chaos-ua-2014` | Cohort of Chaos (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `cold-caster-2024` | Cold Caster | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `conjuration-adept-2024` | Conjuration Adept | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `crafter-2024` | Crafter | 2024 | official | CHOICE-BASED + PROFICIENCY | tool | 0 | 0 | — | — | partly automatic | bg ×1 | — |
| `critter-friend-2014` | Critter Friend (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `crossbow-expert-2014` | Crossbow Expert | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `crossbow-expert-2024` | Crossbow Expert | 2024 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `cruel-2014` | Cruel (HB) | 2014 | third_party | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `crusher-2014` | Crusher | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `crusher-2024` | Crusher | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `cult-of-the-dragon-initiate-2024` | Cult of the Dragon Initiate | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `defense-2024` | Defense | 2024 | official | PASSIVE (applied) | — | 0 | 0 | — | — | automatic | — | — |
| `defensive-duelist-2014` | Defensive Duelist | 2014 | official | REACTION | — | 0 | 0 | card under Reaction | — | reminder only | — | — |
| `defensive-duelist-2024` | Defensive Duelist | 2024 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `delicious-pain-2024` | Delicious Pain | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `diplomat-2014` | Diplomat (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `divination-adept-2024` | Divination Adept | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `divine-communications-ua-2014` | Divine Communications (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `divinely-favored-2014` | Divinely Favored | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `divinely-favored-ua-2014` | Divinely Favored (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `dragon-fear-2014` | Dragon Fear | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `dragon-hide-2014` | Dragon Hide | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `dragon-wings-2014` | Dragon Wings (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `dragonmark-ua-2014` | Dragonmark (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `dragonscarred-2024` | Dragonscarred | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `drow-high-magic-2014` | Drow High Magic | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `dual-wielder-2014` | Dual Wielder | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `dual-wielder-2024` | Dual Wielder | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `dueling-2024` | Dueling | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | partly automatic | — | — |
| `dungeon-delver-2014` | Dungeon Delver | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `durable-2014` | Durable | 2014 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `durable-2024` | Durable | 2024 | official | BONUS ACTION + ABILITY | — | 0 | 0 | card under Bonus Action | — | partly automatic | — | — |
| `dwarven-resilience-2014` | Dwarven Fortitude | 2014 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `echoing-soul-2024` | Echoing Soul | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `eldritch-adept-2014` | Eldritch Adept | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `elemental-adept-2014` | Elemental Adept | 2014 | official | CHOICE-BASED + REMINDER ONLY | damage_type | 0 | 0 | Passive and reminders | — | reminder only | — | — |
| `elemental-adept-2024` | Elemental Adept | 2024 | official | ABILITY + CHOICE-BASED + REMINDER ONLY | ability_increase,damage_type | 0 | 0 | Passive and reminders | — | partly automatic | — | — |
| `elemental-familiar-2024` | Elemental Familiar | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `elemental-touched-ua-2014` | Elemental Touched (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `elven-accuracy-2014` | Elven Accuracy | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `ember-of-the-fire-giant-2014` | Ember of the Fire Giant | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `ember-of-the-fire-giant-revised-ua-2014` | Ember Of The Fire Giant (Revised UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `ember-of-the-fire-giant-ua-2014` | Ember of the Fire Giant (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `emerald-enclave-fledgling-2024` | Emerald Enclave Fledgling | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `empathic-2014` | Empathic (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `enchantment-adept-2024` | Enchantment Adept | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `enclave-magic-2024` | Enclave Magic | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `everybodys-friend-2014` | Everybody's Friend (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `evocation-adept-2024` | Evocation Adept | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `fade-away-2014` | Fade Away | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `fairy-trickster-2024` | Fairy Trickster | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `familiar-friend-2024` | Familiar Friend | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `fell-handed-2014` | Fell Handed | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `fey-pact-2024` | Fey Pact | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `fey-sentinel-2024` | Fey Sentinel | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `fey-teleportation-2014` | Fey Teleportation | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `fey-tormentor-2024` | Fey Tormentor | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `fey-touched-2014` | Fey Touched | 2014 | official | SPELL-GRANTING + ABILITY + CHOICE-BASED | ability_increase,spell | 2 | 0 | — | yes | partly automatic | — | — |
| `fey-touched-2024` | Fey Touched | 2024 | official | SPELL-GRANTING + ABILITY + CHOICE-BASED | ability_increase,spell | 2 | 0 | — | yes | partly automatic | — | — |
| `fighting-initiate-2014` | Fighting Initiate | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `flail-mastery-2014` | Flail Mastery (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `flames-of-phlegethos-2014` | Flames Of Phlegethos | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `flash-recall-2014` | Flash Recall (HB) | 2014 | third_party | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `fury-of-the-frost-giant-2014` | Fury of the Frost Giant | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `fury-of-the-frost-giant-revised-ua-2014` | Fury Of The Frost Giant (Revised UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `fury-of-the-frost-giant-ua-2014` | Fury of the Frost Giant (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `gathered-whispers-2024` | Gathered Whispers | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `genie-magic-2024` | Genie Magic | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `gift-of-the-chromatic-dragon-2014` | Gift of the Chromatic Dragon | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `gift-of-the-gem-dragon-2014` | Gift of the Gem Dragon | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `gift-of-the-metallic-dragon-2014` | Gift of the Metallic Dragon | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `gourmand-2014` | Gourmand (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `grappler-2014` | Grappler | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `grappler-2024` | Grappler | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `great-weapon-fighting-2024` | Great Weapon Fighting | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `great-weapon-master-2014` | Great Weapon Master | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `great-weapon-master-2024` | Great Weapon Master | 2024 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `greater-aberrant-mark-2024` | Greater Aberrant Mark | 2024 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `greater-dragonmark-2014` | Greater Dragonmark (UA) | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `greater-mark-of-detection-2024` | Greater Mark of Detection | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `greater-mark-of-finding-2024` | Greater Mark of Finding | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `greater-mark-of-handling-2024` | Greater Mark of Handling | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `greater-mark-of-healing-2024` | Greater Mark of Healing | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `greater-mark-of-hospitality-2024` | Greater Mark of Hospitality | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `greater-mark-of-making-2024` | Greater Mark of Making | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `greater-mark-of-passage-2024` | Greater Mark of Passage | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `greater-mark-of-scribing-2024` | Greater Mark of Scribing | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `greater-mark-of-sentinel-2024` | Greater Mark of Sentinel | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `greater-mark-of-shadow-2024` | Greater Mark of Shadow | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `greater-mark-of-storm-2024` | Greater Mark of Storm | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `greater-mark-of-warding-2024` | Greater Mark of Warding | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `grudge-bearer-2014` | Grudge Bearer (UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `guile-of-the-cloud-giant-2014` | Guile of the Cloud Giant | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `guile-of-the-cloud-giant-revised-ua-2014` | Guile of The Cloud Giant (Revised UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `guile-of-the-cloud-giant-ua-2014` | Guile of the Cloud Giant (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `gunner-2014` | Gunner | 2014 | official | ABILITY + PROFICIENCY | — | 0 | 0 | — | — | partly automatic | — | — |
| `harper-agent-2024` | Harper Agent | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `harper-teamwork-2024` | Harper Teamwork | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `healer-2014` | Healer | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `healer-2024` | Healer | 2024 | official | REMINDER ONLY | — | 0 | 0 | Passive and reminders | — | reminder only | bg ×1 | — |
| `heavily-armored-2014` | Heavily Armored | 2014 | official | ABILITY + PROFICIENCY | — | 0 | 0 | — | — | automatic | — | — |
| `heavily-armored-2024` | Heavily Armored | 2024 | official | ABILITY + CHOICE-BASED + PROFICIENCY | ability_increase | 0 | 0 | — | — | automatic | — | — |
| `heavy-armor-master-2014` | Heavy Armor Master | 2014 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `heavy-armor-master-2024` | Heavy Armor Master | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `historian-2014` | Historian (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `human-determination-2014` | Human Determination (UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `illusion-adept-2024` | Illusion Adept | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `infernal-bulwark-2024` | Infernal Bulwark | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `infernal-constitution-2014` | Infernal Constitution | 2014 | official | ABILITY + REMINDER ONLY | — | 0 | 0 | Passive and reminders | — | partly automatic | — | — |
| `infernal-dragoon-2024` | Infernal Dragoon | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `infernal-pact-2024` | Infernal Pact | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `initiate-of-high-sorcery-2014` | Initiate of High Sorcery | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `initiate-of-high-sorcery-ua-2014` | Initiate of High Sorcery (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `inspiring-leader-2014` | Inspiring Leader | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `inspiring-leader-2024` | Inspiring Leader | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `interception-2024` | Interception | 2024 | official | REACTION | — | 0 | 0 | card under Reaction | — | reminder only | — | — |
| `investigator-2014` | Investigator (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `keen-mind-2014` | Keen Mind | 2014 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `keen-mind-2024` | Keen Mind | 2024 | official | BONUS ACTION + ABILITY + CHOICE-BASED + PROFICIENCY | skill | 0 | 0 | card under Bonus Action | — | partly automatic | — | — |
| `keenness-of-the-stone-giant-2014` | Keenness of the Stone Giant | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `keenness-of-the-stone-giant-revised-ua-2014` | Keenness of The Stone Giant (Revised UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `keenness-of-the-stone-giant-ua-2014` | Keenness of the Stone Giant (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `knight-of-the-crown-2014` | Knight of the Crown | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `knight-of-the-crown-ua-2014` | Knight Of The Crown (UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `knight-of-the-rose-2014` | Knight of the Rose | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `knight-of-the-rose-ua-2014` | Knight Of The Rose (UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `knight-of-the-sword-2014` | Knight of the Sword | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `knight-of-the-sword-ua-2014` | Knight Of The Sword (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `light-bringer-2024` | Light Bringer | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `lightly-armored-2014` | Lightly Armored | 2014 | official | ABILITY + CHOICE-BASED + PROFICIENCY | ability_increase | 0 | 0 | — | — | automatic | — | — |
| `lightly-armored-2024` | Lightly Armored | 2024 | official | ABILITY + CHOICE-BASED + PROFICIENCY | ability_increase | 0 | 0 | — | — | automatic | — | — |
| `linguist-2014` | Linguist | 2014 | official | ABILITY + CHOICE-BASED + PROFICIENCY | language | 0 | 0 | — | — | partly automatic | — | — |
| `living-shadow-2024` | Living Shadow | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `lordly-resolve-2024` | Lordly Resolve | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `lords-alliance-agent-2024` | Lords' Alliance Agent | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `love-bites-2024` | Love Bites | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `lucky-2014` | Lucky | 2014 | official | RESOURCE | — | 0 | 1 | counter in Ready to use | — | partly automatic | — | — |
| `lucky-2024` | Lucky | 2024 | official | RESOURCE | — | 0 | 1 | counter in Ready to use | — | partly automatic | bg ×2 | — |
| `mage-slayer-2014` | Mage Slayer | 2014 | official | REACTION | — | 0 | 0 | card under Reaction | — | reminder only | — | — |
| `mage-slayer-2024` | Mage Slayer | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `magic-connoisseur-2024` | Magic Connoisseur | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `magic-initiate-2014` | Magic Initiate | 2014 | official | SPELL-GRANTING + CHOICE-BASED | spell_list,spell,spell | 2 | 0 | — | yes | partly automatic | — | edit-choices path sent no list options (lineage / ASI / deferred) — **fixed** 20261109000100 |
| `magic-initiate-2024` | Magic Initiate | 2024 | official | SPELL-GRANTING + CHOICE-BASED | spell_list,spellcasting_ability,spell,spell | 2 | 0 | — | yes | partly automatic | bg ×3 | edit-choices path sent no list options (prod: 1 Variant Human grant stuck) — **fixed** 20261109000100 |
| `mark-of-detection-2024` | Mark of Detection | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `mark-of-finding-2024` | Mark of Finding | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `mark-of-handling-2024` | Mark of Handling | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `mark-of-healing-2024` | Mark of Healing | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `mark-of-hospitality-2024` | Mark of Hospitality | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `mark-of-making-2024` | Mark of Making | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `mark-of-passage-2024` | Mark of Passage | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `mark-of-scribing-2024` | Mark of Scribing | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `mark-of-sentinel-2024` | Mark of Sentinel | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `mark-of-shadow-2024` | Mark of Shadow | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `mark-of-storm-2024` | Mark of Storm | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `mark-of-warding-2024` | Mark of Warding | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `martial-adept-2014` | Martial Adept | 2014 | official | RESOURCE | — | 0 | 1 | counter in Ready to use | — | partly automatic | — | — |
| `martial-weapon-training-2024` | Martial Weapon Training | 2024 | official | ABILITY + CHOICE-BASED + PROFICIENCY | ability_increase | 0 | 0 | — | — | automatic | — | — |
| `master-of-disguise-2014` | Master Of Disguise (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `medic-2014` | Medic (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `medium-armor-master-2014` | Medium Armor Master | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `medium-armor-master-2024` | Medium Armor Master | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `menacing-2014` | Menacing (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `metabolic-control-2014` | Metabolic Control (UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `metamagic-adept-2014` | Metamagic Adept | 2014 | official | RESOURCE | — | 0 | 1 | counter in Ready to use | — | partly automatic | — | — |
| `mist-walker-2024` | Mist Walker | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `mobile-2014` | Mobile | 2014 | official | PASSIVE (applied) | — | 0 | 0 | — | — | partly automatic | — | — |
| `moderately-armored-2014` | Moderately Armored | 2014 | official | ABILITY + CHOICE-BASED + PROFICIENCY | ability_increase | 0 | 0 | — | — | automatic | — | — |
| `moderately-armored-2024` | Moderately Armored | 2024 | official | ABILITY + CHOICE-BASED + PROFICIENCY | ability_increase | 0 | 0 | — | — | automatic | — | — |
| `mounted-combatant-2014` | Mounted Combatant | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `mounted-combatant-2024` | Mounted Combatant | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `musician-2024` | Musician | 2024 | official | CHOICE-BASED + PROFICIENCY | tool | 0 | 0 | — | — | partly automatic | bg ×1 | — |
| `mystic-conflux-2014` | Mystic Conflux (HB) | 2014 | third_party | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `mythal-touched-2024` | Mythal Touched | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `naturalist-2014` | Naturalist (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `necromancy-adept-2024` | Necromancy Adept | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `observant-2014` | Observant | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `observant-2024` | Observant | 2024 | official | BONUS ACTION + ABILITY + CHOICE-BASED + PROFICIENCY | ability_increase,skill | 0 | 0 | card under Bonus Action | — | partly automatic | — | — |
| `orcish-aggression-2014` | Orcish Aggression (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `orcish-fury-2014` | Orcish Fury | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `order-s-resilience-2024` | Order's Resilience | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `otherworldly-familiar-2024` | Otherworldly Familiar | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `outlands-envoy-2014` | Outlands Envoy | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `outlands-envoy-ua-2014` | Outlands Envoy (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `outsized-might-ua-2014` | Outsized Might (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `pack-fighting-2024` | Pack Fighting | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `perceptive-2014` | Perceptive (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `performer-2014` | Performer (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `piercer-2014` | Piercer | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `piercer-2024` | Piercer | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `planar-wanderer-2014` | Planar Wanderer | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `planar-wanderer-ua-2014` | Planar Wanderer (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `poisoner-2014` | Poisoner | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `poisoner-2024` | Poisoner | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `polearm-master-2014` | Polearm Master | 2014 | official | PASSIVE (applied) | — | 0 | 0 | — | — | partly automatic | — | — |
| `polearm-master-2024` | Polearm Master | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `portal-jumper-2024` | Portal Jumper | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `potent-dragonmark-2024` | Potent Dragonmark | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `practiced-expert-2014` | Practiced Expert (UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `prodigy-2014` | Prodigy | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `prone-fighting-2024` | Prone Fighting | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `protection-2024` | Protection | 2024 | official | REACTION | — | 0 | 0 | card under Reaction | — | reminder only | — | — |
| `purple-dragon-commandant-2024` | Purple Dragon Commandant | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `purple-dragon-rook-2024` | Purple Dragon Rook | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `putrefy-2024` | Putrefy | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `quick-fingered-2014` | Quick Fingered (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `quicksmithing-2014` | Quicksmithing | 2014 | third_party | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `rebuke-2024` | Rebuke | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `remarkable-recovery-2014` | Remarkable Recovery (HB) | 2014 | third_party | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `resilient-2014` | Resilient | 2014 | official | ABILITY + CHOICE-BASED + PROFICIENCY | ability_increase | 0 | 0 | — | — | automatic | — | saving-throw proficiency labelled automated but not applied by the resolver — **open** (0 production characters) |
| `resilient-2024` | Resilient | 2024 | official | ABILITY + CHOICE-BASED + PROFICIENCY | ability_increase | 0 | 0 | — | — | automatic | — | saving-throw proficiency labelled automated but not applied by the resolver — **open** (0 production characters) |
| `revenant-blade-2014` | Revenant Blade | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `righteous-heritor-2014` | Righteous Heritor | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `righteous-heritor-ua-2014` | Righteous Heritor (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `ritual-caster-2014` | Ritual Caster | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `ritual-caster-2024` | Ritual Caster | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `rune-carver-adept-revised-ua-2014` | Rune Carver Adept (Revised UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `rune-carver-adept-ua-2014` | Rune Carver Adept (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `rune-carver-apprentice-revised-ua-2014` | Rune Carver Apprentice (Revised UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `rune-carver-apprentice-ua` | Rune Carver Apprentice | ua-2022 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | bg ×1 | — |
| `rune-carver-apprentice-ua-2014` | Rune Carver Apprentice (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `rune-shaper-2014` | Rune Shaper | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `savage-attacker-2014` | Savage Attacker | 2014 | official | FREE / SPECIAL | — | 0 | 0 | card under Free / Special | — | reminder only | — | — |
| `savage-attacker-2024` | Savage Attacker | 2024 | official | FREE / SPECIAL | — | 0 | 0 | card under Free / Special | — | reminder only | bg ×1 | — |
| `scion-of-elemental-air-ua-2014` | Scion Of Elemental Air (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `scion-of-elemental-earth-ua-2014` | Scion Of Elemental Earth (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `scion-of-elemental-fire-ua-2014` | Scion Of Elemental Fire (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `scion-of-elemental-water-ua-2014` | Scion Of Elemental Water (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `scion-of-the-outer-planes-2014` | Scion of the Outer Planes | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `scion-of-the-outer-planes-ua-2014` | Scion of the Outer Planes (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `second-chance-2014` | Second Chance | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `second-skin-2024` | Second Skin | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `sentinel-2014` | Sentinel | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `sentinel-2024` | Sentinel | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `servo-crafting-2014` | Servo Crafting | 2014 | third_party | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `shadow-pact-2024` | Shadow Pact | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `shadow-touched-2014` | Shadow Touched | 2014 | official | SPELL-GRANTING + ABILITY + CHOICE-BASED | ability_increase,spell | 2 | 0 | — | yes | partly automatic | — | — |
| `shadow-touched-2024` | Shadow Touched | 2024 | official | SPELL-GRANTING + ABILITY + CHOICE-BASED | ability_increase,spell | 2 | 0 | — | yes | partly automatic | — | — |
| `shadow-trapper-2024` | Shadow Trapper | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `shadow-weaver-2024` | Shadow Weaver | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `shadowmoor-hexer-2024` | Shadowmoor Hexer | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `sharp-eye-2024` | Sharp Eye | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `sharpshooter-2014` | Sharpshooter | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `sharpshooter-2024` | Sharpshooter | 2024 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `shield-master-2014` | Shield Master | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `shield-master-2024` | Shield Master | 2024 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `shield-training-2014` | Shield Training (UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `shifting-combatant-2024` | Shifting Combatant | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `silver-tongued-2014` | Silver Tongued (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `skill-expert-2014` | Skill Expert | 2014 | official | ABILITY + CHOICE-BASED + PROFICIENCY | ability_increase,skill,expertise | 0 | 0 | — | — | automatic | — | — |
| `skill-expert-2024` | Skill Expert | 2024 | official | ABILITY + CHOICE-BASED + PROFICIENCY | ability_increase,skill,expertise | 0 | 0 | — | — | automatic | — | — |
| `skilled-2014` | Skilled | 2014 | official | CHOICE-BASED + PROFICIENCY | skill_or_tool | 0 | 0 | — | — | automatic | — | — |
| `skilled-2024` | Skilled | 2024 | official | CHOICE-BASED + PROFICIENCY | skill_or_tool | 0 | 0 | — | — | automatic | bg ×3 | — |
| `skulker-2014` | Skulker | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `skulker-2024` | Skulker | 2024 | official | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `slasher-2014` | Slasher | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `slasher-2024` | Slasher | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `soothing-familiar-2024` | Soothing Familiar | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `soul-of-the-storm-giant-2014` | Soul of the Storm Giant | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `soul-of-the-storm-giant-revised-ua-2014` | Soul of The Storm Giant (Revised UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `soul-of-the-storm-giant-ua-2014` | Soul of the Storm Giant (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `spear-mastery-2014` | Spear Mastery (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `speedy-2024` | Speedy | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `spell-resistant-2024` | Spell Resistant | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `spell-sniper-2014` | Spell Sniper | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `spell-sniper-2024` | Spell Sniper | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `spell-subterfuge-2024` | Spell Subterfuge | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `spelldriver-2014` | Spelldriver (HB) | 2014 | third_party | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `spellfire-adept-2024` | Spellfire Adept | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `spellfire-spark-2024` | Spellfire Spark | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `squat-nimbleness-2014` | Squat Nimbleness | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `squire-of-solamnia-2014` | Squire of Solamnia | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `squire-of-solamnia-ua-2014` | Squire of Solamnia (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `stealthy-2014` | Stealthy (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `street-justice-2024` | Street Justice | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `strike-of-the-giants-2014` | Strike of the Giants | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `strike-of-the-giants-ua-2014` | Strike of the Giants (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `strixhaven-initiate-2014` | Strixhaven Initiate | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `strixhaven-mascot-2014` | Strixhaven Mascot | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `survivalist-2014` | Survivalist (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `survivor-2024` | Survivor | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `svirfneblin-magic-2014` | Svirfneblin Magic | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `symbiotic-being-2024` | Symbiotic Being | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `tactical-combatant-2024` | Tactical Combatant | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `tandem-tactician-2014` | Tandem Tactician (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `tavern-brawler-2014` | Tavern Brawler | 2014 | official | BONUS ACTION + ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | card under Bonus Action | — | partly automatic | — | — |
| `tavern-brawler-2024` | Tavern Brawler | 2024 | official | REMINDER ONLY | — | 0 | 0 | Passive and reminders | — | partly automatic | bg ×1 | — |
| `telekinetic-2014` | Telekinetic | 2014 | official | BONUS ACTION + SPELL-GRANTING + ABILITY + CHOICE-BASED | ability_increase | 1 | 0 | card under Bonus Action | yes | partly automatic | — | — |
| `telekinetic-2024` | Telekinetic | 2024 | official | BONUS ACTION + SPELL-GRANTING + ABILITY + CHOICE-BASED | ability_increase | 1 | 0 | card under Bonus Action | yes | partly automatic | — | — |
| `telepathic-2014` | Telepathic | 2014 | official | SPELL-GRANTING + ABILITY + CHOICE-BASED | ability_increase | 1 | 0 | — | yes | partly automatic | — | — |
| `telepathic-2024` | Telepathic | 2024 | official | SPELL-GRANTING + ABILITY + CHOICE-BASED | ability_increase | 1 | 0 | — | yes | partly automatic | — | — |
| `theologian-2014` | Theologian (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `thrown-arms-master-2014` | Thrown Arms Master (HB) | 2014 | third_party | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `thrown-weapon-fighting-2024` | Thrown Weapon Fighting | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | partly automatic | — | — |
| `tireless-reveler-2024` | Tireless Reveler | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `touch-of-death-2024` | Touch of Death | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `tough-2014` | Tough | 2014 | official | PASSIVE (applied) | — | 0 | 0 | — | — | automatic | — | — |
| `tough-2024` | Tough | 2024 | official | PASSIVE (applied) | — | 0 | 0 | — | — | automatic | bg ×1 | — |
| `tower-of-iron-will-2014` | Tower Of Iron Will (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `tracker-2014` | Tracker (UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `transmutation-adept-2024` | Transmutation Adept | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `transmuted-anatomy-2024` | Transmuted Anatomy | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `treacherous-allure-2024` | Treacherous Allure | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `two-weapon-fighting-2024` | Two Weapon Fighting | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `tyro-of-the-gauntlet-2024` | Tyro of the Gauntlet | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `unarmed-fighting-2024` | Unarmed Fighting | 2024 | official | REMINDER ONLY | — | 0 | 0 | Passive and reminders | — | partly automatic | — | — |
| `vampire-hunter-2024` | Vampire Hunter | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `vampire-s-plaything-2024` | Vampire's Plaything | 2024 | unverified | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `vampire-touched-2024` | Vampire Touched | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `vampiric-exultation-2014` | Vampiric Exultation | 2014 | third_party | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `vigor-of-the-hill-giant-2014` | Vigor of the Hill Giant | 2014 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `vigor-of-the-hill-giant-revised-ua-2014` | Vigor of The Hill Giant (Revised UA) | 2014 | playtest | ABILITY | — | 0 | 0 | — | — | partly automatic | — | — |
| `vigor-of-the-hill-giant-ua-2014` | Vigor of the Hill Giant (UA) | 2014 | playtest | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `vital-sacrifice-2014` | Vital Sacrifice (HB) | 2014 | third_party | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `war-caster-2014` | War Caster | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `war-caster-2024` | War Caster | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `warlike-familiar-2024` | Warlike Familiar | 2024 | unverified | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `watchers-2024` | Watchers | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `weapon-master-2014` | Weapon Master | 2014 | official | ABILITY + CHOICE-BASED + PROFICIENCY | ability_increase,weapon | 0 | 0 | — | — | automatic | — | — |
| `weapon-master-2024` | Weapon Master | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `wild-talent-2014` | Wild Talent (UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `wonder-maker-2014` | Wonder Maker (UA) | 2014 | playtest | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |
| `wood-elf-magic-2014` | Wood Elf Magic | 2014 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `zhentarim-ruffian-2024` | Zhentarim Ruffian | 2024 | official | NON-GAMEPLAY (descriptive) | — | 0 | 0 | — | — | reminder only | — | — |
| `zhentarim-tactics-2024` | Zhentarim Tactics | 2024 | official | ABILITY + CHOICE-BASED | ability_increase | 0 | 0 | — | — | partly automatic | — | — |

## Backgrounds (30 official versions)

Background features are NON-GAMEPLAY (Build). Ability choices, proficiencies and starting equipment are applied on Build;
a granted feat appears through its feat card (source "Background: …", change via Change Background).

| Background version | Name | Rules | Feat granted | Features | Feature automation | Play |
|---|---|---|---|---|---|---|
| `acolyte-2024` | Acolyte | 2024 | magic-initiate-2024(Cleric) | 0 | — | feat card (source: Background) |
| `anthropologist-toa` | Anthropologist | 2014 | — | 1 | informational | — |
| `archaeologist-toa` | Archaeologist | 2014 | — | 1 | informational | — |
| `artisan-2024` | Artisan | 2024 | crafter-2024 | 0 | — | feat card (source: Background) |
| `charlatan-2024` | Charlatan | 2024 | skilled-2024 | 0 | — | feat card (source: Background) |
| `criminal-2024` | Criminal | 2024 | alert-2024 | 0 | — | feat card (source: Background) |
| `entertainer-2024` | Entertainer | 2024 | musician-2024 | 0 | — | feat card (source: Background) |
| `faceless-bgda` | Faceless | 2014 | — | 1 | informational | — |
| `far-traveler-scag` | Far Traveler | 2014 | — | 1 | informational | — |
| `farmer-2024` | Farmer | 2024 | tough-2024 | 0 | — | feat card (source: Background) |
| `folk-hero-phb` | Folk Hero | 2014 | — | 1 | informational | — |
| `gambler-ai` | Gambler | 2014 | — | 1 | informational | — |
| `guard-2024` | Guard | 2024 | alert-2024 | 0 | — | feat card (source: Background) |
| `guide-2024` | Guide | 2024 | magic-initiate-2024(Druid) | 0 | — | feat card (source: Background) |
| `guild-artisan-phb` | Guild Artisan | 2014 | — | 1 | informational | — |
| `guild-merchant-phb` | Guild Artisan (variant: Guild Merchant) | 2014 | — | 1 | informational | — |
| `haunted-one-vrgr` | Haunted One | 2014 | — | 1 | informational | — |
| `hermit-2024` | Hermit | 2024 | healer-2024 | 0 | — | feat card (source: Background) |
| `investigator-vrgr` | Investigator | 2014 | — | 1 | informational | — |
| `merchant-2024` | Merchant | 2024 | lucky-2024 | 0 | — | feat card (source: Background) |
| `noble-2024` | Noble | 2024 | skilled-2024 | 0 | — | feat card (source: Background) |
| `outlander-phb` | Outlander | 2014 | — | 1 | informational | — |
| `rune-carver-ua` | Rune Carver | 2014 | rune-carver-apprentice-ua | 1 | informational | feat card (source: Background) |
| `sage-2024` | Sage | 2024 | magic-initiate-2024(Wizard) | 0 | — | feat card (source: Background) |
| `sailor-2024` | Sailor | 2024 | tavern-brawler-2024 | 0 | — | feat card (source: Background) |
| `scribe-2024` | Scribe | 2024 | skilled-2024 | 0 | — | feat card (source: Background) |
| `smuggler-gos` | Smuggler | 2014 | — | 1 | informational | — |
| `soldier-2024` | Soldier | 2024 | savage-attacker-2024 | 0 | — | feat card (source: Background) |
| `urchin-phb` | Urchin | 2014 | — | 1 | informational | — |
| `wayfarer-2024` | Wayfarer | 2024 | lucky-2024 | 0 | — | feat card (source: Background) |
