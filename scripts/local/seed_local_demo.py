"""Synthetic demo data for LOCAL manual testing (run by scripts/seed-local-demo.ps1). Safe to run again.

Accounts (LOCAL ONLY, synthetic): local-player@example.test and local-dm@example.test, password local-dev-password.
"Local Demo Campaign" (DM + player) and nine demo characters owned by the player; see docs/LOCAL_TEST_CHARACTERS.md.
Thirteen class showcase characters (one per official class, docs/CLASS_TEST_CHARACTERS.md) follow the same rules.
The ninth (Local Feature Tester) uses the SYNTHETIC test class of supabase/tests/fixtures/class_feature_engine_fixture.sql,
which scripts/seed-local-demo.ps1 loads first; it is test content, not an official class.
Four governance campaigns ("Local Relaxed / Standard / Strict / Custom Table", one character each) show campaign rules,
requests in every state, DM custom content, hidden data and feats; they are built only when the campaign does not exist.

Ownership and idempotency
  Every demo character has a stable id derived from its name (uuid5 of a fixed namespace). The seeder only ever touches
  characters with those ids:
    - missing        -> created and set up completely (items, proficiencies, lineage, classes, spells, slots, trackers)
    - already there  -> left exactly as it is (your manual changes are kept); reported as "exists"
    - --repair       -> the setup of existing demo characters is applied again (adds what is missing, re-equips,
                        resets the demo spell / slot state); still never touches any other character
  A character with a demo name but another id (made by hand, or by an older seeder) is reported and skipped.

Uses API_URL / ANON_KEY / SERVICE_ROLE_KEY of the LOCAL stack (environment, from `supabase status`). The service role
is used only for local setup steps a normal user cannot do (confirmed accounts, the campaign, fixed character ids, a
legacy row, a temporary slot); everything else goes through the same RPCs as the app with the player's own JWT.
Refuses any non-local URL. Never deletes anything.
"""
import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from urllib.parse import quote, urlparse

API = os.environ["API_URL"].rstrip("/")
ANON = os.environ["ANON_KEY"]
SERVICE = os.environ["SERVICE_ROLE_KEY"]
if urlparse(API).hostname not in ("127.0.0.1", "localhost"):
    sys.exit(f"refusing to run: {API} is not a local Supabase API")
REPAIR = "--repair" in sys.argv

PASSWORD = "local-dev-password"          # synthetic, local only
PLAYER, DM = "local-player@example.test", "local-dm@example.test"
CAMPAIGN = "Local Demo Campaign"
NS = uuid.UUID("6d1c7a52-5c1e-4c0e-9a51-7a3f0c0de001")   # fixed namespace -> stable ids
REP = {"Prefer": "return=representation"}
report = {"created": [], "exists": [], "skipped": [], "repaired": []}
# ---- class showcase characters (one per official class; docs/CLASS_TEST_CHARACTERS.md) --------------------------------------
# "showcase" blocks go through the class feature RPCs: subclass, optional replacements, choices, active states, Wild Shape,
# companions and infusions. Values are chosen to show each class's mechanics on the sheet.
SHOWCASE = [
    {"name": "Showcase Barbarian", "purpose": "Rage (active state), Unarmored Defense, Berserker", "class_name": "Barbarian", "level": 6,
     "race": "Half-Orc", "abilities": {"strength": 16, "dexterity": 14, "constitution": 16, "intelligence": 8, "wisdom": 12, "charisma": 10}, "hp": 61,
     "items": [("greataxe", 1, "main_hand"), ("handaxe", 2, None), ("javelin", 4, None), ("explorers-pack", 1, None)],
     "classes": [("barbarian-phb", 6)],
     "showcase": {"subclass": "barbarian-berserker-phb",
                  "choices": [("barbarian-phb-u1-proficiencies", "barbarian-proficiencies-phb-skills", ["athletics", "perception"]),
                              ("barbarian-phb-u4-asi", "barbarian-asi-phb-asi", ["str:1", "con:1"])],
                  "states": ["rage"]}},
    {"name": "Showcase Bard", "purpose": "Bardic Inspiration, Expertise, Jack of All Trades, Lore", "class_name": "Bard", "level": 6,
     "race": "Half-Elf", "abilities": {"strength": 8, "dexterity": 14, "constitution": 14, "intelligence": 12, "wisdom": 10, "charisma": 16}, "hp": 39,
     "items": [("rapier", 1, "main_hand"), ("leather", 1, "armor"), ("lute", 1, None)],
     "classes": [("bard-phb", 6)],
     "showcase": {"subclass": "bard-lore-phb",
                  "choices": [("bard-phb-u1-proficiencies", "bard-proficiencies-phb-skills", ["performance", "persuasion", "deception"]),
                              ("bard-phb-u1-proficiencies", "bard-proficiencies-phb-tools-choice", ["lute", "flute", "drum"]),
                              ("bard-phb-u3-expertise", "bard-expertise-phb-expertise", ["performance", "persuasion"]),
                              ("bard-lore-phb-u3-bonus-proficiencies", "bard-lore-bonus-proficiencies-phb-skills", ["arcana", "history", "insight"]),
                              ("bard-phb-u4-asi", "bard-asi-phb-asi", ["cha:2"]),
                              ("bard-lore-phb-u6-additional-magical-secrets", "bard-lore-additional-magical-secrets-phb-spells", ["fireball-phb", "counterspell-phb"])]}},
    {"name": "Showcase Cleric", "purpose": "domain spells, Channel Divinity, Disciple of Life", "class_name": "Cleric", "level": 5,
     "race": "Dwarf", "abilities": {"strength": 14, "dexterity": 10, "constitution": 14, "intelligence": 10, "wisdom": 16, "charisma": 12}, "hp": 38,
     "items": [("mace", 1, "main_hand"), ("chain-mail", 1, "armor"), ("shield", 1, "shield")],
     "classes": [("cleric-phb", 5)],
     "showcase": {"subclass": "cleric-life-phb",
                  "choices": [("cleric-phb-u1-proficiencies", "cleric-proficiencies-phb-skills", ["insight", "medicine"]),
                              ("cleric-phb-u4-asi", "cleric-asi-phb-asi", ["wis:2"])]}},
    {"name": "Showcase Druid", "purpose": "Wild Shape forms (Moon), companions", "class_name": "Druid", "level": 6,
     "race": "Wood Elf", "abilities": {"strength": 10, "dexterity": 14, "constitution": 14, "intelligence": 12, "wisdom": 16, "charisma": 10}, "hp": 45,
     "items": [("scimitar", 1, "main_hand"), ("leather", 1, "armor"), ("wooden-staff", 1, None)],
     "classes": [("druid-phb", 6)],
     "showcase": {"subclass": "druid-moon-phb",
                  "choices": [("druid-phb-u1-proficiencies", "druid-proficiencies-phb-skills", ["nature", "perception"]),
                              ("druid-phb-u4-asi", "druid-asi-phb-asi", ["wis:2"])],
                  "optional": ["druid-phb-u2-wild-companion"],
                  "companions": [("owl", "Pip", "Wild Companion")],
                  "transform": "brown-bear"}},
    {"name": "Showcase Fighter", "purpose": "Fighting Style, Second Wind, Action Surge, Champion crits", "class_name": "Fighter", "level": 5,
     "race": "Human", "abilities": {"strength": 16, "dexterity": 12, "constitution": 16, "intelligence": 10, "wisdom": 12, "charisma": 8}, "hp": 49,
     "items": [("longsword", 1, "main_hand"), ("chain-mail", 1, "armor"), ("shield", 1, "shield")],
     "classes": [("fighter-phb", 5)],
     "showcase": {"subclass": "fighter-champion-phb",
                  "choices": [("fighter-phb-u1-proficiencies", "fighter-proficiencies-phb-skills", ["athletics", "perception"]),
                              ("fighter-phb-u1-fighting-style", "fighter-fighting-style-phb-style", ["defense"]),
                              ("fighter-phb-u4-asi", "fighter-asi-phb-asi", ["str:2"])]}},
    {"name": "Showcase Monk", "purpose": "Martial Arts, Ki and Ki DC, Unarmored Movement, Open Hand", "class_name": "Monk", "level": 6,
     "race": "Human", "abilities": {"strength": 10, "dexterity": 16, "constitution": 12, "intelligence": 10, "wisdom": 16, "charisma": 8}, "hp": 39,
     "items": [("shortsword", 1, None), ("dart", 10, None)],
     "classes": [("monk-phb", 6)],
     "showcase": {"subclass": "monk-open-hand-phb",
                  "choices": [("monk-phb-u1-proficiencies", "monk-proficiencies-phb-skills", ["acrobatics", "insight"]),
                              ("monk-phb-u1-proficiencies", "monk-proficiencies-phb-tools-choice", ["flute"]),
                              ("monk-phb-u4-asi", "monk-asi-phb-asi", ["dex:1", "wis:1"])]}},
    {"name": "Showcase Paladin", "purpose": "Divine Smite (slot rider), Lay on Hands pool, Aura of Protection", "class_name": "Paladin", "level": 6,
     "race": "Human", "abilities": {"strength": 16, "dexterity": 10, "constitution": 14, "intelligence": 8, "wisdom": 10, "charisma": 16}, "hp": 52,
     "items": [("longsword", 1, "main_hand"), ("chain-mail", 1, "armor"), ("shield", 1, "shield")],
     "classes": [("paladin-phb", 6)],
     "showcase": {"subclass": "paladin-devotion-phb",
                  "choices": [("paladin-phb-u1-proficiencies", "paladin-proficiencies-phb-skills", ["athletics", "persuasion"]),
                              ("paladin-phb-u2-fighting-style", "paladin-fighting-style-phb-style", ["defense"]),
                              ("paladin-phb-u4-asi", "paladin-asi-phb-asi", ["str:1", "cha:1"])]}},
    {"name": "Showcase Ranger", "purpose": "Favored Foe and Deft Explorer (Tasha's replacements), Hunter", "class_name": "Ranger", "level": 5,
     "race": "Wood Elf", "abilities": {"strength": 12, "dexterity": 16, "constitution": 14, "intelligence": 10, "wisdom": 14, "charisma": 8}, "hp": 44,
     "items": [("longbow", 1, "main_hand"), ("arrows", 20, None), ("leather", 1, "armor")],
     "classes": [("ranger-phb", 5)],
     "showcase": {"subclass": "ranger-hunter-phb",
                  "optional": ["ranger-phb-u1-favored-foe", "ranger-phb-u1-deft-explorer"],
                  "choices": [("ranger-phb-u1-proficiencies", "ranger-proficiencies-phb-skills", ["stealth", "survival", "perception"]),
                              ("ranger-phb-u1-deft-explorer", "ranger-deft-explorer-tce-canny-skill", ["survival"]),
                              ("ranger-phb-u1-deft-explorer", "ranger-deft-explorer-tce-canny-languages", ["elvish", "sylvan"]),
                              ("ranger-phb-u2-fighting-style", "ranger-fighting-style-phb-style", ["archery"]),
                              ("ranger-hunter-phb-u3-hunters-prey", "ranger-hunter-hunters-prey-phb-prey", ["colossus-slayer"]),
                              ("ranger-phb-u4-asi", "ranger-asi-phb-asi", ["dex:2"])]}},
    {"name": "Showcase Rogue", "purpose": "Sneak Attack, Expertise, Cunning Action, Thief", "class_name": "Rogue", "level": 5,
     "race": "Halfling", "abilities": {"strength": 8, "dexterity": 16, "constitution": 14, "intelligence": 12, "wisdom": 12, "charisma": 10}, "hp": 38,
     "items": [("rapier", 1, "main_hand"), ("shortbow", 1, None), ("arrows", 20, None), ("leather", 1, "armor"), ("thieves-tools", 1, None)],
     "classes": [("rogue-phb", 5)],
     "showcase": {"subclass": "rogue-thief-phb",
                  "choices": [("rogue-phb-u1-proficiencies", "rogue-proficiencies-phb-skills", ["stealth", "acrobatics", "perception", "sleight_of_hand"]),
                              ("rogue-phb-u1-expertise", "rogue-expertise-phb-expertise", ["stealth", "thieves-tools"]),
                              ("rogue-phb-u4-asi", "rogue-asi-phb-asi", ["dex:2"])]}},
    {"name": "Showcase Sorcerer", "purpose": "Font of Magic, Metamagic, Draconic Resilience", "class_name": "Sorcerer", "level": 6,
     "race": "Dragonborn", "abilities": {"strength": 8, "dexterity": 14, "constitution": 14, "intelligence": 10, "wisdom": 12, "charisma": 16}, "hp": 45,
     "classes": [("sorcerer-phb", 6)],
     "showcase": {"subclass": "sorcerer-draconic-bloodline-phb",
                  "choices": [("sorcerer-phb-u1-proficiencies", "sorcerer-proficiencies-phb-skills", ["arcana", "persuasion"]),
                              ("sorcerer-draconic-bloodline-phb-u1-dragon-ancestor", "sorcerer-draconic-bloodline-dragon-ancestor-phb-ancestor", ["red"]),
                              ("sorcerer-phb-u3-metamagic", "sorcerer-metamagic-phb-options", ["quickened-spell", "twinned-spell"]),
                              ("sorcerer-phb-u4-asi", "sorcerer-asi-phb-asi", ["cha:2"])]}},
    {"name": "Showcase Warlock", "purpose": "Pact Magic, invocations, Pact of the Blade, Fiend", "class_name": "Warlock", "level": 5,
     "race": "Tiefling", "abilities": {"strength": 10, "dexterity": 14, "constitution": 14, "intelligence": 10, "wisdom": 12, "charisma": 16}, "hp": 38,
     "classes": [("warlock-phb", 5)],
     "showcase": {"subclass": "warlock-fiend-phb",
                  "choices": [("warlock-phb-u1-proficiencies", "warlock-proficiencies-phb-skills", ["arcana", "deception"]),
                              ("warlock-phb-u3-pact-boon", "warlock-pact-boon-phb-pact", ["pact-of-the-blade"]),
                              ("warlock-phb-u2-eldritch-invocations", "warlock-eldritch-invocations-phb-invocations",
                               ["devils-sight", "eldritch-smite", "thirsting-blade"]),
                              ("warlock-phb-u4-asi", "warlock-asi-phb-asi", ["cha:2"])]}},
    {"name": "Showcase Wizard", "purpose": "spellbook, Arcane Recovery, Evocation", "class_name": "Wizard", "level": 6,
     "race": "High Elf", "abilities": {"strength": 8, "dexterity": 14, "constitution": 14, "intelligence": 16, "wisdom": 12, "charisma": 10}, "hp": 38,
     "classes": [("wizard-phb", 6)],
     "showcase": {"subclass": "wizard-evocation-phb",
                  "choices": [("wizard-phb-u1-proficiencies", "wizard-proficiencies-phb-skills", ["arcana", "investigation"]),
                              ("wizard-phb-u4-asi", "wizard-asi-phb-asi", ["int:2"])]}},
    {"name": "Showcase Artificer", "purpose": "infusions on inventory items, Alchemist elixirs", "class_name": "Artificer", "level": 6,
     "race": "Gnome", "abilities": {"strength": 10, "dexterity": 14, "constitution": 14, "intelligence": 16, "wisdom": 12, "charisma": 8}, "hp": 45,
     "items": [("mace", 1, "main_hand"), ("scale-mail", 1, "armor"), ("rod", 1, None), ("crystal", 1, None)],
     "classes": [("artificer-tce", 6)],
     "showcase": {"subclass": "artificer-alchemist-tce",
                  "choices": [("artificer-tce-u1-proficiencies", "artificer-proficiencies-tce-skills", ["arcana", "investigation"]),
                              ("artificer-tce-u1-proficiencies", "artificer-proficiencies-tce-tools-choice", ["smiths-tools"]),
                              ("artificer-tce-u2-infuse-item", "artificer-infuse-item-tce-infusions",
                               ["enhanced-weapon", "enhanced-defense", "enhanced-arcane-focus", "homunculus-servant", "replicate-magic-item", "returning-weapon"]),
                              ("artificer-tce-u4-asi", "artificer-asi-tce-asi", ["int:2"])],
                  "infusions": [("enhanced-weapon", "mace"), ("enhanced-defense", "scale-mail"), ("homunculus-servant", None)]}},
]


# ---------------------------------------------------------------------------------------------------------------------------
# The demo characters. Expected values are documented in docs/LOCAL_TEST_CHARACTERS.md.
# ---------------------------------------------------------------------------------------------------------------------------
STD = {"strength": 10, "dexterity": 14, "constitution": 14, "intelligence": 10, "wisdom": 12, "charisma": 10}
FIXTURES = [
    {"name": "Local Hero", "purpose": "inventory, armor, AC, proficient weapons, Mountain Dwarf",
     "class_name": "Fighter", "level": 3, "abilities": {**STD, "strength": 15, "dexterity": 12}, "hp": 28,
     "proficiencies": ["simple-weapons", "martial-weapons", "light-armor", "medium-armor", "heavy-armor", "shields"],
     "items": [("longsword", 1, "main_hand"), ("chain-mail", 1, "armor"), ("shield", 1, "shield"), ("leather", 1, None),
               ("scale-mail", 1, None), ("mace", 1, None), ("shortbow", 1, None), ("arrows", 20, None),
               ("potion-of-healing-common", 2, None), ("ring-of-protection", 1, None), ("backpack", 1, None)],
     "legacy_item": "Old Lucky Coin", "private_homebrew": True,
     "lineage": ("dwarf-phb", "dwarf-mountain", {"dwarf-phb:tool": ["smiths-tools"]}),
     "classes": [("fighter-phb", 3)]},
    {"name": "Local Sidekick", "purpose": "proficiency, Strength and Stealth warnings; Custom Lineage with open choices",
     "class_name": "Rogue", "level": 3, "abilities": {**STD, "strength": 8, "dexterity": 16, "constitution": 12}, "hp": 20,
     "proficiencies": ["simple-weapons", "light-armor"],
     "items": [("chain-mail", 1, "armor"), ("longsword", 1, "main_hand"), ("leather", 1, None), ("dagger", 2, None)],
     "lineage": ("custom-tce", None, {"custom-tce:size": ["small"]}),
     "classes": [("rogue-phb", 3)]},
    {"name": "Local Spellcaster", "purpose": "spellbook: sources, DC / attack per source, always prepared, ritual, duplicate grant, item DC",
     "class_name": "Artificer", "level": 5, "abilities": {**STD, "intelligence": 16, "wisdom": 14, "charisma": 14}, "hp": 33,
     "lineage": ("tiefling-phb", "tiefling-asmodeus", {}),
     "classes": [("artificer-tce", 5)],
     "sources": [{"source_type": "manual", "label": "Manual Spellcasting Source", "casting_ability": "wis", "always_prepared_allowed": True},
                 {"source_type": "item", "label": "Wand of Fireballs (demo)", "fixed_dc": 15, "uses_spell_slots": False}],
     "spells": [("class:artificer", "fire-bolt-phb", True, False, False), ("class:artificer", "cure-wounds-phb", True, True, False),
                ("class:artificer", "alarm-phb", True, True, False), ("class:artificer", "faerie-fire-phb", True, True, False),
                ("Manual Spellcasting Source", "bless-phb", True, False, True),
                ("Manual Spellcasting Source", "thaumaturgy-phb", True, False, False),
                ("Wand of Fireballs (demo)", "fireball-phb", True, False, False)]},
    {"name": "Local Wizard", "purpose": "standard slots (single class), prepared limit, class spell level",
     "class_name": "Wizard", "level": 5, "race": "Human", "abilities": {**STD, "intelligence": 16}, "hp": 27,
     "classes": [("wizard-phb", 5)],
     "spells": [("class:wizard", "fire-bolt-phb", True, False, False), ("class:wizard", "mage-hand-phb", True, False, False),
                ("class:wizard", "light-phb", True, False, False), ("class:wizard", "magic-missile-phb", True, True, False),
                ("class:wizard", "shield-phb", True, True, False), ("class:wizard", "detect-magic-phb", True, False, False),
                ("class:wizard", "misty-step-phb", True, True, False), ("class:wizard", "fireball-phb", True, True, False)],
     "slots": [("standard", 1, 1)]},
    {"name": "Local Artificer", "purpose": "Artificer level 1: slots from level 1, INT, Artificer list",
     "class_name": "Artificer", "level": 1, "race": "Gnome", "abilities": {**STD, "intelligence": 16, "constitution": 14}, "hp": 10,
     "classes": [("artificer-tce", 1)],
     "spells": [("class:artificer", "guidance-phb", True, False, False), ("class:artificer", "mending-phb", True, False, False),
                ("class:artificer", "cure-wounds-phb", True, True, False), ("class:artificer", "sanctuary-phb", True, True, False)]},
    {"name": "Local Paladin", "purpose": "half caster: no slots at level 1, slots from level 2",
     "class_name": "Paladin", "level": 1, "race": "Human", "abilities": {**STD, "strength": 16, "charisma": 16, "dexterity": 10}, "hp": 12,
     "proficiencies": ["simple-weapons", "martial-weapons", "light-armor", "medium-armor", "heavy-armor", "shields"],
     "items": [("chain-mail", 1, "armor"), ("shield", 1, "shield"), ("longsword", 1, "main_hand")],
     "classes": [("paladin-phb", 1)]},
    {"name": "Local Warlock", "purpose": "Pact Magic, short / long rest, trackers, temporary slot",
     "class_name": "Warlock", "level": 5, "race": "Half-Elf", "abilities": {**STD, "charisma": 16}, "hp": 33,
     "classes": [("warlock-phb", 5)],
     "spells": [("class:warlock", "eldritch-blast-phb", True, False, False), ("class:warlock", "mage-hand-phb", True, False, False),
                ("class:warlock", "prestidigitation-phb", True, False, False), ("class:warlock", "hex-phb", True, False, False),
                ("class:warlock", "armor-of-agathys-phb", True, False, False), ("class:warlock", "misty-step-phb", True, False, False),
                ("class:warlock", "hunger-of-hadar-phb", True, False, False), ("class:warlock", "counterspell-phb", True, False, False)],
     "slots": [("pact", None, 1)],
     "trackers": [("Short-rest charm (demo)", 0, 2, "short"), ("Long-rest charm (demo)", 0, 1, "long")],
     "temporary_slots": [(1, "Demo spark (temporary)", "long_rest")]},
    {"name": "Local Multiclass", "purpose": "multiclass caster level, class spell level vs slots, standard + Pact pools",
     "class_name": "Wizard / Paladin / Warlock", "level": 9, "race": "Human",
     "abilities": {"strength": 14, "dexterity": 12, "constitution": 14, "intelligence": 16, "wisdom": 10, "charisma": 16}, "hp": 60,
     "proficiencies": ["simple-weapons", "martial-weapons", "light-armor", "medium-armor", "heavy-armor", "shields"],
     "classes": [("wizard-phb", 3), ("paladin-phb", 4), ("warlock-phb", 2)],
     "spells": [("class:wizard", "fire-bolt-phb", True, False, False), ("class:wizard", "magic-missile-phb", True, True, False),
                ("class:wizard", "shield-phb", True, True, False), ("class:wizard", "misty-step-phb", True, False, False),
                ("class:paladin", "bless-phb", True, True, False), ("class:warlock", "eldritch-blast-phb", True, False, False),
                ("class:warlock", "hex-phb", True, False, False)],
     "slots": [("standard", 1, 1), ("pact", None, 1)],
     "resources": [{"resource_key": "lay-on-hands-demo", "name": "Lay on Hands pool (demo resource)", "source_type": "class",
                    "source_id": "paladin-phb:lay-on-hands", "class": "paladin", "recharge": "long_rest",
                    "max_formula": {"terms": [{"of": "class_level", "multiplier": 5}]},
                    "notes": "Generic manual resource demo (the class feature Lay on Hands is the Paladin's own resource)."}]},
    {"name": "Local Feature Tester", "purpose": "class feature engine (SYNTHETIC test class): features, choices, subclass, resources",
     "class_name": "Engine Test Class", "level": 5, "race": "Human",
     "abilities": {"strength": 14, "dexterity": 14, "constitution": 12, "intelligence": 10, "wisdom": 16, "charisma": 12}, "hp": 38,
     "items": [("shortbow", 1, "main_hand"), ("arrows", 20, None)],
     "classes": [("engine-test-fixture", 5)],
     "features": {
         "subclass": "engine-test-path-fixture",
         "optional": ["et-u3-swift-reflexes"],
         "choices": [("et-u1-proficiencies", "et-skills", ["athletics", "perception"]),
                     ("et-u1-expertise", "et-expertise-pick", ["athletics", "perception"]),
                     ("et-u1-fighting-style", "et-style", ["archery"]),
                     ("et-u2-discipline", "et-discipline-pick", ["elements"]),
                     ("et-u2-discipline", "et-element", ["fire"]),
                     ("et-u2-discipline", "et-techniques", ["feint", "forbidden-technique"]),
                     ("et-u3-insight", "et-cantrip", ["light-phb"]),
                     ("et-u4-asi", "et-asi-pick", [])],          # left open on purpose: the incomplete-choice demo
         "resources": [("et-surge-uses", 1), ("et-focus-points", 2), ("et-reserve-uses", 1), ("et-inspiration-uses", 0),
                       ("et-burst-uses", 0)]}},
]
FIXTURES = FIXTURES + SHOWCASE
# ---- Wild Shape scenarios (docs/LOCAL_TEST_CHARACTERS.md, docs/WILD_SHAPE_UI.md) ---------------------------------------------
# Each one shows a different part of the 2014 Druid / Circle of the Moon rules; all state goes through the Wild Shape RPCs.
_DRUID = {"strength": 10, "dexterity": 14, "constitution": 14, "intelligence": 12, "wisdom": 16, "charisma": 10}
WILD_SHAPE = [
    {"name": "Wild Shape Druid 2", "purpose": "CR 1/4 limit, no swimming or flying forms, seen forms required", "class_name": "Druid", "level": 2,
     "abilities": _DRUID, "hp": 17, "classes": [("druid-phb", 2)],
     "wild_shape": {"seen": ["wolf", "cat", "riding-horse"], "favorites": ["wolf"], "settings": {"p_seen_mode": "enforce"}}},
    {"name": "Wild Shape Druid 4", "purpose": "CR 1/2, swimming forms unlocked, flying still locked", "class_name": "Druid", "level": 4,
     "abilities": _DRUID, "hp": 31, "classes": [("druid-phb", 4)], "subclass": "druid-land-phb",
     "wild_shape": {"seen": ["crocodile", "reef-shark", "giant-goat"], "favorites": ["crocodile"]}},
    {"name": "Wild Shape Druid 8", "purpose": "CR 1, flying forms unlocked; in Giant Eagle form", "class_name": "Druid", "level": 8,
     "abilities": _DRUID, "hp": 59, "classes": [("druid-phb", 8)], "subclass": "druid-land-phb",
     "wild_shape": {"seen": ["giant-eagle", "giant-spider", "brown-bear"], "transform": "giant-eagle"}},
    {"name": "Wild Shape Moon 2", "purpose": "Combat Wild Shape at level 2: CR 1, wounded Brown Bear form, slots for healing", "class_name": "Druid",
     "level": 2, "abilities": _DRUID, "hp": 17, "classes": [("druid-phb", 2)], "subclass": "druid-moon-phb",
     "wild_shape": {"seen": ["brown-bear", "dire-wolf"], "favorites": ["brown-bear", "dire-wolf"], "transform": "brown-bear", "damage": 15}},
    {"name": "Wild Shape Moon 6", "purpose": "Circle Forms CR 2, Giant Spider with Web recharge, concentration reminder", "class_name": "Druid",
     "level": 6, "abilities": _DRUID, "hp": 45, "classes": [("druid-phb", 6)], "subclass": "druid-moon-phb",
     "wild_shape": {"seen": ["giant-spider", "giant-constrictor-snake", "saber-toothed-tiger"], "favorites": ["giant-spider"],
                    "transform": "giant-spider"}},
    {"name": "Wild Shape Moon 10", "purpose": "Elemental Wild Shape (2 uses); CR 3; in Earth Elemental form", "class_name": "Druid", "level": 10,
     "abilities": _DRUID, "hp": 73, "classes": [("druid-phb", 10)], "subclass": "druid-moon-phb",
     "wild_shape": {"seen": ["killer-whale", "giant-scorpion"], "transform": "earth-elemental"}},
    {"name": "Wild Shape Druid 20", "purpose": "Beast Spells and Archdruid (unlimited Wild Shape)", "class_name": "Druid", "level": 20,
     "abilities": {**_DRUID, "wisdom": 20}, "hp": 143, "classes": [("druid-phb", 20)], "subclass": "druid-land-phb",
     "wild_shape": {"seen": ["brown-bear", "wolf"], "transform": "brown-bear"}},
    {"name": "Wild Shape Fighter Druid", "purpose": "multiclass Fighter 3 / Druid 4: limits from the Druid level, shield and armor merge (switch one to wear in the form)",
     "class_name": "Fighter", "level": 7, "abilities": {**_DRUID, "strength": 14}, "hp": 58, "classes": [("fighter-phb", 3), ("druid-phb", 4)],
     "items": [("shield", 1, "shield"), ("leather", 1, "armor")],
     "wild_shape": {"seen": ["black-bear", "wolf"], "favorites": ["black-bear"], "settings": {"p_default_equipment": "merge"}}},
]
FIXTURES = FIXTURES + WILD_SHAPE

# Backgrounds of the showcase characters (docs/BACKGROUNDS.md). Added only when the character has no background yet (never
# overwritten). 2024 versions use "scores already include the increases": the showcase scores above are the final values.
INCL = {"bonuses_included": True}
BACKGROUNDS = {
    "Showcase Barbarian": ("folk-hero-phb", None, {"tool": ["tool:smiths-tools"]}, {}),
    "Showcase Bard": ("entertainer-2024", {"mode": "plus2_plus1", "allocation": {"cha": 2, "dex": 1}}, {"tool": ["tool:lute"]}, INCL),
    "Showcase Cleric": ("acolyte-2024", {"mode": "plus2_plus1", "allocation": {"wis": 2, "int": 1}}, {}, INCL),
    "Showcase Druid": ("hermit-2024", {"mode": "plus2_plus1", "allocation": {"wis": 2, "con": 1}}, {}, INCL),
    "Showcase Fighter": ("soldier-2024", {"mode": "plus2_plus1", "allocation": {"str": 2, "con": 1}}, {"tool": ["tool:dice-set"]}, INCL),
    "Showcase Monk": ("wayfarer-2024", {"mode": "plus1_x3", "allocation": {"dex": 1, "wis": 1, "cha": 1}}, {}, INCL),
    "Showcase Paladin": ("noble-2024", {"mode": "plus2_plus1", "allocation": {"str": 2, "cha": 1}}, {"tool": ["tool:dragonchess-set"]}, INCL),
    "Showcase Ranger": ("outlander-phb", None, {"tool": ["tool:flute"], "language": ["language:sylvan"]}, {}),
    "Showcase Rogue": ("criminal-2024", {"mode": "plus2_plus1", "allocation": {"dex": 2, "int": 1}}, {}, INCL),
    "Showcase Sorcerer": ("far-traveler-scag", None, {"tool": ["tool:lute"], "language": ["language:draconic"]}, {}),
    "Showcase Warlock": ("haunted-one-vrgr", None, {"skills": ["skill:arcana", "skill:investigation"],
                                                    "languages": ["language:infernal", "language:abyssal"]}, {}),
    "Showcase Wizard": ("sage-2024", {"mode": "plus2_plus1", "allocation": {"int": 2, "con": 1}}, {}, INCL),
    "Showcase Artificer": ("artisan-2024", {"mode": "plus2_plus1", "allocation": {"int": 2, "dex": 1}}, {"tool": ["tool:smiths-tools"]}, INCL),
}


# ---------------------------------------------------------------------------------------------------------------------------
def call(method, path, body=None, token=SERVICE, key=SERVICE, headers=None):
    h = {"apikey": key, "Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    h.update(headers or {})
    req = urllib.request.Request(API + path, data=json.dumps(body).encode() if body is not None else None, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw


def ok(st, body, what):
    if st >= 300:
        sys.exit(f"FAILED  {what}: HTTP {st} {body}")


def account(email, name):
    st, body = call("POST", "/auth/v1/admin/users", {"email": email, "password": PASSWORD, "email_confirm": True,
                                                      "user_metadata": {"full_name": name}})
    created = st < 300
    st, body = call("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": PASSWORD}, token=ANON, key=ANON)
    if st != 200:
        sys.exit(f"FAILED  sign-in as {email}: {body}\n        (the account exists with a different password? reset-local.ps1 gives a clean start)")
    print(f"{'created ' if created else 'exists  '} account {email}")
    return body["user"]["id"], body["access_token"]


def fixture_id(name):
    return str(uuid.uuid5(NS, f"character:{name}"))


def main():
    player, jwt = account(PLAYER, "Local Player")
    dm, dm_jwt = account(DM, "Local DM")
    rpc = lambda fn, **a: call("POST", f"/rest/v1/rpc/{fn}", a, token=jwt, key=ANON)   # noqa: E731

    st, rows = call("GET", f"/rest/v1/campaigns?name=eq.{quote(CAMPAIGN)}&select=id")
    if rows:
        camp = rows[0]["id"]; print(f"exists   campaign {CAMPAIGN}")
    else:
        st, rows = call("POST", "/rest/v1/campaigns", {"name": CAMPAIGN, "description": "Synthetic local demo data", "created_by": dm}, headers=REP)
        ok(st, rows, "create campaign"); camp = rows[0]["id"]; print(f"created  campaign {CAMPAIGN}")
    st, body = call("POST", "/rest/v1/campaign_members", [{"campaign_id": camp, "user_id": dm, "role": "dm"},
                                                          {"campaign_id": camp, "user_id": player, "role": "player"}],
                    headers={"Prefer": "resolution=ignore-duplicates"})
    ok(st, body, "campaign members")

    # campaign homebrew item (stable request id: created once)
    st, hammer = rpc_as(dm_jwt, "create_homebrew_item", p_request_id=str(uuid.uuid5(NS, "campaign-homebrew")), p_definition={
        "name": "Local Campaign Warhammer", "kind_id": "weapon", "category_id": "martial-melee", "weight_lb": 2, "campaign_id": camp,
        "description": "Campaign homebrew (synthetic local demo)."},
        p_stats={"weapon": {"weapon_group": "martial", "damage_dice": "1d8", "damage_type_id": "bludgeoning", "properties": ["versatile"]}})
    ok(st, hammer, "campaign homebrew"); print(f"ready    campaign homebrew '{hammer['name']}'")

    for fx in FIXTURES:
        cid = fixture_id(fx["name"])
        st, rows = call("GET", f"/rest/v1/characters?id=eq.{cid}&select=id,name")
        if rows:
            if not REPAIR:
                report["exists"].append(fx["name"]); print(f"exists   character {fx['name']} (left unchanged; --repair re-applies the demo setup)")
                continue
            report["repaired"].append(fx["name"]); print(f"repair   character {fx['name']}")
        else:
            st, same = call("GET", f"/rest/v1/characters?owner_id=eq.{player}&name=eq.{quote(fx['name'])}&select=id")
            if same:
                report["skipped"].append(fx["name"])
                print(f"skipped  character {fx['name']}: a character with this name exists that the seeder did not create (left alone)")
                continue
            st, rows = call("POST", "/rest/v1/characters", {"id": cid, "owner_id": player, "name": fx["name"], "class_name": fx["class_name"],
                                                            "level": fx["level"], "campaign_id": camp, "race": fx.get("race", ""), "gp": 25,
                                                            "hp_max": fx["hp"], "hp_current": fx["hp"], **fx["abilities"]}, headers=REP)
            ok(st, rows, f"create {fx['name']}"); report["created"].append(fx["name"]); print(f"created  character {fx['name']}  ({fx['purpose']})")
        setup(fx, cid, player, jwt, rpc)

    # backgrounds: add-only (a character that already has a background keeps it; skipped characters are never touched)
    for name, (version, ability, choices, opts) in BACKGROUNDS.items():
        if name in report["skipped"]:
            continue
        st, bg = rpc("get_character_background", p_character=fixture_id(name))
        if st != 200:
            print(f"skipped  background {name}: {bg}")
            continue
        if bg.get("selected"):
            print(f"kept     background {name}: {bg['version']['name']} (already chosen)")
            continue
        st, body = rpc("set_character_background", p_character=fixture_id(name), p_version=version, p_ability=ability, p_choices=choices,
                       p_replacements=[], p_options=opts)
        ok(st, body, f"{name}: background {version}")
        print(f"background {name}: {body['version']['name']}{' (scores already include the increases)' if opts.get('bonuses_included') else ''}")

    governance_fixtures(player, jwt, dm, dm_jwt)

    print("\nSummary: created " + (", ".join(report["created"]) or "none") + "; already there " + (", ".join(report["exists"]) or "none")
          + "; repaired " + (", ".join(report["repaired"]) or "none") + "; skipped " + (", ".join(report["skipped"]) or "none") + ".")
    print(f"Local demo data is ready. Sign in as {PLAYER} (or the DM {DM}); password {PASSWORD} (synthetic, LOCAL ONLY).")
    print("What to test with each character: docs/LOCAL_TEST_CHARACTERS.md and docs/LOCAL_MANUAL_TESTING.md")


# ---- campaign governance, approvals, DM content and feats (docs/DM_GOVERNANCE.md, docs/LOCAL_TEST_CHARACTERS.md) ---------------
# One campaign per preset, each with one player character. Add-only: a campaign that already exists is left exactly as it is
# (its rules, requests and content may have been changed by hand); only missing campaigns are built.
GOV_CAMPAIGNS = [
    ("Local Relaxed Table", {"preset": "relaxed"}, "Relaxed Ranger", "ranger-phb", 4),
    ("Local Standard Table", {"preset": "standard"}, "Standard Fighter", "fighter-phb", 4),
    ("Local Strict Table", {"preset": "strict"}, "Strict Wizard", "wizard-phb", 3),
    ("Local Custom Table", {"preset": "custom", "custom_base": "standard",
                            "overrides": {"runtime.long_rest": "player_managed", "choice.feat": "dm_only"}}, "Custom Cleric", "cleric-phb", 4),
]


def governance_fixtures(player, jwt, dm, dm_jwt):
    as_player = lambda fn, **a: rpc_as(jwt, fn, **a)      # noqa: E731
    as_dm = lambda fn, **a: rpc_as(dm_jwt, fn, **a)       # noqa: E731
    for camp_name, settings, char_name, class_version, level in GOV_CAMPAIGNS:
        st, rows = call("GET", f"/rest/v1/campaigns?name=eq.{quote(camp_name)}&select=id")
        if rows:
            print(f"exists   campaign {camp_name} (left unchanged)")
            continue
        cid = fixture_id(char_name)
        st, rows = call("GET", f"/rest/v1/characters?id=eq.{cid}&select=id")
        if rows:
            print(f"skipped  campaign {camp_name}: {char_name} exists without its campaign (left alone)")
            continue
        st, rows = call("POST", "/rest/v1/campaigns", {"name": camp_name, "description": "Synthetic governance demo (local only)",
                                                         "created_by": dm}, headers=REP)
        ok(st, rows, f"create {camp_name}"); camp = rows[0]["id"]
        st, body = call("POST", "/rest/v1/campaign_members", [{"campaign_id": camp, "user_id": dm, "role": "dm"},
                                                              {"campaign_id": camp, "user_id": player, "role": "player"}],
                        headers={"Prefer": "resolution=ignore-duplicates"})
        ok(st, body, f"{camp_name}: members")
        # the character is built while the table is relaxed (character creation), then the DM picks the real rules
        ok(*as_dm("set_campaign_governance", p_campaign=camp, p_settings={"preset": "relaxed"}), f"{camp_name}: relaxed for setup")
        st, rows = call("POST", "/rest/v1/characters", {"id": cid, "owner_id": player, "name": char_name, "level": level, "campaign_id": camp,
                                                        "hp_max": 30, "hp_current": 30, "strength": 14, "dexterity": 14, "constitution": 14,
                                                        "intelligence": 14, "wisdom": 14, "charisma": 10}, headers=REP)
        ok(st, rows, f"create {char_name}")
        ok(*as_player("set_character_class", p_character=cid, p_class_version=class_version, p_level=level), f"{char_name}: class")
        ok(*as_dm("set_character_setup_complete", p_character=cid, p_complete=True), f"{char_name}: setup complete")
        ok(*as_dm("set_campaign_governance", p_campaign=camp, p_settings=settings), f"{camp_name}: rules")
        extra = []

        if settings["preset"] == "relaxed":
            # feats chosen freely: a 2024 feat and a 2014 feat (distinct versions, never merged)
            for version in ("alert-2024", "observant-2014"):
                st, body = as_player("assign_character_feat", p_character=cid, p_version=version, p_choices={}, p_source_type="direct",
                                     p_source_note="demo data", p_override_reason=None, p_notes=None)
                extra.append(f"feat {version}" if st < 300 else f"feat {version} left open ({body.get('message') if isinstance(body, dict) else body})")

        if settings["preset"] == "standard":
            # custom content: published spell, item, feat and Wild Shape beast; one draft; one archived
            def content(kind, fields, publish=True):
                st, c = as_dm("create_dm_content", p_type=kind, p_campaign=camp, p_fields=fields,
                              p_request_id=str(uuid.uuid5(NS, f"content:{camp_name}:{fields['name']}")))
                ok(st, c, f"content {fields['name']}")
                if publish:
                    st, c = as_dm("publish_dm_content", p_content=c["id"])
                    ok(st, c, f"publish {fields['name']}")
                return c
            content("spell", {"name": "Ember Lance", "player_text": "A spear of cinders.", "dm_notes": "Taught by the Ash Cult",
                              "definition": {"level": 1, "school": "evocation", "class_lists": ["wizard-spell-list", "sorcerer-spell-list"],
                                             "range": {"type": "distance", "distance": 60}, "components": {"v": True, "s": True},
                                             "attack_type": "ranged", "effects": [{"category": "damage", "dice": "2d8", "damage_types": ["fire"]}]}})
            ring = content("item", {"name": "Ring of the Ashen Oath", "player_text": "Warm iron.",
                                    "definition": {"item": {"kind_id": "gear", "is_magic": True, "rarity_id": "rare"},
                                                   "hidden": {"unidentified_name": "Heavy iron ring", "curse": "Bound to the wearer"}}})
            feat = content("feat", {"name": "Ashwalker", "ruleset": "2024",
                                    "definition": {"category": "general", "effects": [{"type": "speed_bonus", "value": 5, "label": "Ashwalker"}]}})
            content("creature", {"name": "Cinder Fox", "definition": {"size": "Small", "creature_type": "beast", "armor_class": 13, "hit_points": 9,
                                 "speed": {"walk": 40}, "abilities": {"str": 8, "dex": 16, "con": 12, "int": 4, "wis": 12, "cha": 6},
                                 "challenge_rating": 0.25,
                                 "actions": [{"kind": "melee", "name": "Bite", "reach": 5, "damage": [{"dice": "1d6+3", "type": "piercing"}],
                                              "attack_bonus": 5}]}})
            content("spell", {"name": "Unfinished Hex (draft)", "definition": {"level": 1, "school": "necromancy"}}, publish=False)
            old = content("item", {"name": "Retired Lantern", "definition": {"item": {"kind_id": "gear"}}})
            ok(*as_dm("archive_dm_content", p_content=old["id"], p_reason="demo: retired"), "archive Retired Lantern")
            ok(*as_dm("dm_assign_content", p_content=feat["id"], p_characters=[cid], p_mode="campaign_reward", p_options={}), "reward Ashwalker")
            ok(*as_dm("dm_assign_content", p_content=ring["id"], p_characters=[cid], p_mode="inventory", p_options={"identified": False}), "give ring")
            extra.append("content: Ember Lance, Ring of the Ashen Oath (unidentified), Ashwalker, Cinder Fox, a draft, an archived item")

            # requests in every state the DM review handles
            def request(title, ops, submit=True):
                st, r = as_player("create_change_request", p_character=cid, p_ops=ops, p_title=title, p_reason="demo data",
                                  p_player_note=None, p_submit=submit, p_idempotency_key=str(uuid.uuid5(NS, f"request:{camp_name}:{title}")))
                ok(st, r, f"request {title}")
                return r

            def feat_op(version):
                return [{"op": "assign_character_feat", "args": {"p_version": version, "p_choices": {}}}]

            level_up = [{"op": "set_character_class", "args": {"p_class_version": class_version, "p_level": level + 1}}]
            r = request("Approved: Alert", feat_op("alert-2024"))
            ok(*as_dm("review_change_request", p_request=r["id"], p_decision="approve", p_note="Welcome to the watch"), "approve Alert")
            r = request("Rejected: Lucky", feat_op("lucky-2024"))
            ok(*as_dm("review_change_request", p_request=r["id"], p_decision="reject", p_note="Not in this campaign"), "reject Lucky")
            r = request("Returned: next level", level_up)
            ok(*as_dm("review_change_request", p_request=r["id"], p_decision="return", p_note="After the next session"), "return level up")
            r = request("Cancelled: Skilled", feat_op("skilled-2024"))
            ok(*as_player("cancel_change_request", p_request=r["id"], p_reason="changed my mind"), "cancel Skilled")
            # a request that goes stale: the DM corrects the character after it was sent
            request("Stale: Observant", [{"op": "assign_character_feat", "args": {"p_version": "observant-2024", "p_choices": {}}}])
            ok(*as_dm("update_character_build", p_character=cid, p_patch={"hp_max": 32}), "DM correction")
            # sent after every change above, so it is current (not stale) when the DM opens it
            request("Pending: Tough", feat_op("tough-2024"))
            request("Draft: Savage Attacker", feat_op("savage-attacker-2024"), submit=False)
            ok(*as_dm("save_dm_note", p_character=cid, p_title="Secret", p_body="Their sister leads the Ash Cult."), "DM note")
            ok(*as_dm("apply_character_condition", p_character=cid, p_version=None, p_name="Ash curse (hidden)", p_hidden=True, p_expires=None,
                      p_note="Reveal when they sleep in the ruins"), "hidden condition")
            extra.append("requests: pending, approved, rejected, returned, cancelled, draft, stale; a DM note; a hidden condition")

        if settings["preset"] == "strict":
            st, r = as_player("create_change_request", p_character=cid, p_title="Pending: next level",
                              p_ops=[{"op": "set_character_class", "args": {"p_class_version": class_version, "p_level": level + 1}}],
                              p_reason="demo data", p_player_note=None, p_submit=True,
                              p_idempotency_key=str(uuid.uuid5(NS, f"request:{camp_name}:level")))
            ok(st, r, "strict request")
            ok(*as_dm("set_character_lock", p_character=cid, p_mode="progression_locked", p_reason="Between sessions"), "lock")
            extra.append("a pending level-up request; progression locked")
        print(f"created  campaign {camp_name} ({settings['preset']}) with {char_name}" + (f": {'; '.join(extra)}" if extra else ""))


def rpc_as(token, fn, **args):
    return call("POST", f"/rest/v1/rpc/{fn}", args, token=token, key=ANON)


def setup(fx, cid, player, jwt, rpc):
    name = fx["name"]
    st, invs = call("GET", f"/rest/v1/inventories?character_id=eq.{cid}&select=id")
    ok(st, invs, f"{name} inventory")
    inv = invs[0]["id"]

    def row_of(item_id):
        st, rows = call("GET", f"/rest/v1/inventory_items?inventory_id=eq.{inv}&item_id=eq.{quote(item_id)}&select=id")
        return rows[0]["id"] if rows else None

    for group in fx.get("proficiencies", []):
        st, body = rpc("set_character_proficiency", p_character=cid, p_group=group, p_enabled=True)
        ok(st, body, f"{name}: proficiency {group}")
    for item_id, qty, slot in fx.get("items", []):
        row = row_of(item_id)
        if not row:
            st, body = rpc("add_inventory_item", p_inventory=inv, p_item=item_id, p_quantity=qty)
            ok(st, body, f"{name}: add {item_id}")
            row = row_of(item_id)
        if slot:
            st, eq = call("GET", f"/rest/v1/character_equipment?inventory_item_id=eq.{row}&select=slot_id")
            if not eq:
                st, body = rpc("equip_item", p_item=row, p_slot=slot, p_replace=True)
                ok(st, body, f"{name}: equip {item_id}")
    if fx.get("items"):
        print(f"ready    {name}: {len(fx['items'])} catalog items, {sum(1 for x in fx['items'] if x[2])} equipped")
    if fx.get("legacy_item"):
        st, rows = call("GET", f"/rest/v1/inventory_items?character_id=eq.{cid}&item_id=is.null&name=eq.{quote(fx['legacy_item'])}&select=id")
        if not rows:   # an old free-text row, as written by the app before the item catalog existed (users can no longer create these)
            st, body = call("POST", "/rest/v1/inventory_items", {"character_id": cid, "name": fx["legacy_item"], "quantity": 1, "weight": 0,
                                                                 "description": "Legacy free-text item (synthetic)"})
            ok(st, body, "legacy item")
        print(f"ready    {name}: legacy item '{fx['legacy_item']}'")
    if fx.get("private_homebrew"):
        st, blade = rpc("create_homebrew_item", p_request_id=str(uuid.uuid5(NS, "private-homebrew")), p_definition={
            "name": "Local Moonblade", "kind_id": "weapon", "category_id": "martial-melee", "weight_lb": 3,
            "description": "Private homebrew (synthetic local demo)."},
            p_stats={"weapon": {"weapon_group": "martial", "damage_dice": "1d8", "damage_type_id": "slashing", "properties": ["finesse"]}})
        ok(st, blade, "private homebrew")
        if not row_of(blade["id"]):
            st, body = rpc("add_inventory_item", p_inventory=inv, p_item=blade["id"], p_quantity=1)
            ok(st, body, "add private homebrew")
        print(f"ready    {name}: private homebrew '{blade['name']}'")

    if fx.get("lineage"):
        version, sub, choices = fx["lineage"]
        st, rows = call("GET", f"/rest/v1/character_lineages?character_id=eq.{cid}&select=version_id")
        if not rows:
            st, body = rpc("set_character_lineage", p_character=cid, p_version=version, p_subversion=sub, p_choices=choices)
            ok(st, body, f"{name}: lineage"); print(f"lineage  {name}: {sub or version} ({body['unresolved']} open choices)")

    st, have = call("GET", f"/rest/v1/character_classes?character_id=eq.{cid}&select=class_version_id")
    have = {r["class_version_id"] for r in have or []}
    for version, level in fx.get("classes", []):
        if version not in have:
            st, body = rpc("set_character_class", p_character=cid, p_class_version=version, p_level=level)
            ok(st, body, f"{name}: class {version}")
    if fx.get("classes"):
        print(f"classes  {name}: " + " / ".join(f"{v} {l}" for v, l in fx["classes"]))

    st, summary = rpc("get_character_class_summary", p_character=cid)
    ok(st, summary, f"{name}: class summary")
    class_src = {k["class_id"]: k["spellcasting"]["source_id"] for k in summary["classes"] if k.get("spellcasting")}
    st, book = rpc("get_character_spellbook", p_character=cid)
    ok(st, book, f"{name}: spellbook")
    labels = {s["label"]: s["id"] for s in book["sources"] if s.get("id")}
    for src in fx.get("sources", []):
        if src["label"] not in labels:
            st, body = rpc("save_character_spellcasting_source", p_character=cid, p_source=src)
            ok(st, body, f"{name}: source {src['label']}"); labels[src["label"]] = body["id"]
    for ref, spell, known, prepared, always in fx.get("spells", []):
        source = class_src[ref.split(":")[1]] if ref.startswith("class:") else labels[ref]
        st, body = rpc("set_character_spell", p_character=cid, p_source=source, p_spell_version=spell,
                       p_known=known, p_prepared=prepared, p_always_prepared=always)
        ok(st, body, f"{name}: spell {spell}")
    if fx.get("spells"):
        print(f"spells   {name}: {len(fx['spells'])} catalog spells")

    for pool, level, used in fx.get("slots", []):
        st, body = rpc("set_spell_slot_state", p_character=cid, p_pool=pool, p_slot_level=level, p_expended=used, p_reason="demo data")
        ok(st, body, f"{name}: slot state {pool}")
    if fx.get("slots"):
        print(f"slots    {name}: " + ", ".join(f"{p}{'' if l is None else ' L' + str(l)} {u} used" for p, l, u in fx["slots"]))

    for tname, current, mx, reset in fx.get("trackers", []):
        st, rows = call("GET", f"/rest/v1/feature_trackers?character_id=eq.{cid}&name=eq.{quote(tname)}&select=id")
        if rows:
            st, body = call("PATCH", f"/rest/v1/feature_trackers?id=eq.{rows[0]['id']}", {"current": current, "max": mx, "reset_on": reset})
        else:
            st, body = call("POST", "/rest/v1/feature_trackers", {"character_id": cid, "name": tname, "current": current, "max": mx, "reset_on": reset})
        ok(st, body, f"{name}: tracker {tname}")
    for level, label, expires in fx.get("temporary_slots", []):
        st, rows = call("GET", f"/rest/v1/character_temporary_spell_slots?character_id=eq.{cid}&source_label=eq.{quote(label)}&select=id")
        if not rows:
            st, body = call("POST", "/rest/v1/character_temporary_spell_slots",
                            {"character_id": cid, "slot_level": level, "source_label": label, "source_type": "manual", "expires_on": expires})
            ok(st, body, f"{name}: temporary slot")
    for res in fx.get("resources", []):
        st, rows = call("GET", f"/rest/v1/character_resources?character_id=eq.{cid}&resource_key=eq.{res['resource_key']}&select=id")
        if not rows:
            row = next(k["id"] for k in summary["classes"] if k["class_id"] == res["class"])
            st, body = rpc("save_character_resource", p_character=cid, p_resource={**{k: v for k, v in res.items() if k != "class"},
                                                                                      "character_class_id": row})
            ok(st, body, f"{name}: resource {res['resource_key']}")
    if fx.get("trackers") or fx.get("temporary_slots") or fx.get("resources"):
        print(f"ready    {name}: trackers / temporary slots / resources")

    feat = fx.get("features")
    if feat:   # class feature engine demo: subclass, optional replacement, choices, resource state (all through the RPCs)
        st, summary = rpc("get_character_class_summary", p_character=cid)
        row = summary["classes"][0]
        if row["level"] != fx["classes"][0][1] or row.get("subclass_version_id") != feat["subclass"]:
            st, body = rpc("set_character_class", p_character=cid, p_class_version=row["class_version_id"], p_level=fx["classes"][0][1],
                           p_subclass_version=feat["subclass"], p_character_class=row["id"])
            ok(st, body, f"{name}: subclass")
        for unlock in feat["optional"]:
            st, body = rpc("set_character_optional_feature", p_character=cid, p_character_class=row["id"], p_unlock=unlock, p_enabled=True)
            ok(st, body, f"{name}: optional feature {unlock}")
        for unlock, choice, values in feat["choices"]:
            st, body = rpc("set_character_feature_choice", p_character=cid, p_character_class=row["id"], p_unlock=unlock, p_choice=choice,
                           p_values=values, p_manual_status=None)
            ok(st, body, f"{name}: choice {choice}")
        for res_id, used in feat["resources"]:
            st, body = rpc("set_character_resource_state", p_character=cid, p_resource_key=f"f:{row['id']}:{res_id}", p_expended=used,
                           p_reason="demo data", p_temporary_bonus=0, p_max_adjustment=0)
            ok(st, body, f"{name}: resource {res_id}")
        print(f"features {name}: subclass, 1 replacement, {len(feat['choices'])} choices (ASI left open), {len(feat['resources'])} resources")

    sc = fx.get("showcase")
    if sc:     # class showcase: everything through the same RPCs as the app (player's JWT)
        st, summary = rpc("get_character_class_summary", p_character=cid)
        row = summary["classes"][0]
        if row.get("subclass_version_id") != sc["subclass"]:
            st, body = rpc("set_character_class", p_character=cid, p_class_version=row["class_version_id"], p_level=row["level"],
                           p_subclass_version=sc["subclass"], p_character_class=row["id"])
            ok(st, body, f"{name}: subclass")
        for unlock in sc.get("optional", []):
            st, body = rpc("set_character_optional_feature", p_character=cid, p_character_class=row["id"], p_unlock=unlock, p_enabled=True)
            ok(st, body, f"{name}: optional feature {unlock}")
        for unlock, choice, values in sc.get("choices", []):
            st, body = rpc("set_character_feature_choice", p_character=cid, p_character_class=row["id"], p_unlock=unlock, p_choice=choice,
                           p_values=values, p_manual_status=None)
            ok(st, body, f"{name}: choice {choice}")
        st, states = rpc("get_character_states", p_character=cid)
        ok(st, states, f"{name}: states")
        for key in sc.get("states", []):
            if not any(s["key"] == key and s["active"] for s in states["states"]):
                st, body = rpc("start_character_state", p_character=cid, p_state=key, p_spend=False)
                ok(st, body, f"{name}: start {key}")
        st, comps = call("GET", f"/rest/v1/character_companions?character_id=eq.{cid}&select=name")
        for creature, cname, source in sc.get("companions", []):
            if not any(c["name"] == cname for c in comps or []):
                st, body = rpc("add_character_companion", p_character=cid, p_creature=creature, p_name=cname, p_source=source)
                ok(st, body, f"{name}: companion {cname}")
        if sc.get("transform"):
            st, tf = rpc("get_character_transformation", p_character=cid)
            ok(st, tf, f"{name}: transformation")
            if not tf.get("active"):
                st, body = rpc("start_transformation", p_character=cid, p_creature=sc["transform"])
                ok(st, body, f"{name}: Wild Shape {sc['transform']}")
        if sc.get("infusions"):
            st, inf = rpc("get_character_infusions", p_character=cid)
            ok(st, inf, f"{name}: infusions")
            have = {a["infusion_id"] for a in inf["active"]}
            for infusion, item in sc["infusions"]:
                if infusion in have:
                    continue
                st, body = rpc("apply_infusion", p_character=cid, p_infusion=infusion, p_inventory_item=row_of(item) if item else None,
                               p_replicate_item=None)
                ok(st, body, f"{name}: infusion {infusion}")
        print(f"showcase {name}: {sc['subclass']}, {len(sc.get('choices', []))} choices"
              + (f", states {', '.join(sc['states'])}" if sc.get("states") else "")
              + (f", form {sc['transform']}" if sc.get("transform") else "")
              + (f", {len(sc['infusions'])} infusions" if sc.get("infusions") else ""))

    ws = fx.get("wild_shape")
    if ws:     # Wild Shape scenario: subclass, seen forms, favorites, settings, current form, damage (add-only: an existing form is kept)
        st, summary = rpc("get_character_class_summary", p_character=cid)
        druid = next(k for k in summary["classes"] if k["class_id"] == "druid")
        if fx.get("subclass") and druid.get("subclass_version_id") != fx["subclass"]:
            st, body = rpc("set_character_class", p_character=cid, p_class_version=druid["class_version_id"], p_level=druid["level"],
                           p_subclass_version=fx["subclass"], p_character_class=druid["id"])
            ok(st, body, f"{name}: subclass")
        st, body = rpc("set_seen_forms", p_character=cid, p_creatures=ws.get("seen", []), p_seen=True, p_source="seen", p_note="demo data")
        ok(st, body, f"{name}: seen forms")
        for creature in ws.get("favorites", []):
            st, body = rpc("set_form_favorite", p_character=cid, p_creature=creature, p_favorite=True)
            ok(st, body, f"{name}: favorite {creature}")
        if ws.get("settings"):
            st, body = rpc("set_wild_shape_settings", p_character=cid, **{"p_seen_mode": None, "p_default_equipment": None, "p_confirm_lethal": None,
                                                                          **ws["settings"]})
            ok(st, body, f"{name}: Wild Shape settings")
        st, tf = rpc("get_character_transformation", p_character=cid)
        ok(st, tf, f"{name}: transformation")
        if ws.get("transform") and not tf.get("active"):
            st, body = rpc("start_transformation", p_character=cid, p_creature=ws["transform"], p_options={})
            ok(st, body, f"{name}: Wild Shape {ws['transform']}")
            if ws.get("damage"):
                st, body = rpc("damage_active_transformation", p_character=cid, p_amount=ws["damage"], p_note="demo data")
                ok(st, body, f"{name}: form damage")
        print(f"wildshape {name}: {len(ws.get('seen', []))} seen, {len(ws.get('favorites', []))} favorites"
              + (f", form {ws['transform']}" if ws.get("transform") else ", normal form"))


if __name__ == "__main__":
    main()
