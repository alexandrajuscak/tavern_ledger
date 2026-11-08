# Icon asset inventory

Generated 2026-10-31 by `scripts/local/icon_audit.py`; machine-readable report: `data/reports/icon_audit.json`.
Registry: `js/icon-registry.js` (generated from `assets/icons` by `scripts/local/build_icon_registry.py`). Rules:
`docs/UI_ICON_SYSTEM.md`.

## Summary

| Measure | Count |
|---|---|
| Semantic keys | 240 (37 semantic aliases such as `section.skills`) |
| Asset files | 203 |
| Icon references in code (incl. dynamic families) | 151 |
| Direct matches | 151 |
| Fallbacks (reference not in the registry) | 0 |
| Missing asset files | 0 |
| Corrupt assets | 0 |
| Assets with a visual-check note | 0 |
| Keys without an accessible label | 0 |
| Assets not referenced by the app (kept for later use) | 88 |
| Assets with unknown licence | 203 |

Fallback chain (js/icons.js): specific key → the key's `fallback` (category icon) → `generic`. A file that fails to load is
swapped for its fallback at the same size, then for the generic icon.

## Visual check notes

Thresholds: subject fills at least 60% of the canvas, 3–97% of the pixels are opaque, the brightest tenth of the subject
reaches 3:1 against the card surface, 96 px (192 px portraits).

| Asset | Note |
|---|---|
| none | |

## Licensing

| Group | Source | Author / provider | Licence | Attribution | Modification | Redistribution | Status |
|---|---|---|---|---|---|---|---|
| actions | ../icons (user collection), curated in ../icons_curated | unknown (icon marketplace style) | unknown | unknown (marketplace free licences usually require it) | unknown | unknown | **unknown**: private table use only; replace or verify before public deployment |
| classes | ../icons (user collection), curated in ../icons_curated | unknown (icon marketplace style) | unknown | unknown (marketplace free licences usually require it) | unknown | unknown | **unknown**: private table use only; replace or verify before public deployment |
| conditions | ../icons (user collection), curated in ../icons_curated | unknown (icon marketplace style) | unknown | unknown (marketplace free licences usually require it) | unknown | unknown | **unknown**: private table use only; replace or verify before public deployment |
| creatures | ../icons (user collection), curated in ../icons_curated | unknown (icon marketplace style) | unknown | unknown (marketplace free licences usually require it) | unknown | unknown | **unknown**: private table use only; replace or verify before public deployment |
| damage-types | ../icons (user collection), curated in ../icons_curated | unknown (icon marketplace style) | unknown | unknown (marketplace free licences usually require it) | unknown | unknown | **unknown**: private table use only; replace or verify before public deployment |
| dm | ../icons (user collection), curated in ../icons_curated | unknown (icon marketplace style) | unknown | unknown (marketplace free licences usually require it) | unknown | unknown | **unknown**: private table use only; replace or verify before public deployment |
| equipment-slots | ../icons (user collection), curated in ../icons_curated | unknown (icon marketplace style) | unknown | unknown (marketplace free licences usually require it) | unknown | unknown | **unknown**: private table use only; replace or verify before public deployment |
| items | ../icons (user collection), curated in ../icons_curated | unknown (icon marketplace style) | unknown | unknown (marketplace free licences usually require it) | unknown | unknown | **unknown**: private table use only; replace or verify before public deployment |
| movement | ../icons (user collection), curated in ../icons_curated | unknown (icon marketplace style) | unknown | unknown (marketplace free licences usually require it) | unknown | unknown | **unknown**: private table use only; replace or verify before public deployment |
| portraits | ../icons (user collection), curated in ../icons_curated | unknown (icon marketplace style) | unknown | unknown (marketplace free licences usually require it) | unknown | unknown | **unknown**: private table use only; replace or verify before public deployment |
| potions | ../icons (user collection), curated in ../icons_curated | unknown (icon marketplace style) | unknown | unknown (marketplace free licences usually require it) | unknown | unknown | **unknown**: private table use only; replace or verify before public deployment |
| spell-schools | ../icons (user collection), curated in ../icons_curated | unknown (icon marketplace style) | unknown | unknown (marketplace free licences usually require it) | unknown | unknown | **unknown**: private table use only; replace or verify before public deployment |
| ui | ../icons (user collection), curated in ../icons_curated | unknown (icon marketplace style) | unknown | unknown (marketplace free licences usually require it) | unknown | unknown | **unknown**: private table use only; replace or verify before public deployment |
| fonts (Inter, Alegreya) | Google Fonts / GitHub | Rasmus Andersson; Juan Pablo del Peral (Huerta Tipográfica) | SIL OFL 1.1 | licence text shipped (`fonts/OFL-*.txt`) | allowed | allowed | **approved** |

Every icon group is **unknown**: fine for private table use, but each one must be verified (and attributed if the licence
asks for it) or replaced before the app is shared publicly or deployed. Two icons were added in this task from the same
collection (`damage-types/multiple` from `storm (1).png`, `damage-types/choose` from `tarot-card.png`); they inherit the
same status. Since the school-only spell icon correction (2026-10-22) no view draws a damage-type icon; those assets are kept
(unused) in case a later feature needs them.

## Unused assets

`actions/ki`, `actions/rage`, `conditions/cursed`, `creatures/bear`, `creatures/bear-head`, `creatures/deer`, `creatures/dog`, `creatures/dragon`, `creatures/eagle`, `creatures/fox-head`, `creatures/horse`, `creatures/owl`, `creatures/snake`, `creatures/spider`, `creatures/stag-head`, `creatures/wolf`, `creatures/wolf-head`, `damage-types/acid`, `damage-types/bludgeoning`, `damage-types/choose`, `damage-types/cold`, `damage-types/force`, `damage-types/lightning`, `damage-types/multiple`, `damage-types/necrotic`, `damage-types/piercing`, `damage-types/poison`, `damage-types/psychic`, `damage-types/radiant`, `damage-types/slashing`, `damage-types/thunder`, `items/amulet-gem`, `items/bandage`, `items/bullets`, `items/candle`, `items/cauldron`, `items/gem`, `items/horn`, `items/hourglass`, `items/ink-and-quill`, `items/key`, `items/lute`, `items/map`, `items/mortar-pestle`, `items/scroll`, `items/tent`, `items/tome-sealed`, `items/torch`, `items/treasure`, `movement/burrow`, `movement/climb`, `movement/fly`, `movement/swim`, `portraits/alchemist`, `portraits/armored-knight`, `portraits/assassin`, `portraits/barbarian`, `portraits/barbarian-with-bear`, `portraits/crossbowman`, `portraits/dragonborn`, `portraits/elf-archer`, `portraits/hunter`, `portraits/knight-woman`, `portraits/martial-artist`, `portraits/masked-ninja`, `portraits/monk`, `portraits/ninja`, `portraits/pirate`, `portraits/priestess`, `portraits/rogue-silver-hair`, `portraits/samurai`, `portraits/samurai-woman`, `portraits/sorceress`, `portraits/thief`, `portraits/traveler`, `portraits/vampire`, `portraits/warrior`, `portraits/wizard`, `portraits/zombie`, `potions/acid`, `potions/empty`, `potions/fire`, `potions/generic`, `potions/love`, `potions/mana`, `potions/poison`, `ui/saving-throw`, `ui/warning`

## Keys

### action

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `action.concentration` | `actions/concentration` | yes | 96x96 | ok | Concentration | `generic` | spell-ui.js |
| `action.damage` | `actions/damage` | yes | 96x96 | ok | Damage | `generic` | unused |
| `action.death-saves` | `actions/death-saves` | yes | 96x96 | ok | Death saves | `generic` | dm-space.js |
| `action.heal` | `actions/heal` | yes | 96x96 | ok | Heal | `generic` | app.js, sheet.js |
| `action.initiative` | `actions/initiative` | yes | 96x96 | ok | Initiative | `generic` | sheet.js |
| `action.inspiration` | `actions/inspiration` | yes | 96x96 | ok | Inspiration | `generic` | unused |
| `action.ki` | `actions/ki` | yes | 96x96 | ok | Ki | `generic` | unused |
| `action.level-up` | `actions/level-up` | yes | 96x96 | ok | Level up | `generic` | sheet.js |
| `action.long-rest` | `actions/long-rest` | yes | 96x96 | ok | Long rest | `generic` | class-ui.js, sheet.js |
| `action.proficiency` | `actions/proficiency` | yes | 96x96 | ok | Proficiency | `generic` | sheet.js |
| `action.rage` | `actions/rage` | yes | 96x96 | ok | Rage | `generic` | unused |
| `action.resources` | `actions/resources` | yes | 96x96 | ok | Resources | `generic` | sheet.js |
| `action.short-rest` | `actions/short-rest` | yes | 96x96 | ok | Short rest | `generic` | class-ui.js, sheet.js |
| `action.speed` | `actions/speed` | yes | 96x96 | ok | Speed | `generic` | sheet.js |
| `action.wild-shape` | `actions/wild-shape` | yes | 96x96 | ok | Wild shape | `generic` | app.js, dm-space.js, sheet.js, wild-shape-ui.js |

### build

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `build.background` | `ui/background` | yes | 96x96 | ok | Background | `identity.generic` | sheet.js |
| `build.class` | `ui/abilities` | yes | 96x96 | ok | Classes | `generic` | sheet.js |
| `build.class-features` | `ui/feat` | yes | 96x96 | ok | Class features | `generic` | sheet.js |
| `build.feat` | `ui/feat` | yes | 96x96 | ok | Feats | `generic` | feat-ui.js |
| `build.lineage` | `ui/lineage` | yes | 96x96 | ok | Lineage | `identity.generic` | sheet.js |
| `build.next` | `ui/build` | yes | 96x96 | ok | Next steps | `generic` | sheet.js |
| `build.own-features` | `ui/custom-content` | yes | 96x96 | ok | Your own features | `generic` | sheet.js |
| `build.reminders` | `ui/notes` | yes | 96x96 | ok | Reminders | `generic` | sheet.js |

### class

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `class.artificer` | `classes/artificer` | yes | 96x96 | ok | Artificer | `ui.build` | (dynamic family) |
| `class.barbarian` | `classes/barbarian` | yes | 96x96 | ok | Barbarian | `ui.build` | (dynamic family) |
| `class.bard` | `classes/bard` | yes | 96x96 | ok | Bard | `ui.build` | (dynamic family) |
| `class.cleric` | `classes/cleric` | yes | 96x96 | ok | Cleric | `ui.build` | (dynamic family) |
| `class.druid` | `classes/druid` | yes | 96x96 | ok | Druid | `ui.build` | (dynamic family) |
| `class.fighter` | `classes/fighter` | yes | 96x96 | ok | Fighter | `ui.build` | (dynamic family), index.html, app.js |
| `class.monk` | `classes/monk` | yes | 96x96 | ok | Monk | `ui.build` | (dynamic family) |
| `class.paladin` | `classes/paladin` | yes | 96x96 | ok | Paladin | `ui.build` | (dynamic family) |
| `class.ranger` | `classes/ranger` | yes | 96x96 | ok | Ranger | `ui.build` | (dynamic family) |
| `class.rogue` | `classes/rogue` | yes | 96x96 | ok | Rogue | `ui.build` | (dynamic family) |
| `class.sorcerer` | `classes/sorcerer` | yes | 96x96 | ok | Sorcerer | `ui.build` | (dynamic family) |
| `class.warlock` | `classes/warlock` | yes | 96x96 | ok | Warlock | `ui.build` | (dynamic family) |
| `class.wizard` | `classes/wizard` | yes | 96x96 | ok | Wizard | `ui.build` | (dynamic family) |

### condition

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `condition.blinded` | `conditions/blinded` | yes | 96x96 | ok | Blinded | `condition.generic-effect` | (dynamic family) |
| `condition.charmed` | `conditions/charmed` | yes | 96x96 | ok | Charmed | `condition.generic-effect` | (dynamic family) |
| `condition.cursed` | `conditions/cursed` | yes | 96x96 | ok | Cursed | `condition.generic-effect` | unused |
| `condition.frightened` | `conditions/frightened` | yes | 96x96 | ok | Frightened | `condition.generic-effect` | (dynamic family) |
| `condition.generic-effect` | `conditions/generic-effect` | yes | 96x96 | ok | Effect | `generic` | (dynamic family), icons.js, wild-shape-ui.js |
| `condition.grappled` | `conditions/grappled` | yes | 96x96 | ok | Grappled | `condition.generic-effect` | (dynamic family) |
| `condition.invisible` | `conditions/invisible` | yes | 96x96 | ok | Invisible | `condition.generic-effect` | (dynamic family) |
| `condition.paralyzed` | `conditions/paralyzed` | yes | 96x96 | ok | Paralyzed | `condition.generic-effect` | (dynamic family) |
| `condition.petrified` | `conditions/petrified` | yes | 96x96 | ok | Petrified | `condition.generic-effect` | (dynamic family) |
| `condition.poisoned` | `conditions/poisoned` | yes | 96x96 | ok | Poisoned | `condition.generic-effect` | (dynamic family) |
| `condition.restrained` | `conditions/restrained` | yes | 96x96 | ok | Restrained | `condition.generic-effect` | (dynamic family) |
| `condition.stunned` | `conditions/stunned` | yes | 96x96 | ok | Stunned | `condition.generic-effect` | (dynamic family) |

### creature

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `creature.bear` | `creatures/bear` | yes | 96x96 | ok | Bear | `dm.creature` | unused |
| `creature.bear-head` | `creatures/bear-head` | yes | 96x96 | ok | Bear head | `dm.creature` | unused |
| `creature.deer` | `creatures/deer` | yes | 96x96 | ok | Deer | `dm.creature` | unused |
| `creature.dog` | `creatures/dog` | yes | 96x96 | ok | Dog | `dm.creature` | unused |
| `creature.dragon` | `creatures/dragon` | yes | 96x96 | ok | Dragon | `dm.creature` | unused |
| `creature.eagle` | `creatures/eagle` | yes | 96x96 | ok | Eagle | `dm.creature` | unused |
| `creature.fox-head` | `creatures/fox-head` | yes | 96x96 | ok | Fox head | `dm.creature` | unused |
| `creature.horse` | `creatures/horse` | yes | 96x96 | ok | Horse | `dm.creature` | unused |
| `creature.owl` | `creatures/owl` | yes | 96x96 | ok | Owl | `dm.creature` | unused |
| `creature.snake` | `creatures/snake` | yes | 96x96 | ok | Snake | `dm.creature` | unused |
| `creature.spider` | `creatures/spider` | yes | 96x96 | ok | Spider | `dm.creature` | unused |
| `creature.stag-head` | `creatures/stag-head` | yes | 96x96 | ok | Stag head | `dm.creature` | unused |
| `creature.wolf` | `creatures/wolf` | yes | 96x96 | ok | Wolf | `dm.creature` | unused |
| `creature.wolf-head` | `creatures/wolf-head` | yes | 96x96 | ok | Wolf head | `dm.creature` | unused |

### dm

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `dm.approved` | `dm/approved` | yes | 96x96 | ok | Approved | `generic` | dm-space.js, feat-ui.js, sheet.js |
| `dm.background` | `dm/background` | yes | 96x96 | ok | Background | `generic` | content-editors.js |
| `dm.campaign` | `dm/campaign` | yes | 96x96 | ok | Campaign | `generic` | index.html, app.js, dm-space.js, homebrew-form.js, sheet.js |
| `dm.companion` | `dm/companion` | yes | 96x96 | ok | Companion | `generic` | content-editors.js |
| `dm.condition` | `dm/condition` | yes | 96x96 | ok | Condition | `generic` | content-editors.js |
| `dm.creature` | `dm/creature` | yes | 96x96 | ok | Creature | `generic` | content-editors.js |
| `dm.dm-grant` | `dm/dm-grant` | yes | 96x96 | ok | DM grant | `generic` | feat-ui.js |
| `dm.feat` | `dm/feat` | yes | 96x96 | ok | Feat | `generic` | content-editors.js |
| `dm.item` | `dm/item` | yes | 96x96 | ok | Item | `generic` | content-editors.js |
| `dm.lineage` | `dm/lineage` | yes | 96x96 | ok | Lineage | `generic` | content-editors.js |
| `dm.spell` | `dm/spell` | yes | 96x96 | ok | Spell | `generic` | content-editors.js |

### generic

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `generic` | `items/crystal` | yes | 96x96 | ok | Icon | `None` | icons.js, spell-icons.js |

### identity

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `identity.generic` | `ui/bio` | yes | 96x96 | ok | Identity | `generic` | sheet.js |

### inventory

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `inventory.armor` | `items/armor` | yes | 96x96 | ok | Armor | `generic` | icons.js |
| `inventory.generic` | `ui/inventory` | yes | 96x96 | ok | Item | `generic` | unused |
| `inventory.shield` | `equipment-slots/shield` | yes | 96x96 | ok | Shield | `generic` | unused |
| `inventory.weapon` | `items/weapons` | yes | 96x96 | ok | Weapon | `generic` | icons.js |

### item

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `item.ammunition` | `items/ammunition` | yes | 96x96 | ok | Ammunition | `inventory.generic` | icons.js |
| `item.amulet-gem` | `items/amulet-gem` | yes | 96x96 | ok | Amulet | `inventory.generic` | unused |
| `item.armor` | `items/armor` | yes | 96x96 | ok | Armor | `inventory.generic` | unused |
| `item.bandage` | `items/bandage` | yes | 96x96 | ok | Bandage | `inventory.generic` | unused |
| `item.book` | `items/book` | yes | 96x96 | ok | Book | `inventory.generic` | sheet.js |
| `item.bullets` | `items/bullets` | yes | 96x96 | ok | Bullets | `inventory.generic` | unused |
| `item.candle` | `items/candle` | yes | 96x96 | ok | Candle | `inventory.generic` | unused |
| `item.cauldron` | `items/cauldron` | yes | 96x96 | ok | Cauldron | `inventory.generic` | unused |
| `item.coins` | `items/coins` | yes | 96x96 | ok | Coins | `inventory.generic` | unused |
| `item.consumables` | `items/consumables` | yes | 96x96 | ok | Consumables | `inventory.generic` | icons.js |
| `item.containers` | `items/containers` | yes | 96x96 | ok | Containers | `inventory.generic` | icons.js |
| `item.crystal` | `items/crystal` | yes | 96x96 | ok | Crystal | `inventory.generic` | unused |
| `item.firearm` | `items/firearm` | yes | 96x96 | ok | Firearm | `inventory.generic` | icons.js |
| `item.gear` | `items/gear` | yes | 96x96 | ok | Gear | `inventory.generic` | icons.js, inventory-ui.js |
| `item.gem` | `items/gem` | yes | 96x96 | ok | Gem | `inventory.generic` | unused |
| `item.horn` | `items/horn` | yes | 96x96 | ok | Horn | `inventory.generic` | unused |
| `item.hourglass` | `items/hourglass` | yes | 96x96 | ok | Hourglass | `inventory.generic` | unused |
| `item.ink-and-quill` | `items/ink-and-quill` | yes | 96x96 | ok | Ink and quill | `inventory.generic` | unused |
| `item.key` | `items/key` | yes | 96x96 | ok | Key | `inventory.generic` | unused |
| `item.lute` | `items/lute` | yes | 96x96 | ok | Lute | `inventory.generic` | unused |
| `item.magic` | `items/magic` | yes | 96x96 | ok | Magic | `inventory.generic` | icons.js, inventory-ui.js |
| `item.map` | `items/map` | yes | 96x96 | ok | Map | `inventory.generic` | unused |
| `item.mortar-pestle` | `items/mortar-pestle` | yes | 96x96 | ok | Mortar and pestle | `inventory.generic` | unused |
| `item.mount` | `items/mount` | yes | 96x96 | ok | Mount | `inventory.generic` | icons.js |
| `item.scroll` | `items/scroll` | yes | 96x96 | ok | Scroll | `inventory.generic` | unused |
| `item.spell-scroll` | `items/spell-scroll` | yes | 96x96 | ok | Spell scroll | `inventory.generic` | icons.js |
| `item.tent` | `items/tent` | yes | 96x96 | ok | Tent | `inventory.generic` | unused |
| `item.tome-sealed` | `items/tome-sealed` | yes | 96x96 | ok | Sealed tome | `inventory.generic` | unused |
| `item.tools` | `items/tools` | yes | 96x96 | ok | Tools | `inventory.generic` | icons.js |
| `item.torch` | `items/torch` | yes | 96x96 | ok | Torch | `inventory.generic` | unused |
| `item.treasure` | `items/treasure` | yes | 96x96 | ok | Treasure | `inventory.generic` | unused |
| `item.vehicle` | `items/vehicle` | yes | 96x96 | ok | Vehicle | `inventory.generic` | icons.js |
| `item.wand` | `items/wand` | yes | 96x96 | ok | Wand | `inventory.generic` | icons.js |
| `item.weapons` | `items/weapons` | yes | 96x96 | ok | Weapons | `inventory.generic` | unused |

### movement

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `movement.burrow` | `movement/burrow` | yes | 96x96 | ok | Burrow | `action.speed` | unused |
| `movement.climb` | `movement/climb` | yes | 96x96 | ok | Climb | `action.speed` | unused |
| `movement.fly` | `movement/fly` | yes | 96x96 | ok | Fly | `action.speed` | unused |
| `movement.swim` | `movement/swim` | yes | 96x96 | ok | Swim | `action.speed` | unused |
| `movement.walk` | `movement/walk` | yes | 96x96 | ok | Walk | `action.speed` | sheet.js |

### portrait

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `portrait.alchemist` | `portraits/alchemist` | yes | 192x192 | ok | Alchemist | `identity.generic` | unused |
| `portrait.armored-knight` | `portraits/armored-knight` | yes | 192x192 | ok | Armored knight | `identity.generic` | unused |
| `portrait.assassin` | `portraits/assassin` | yes | 192x192 | ok | Assassin | `identity.generic` | unused |
| `portrait.barbarian` | `portraits/barbarian` | yes | 192x192 | ok | Barbarian | `identity.generic` | unused |
| `portrait.barbarian-with-bear` | `portraits/barbarian-with-bear` | yes | 192x192 | ok | Barbarian with bear | `identity.generic` | unused |
| `portrait.crossbowman` | `portraits/crossbowman` | yes | 192x192 | ok | Crossbowman | `identity.generic` | unused |
| `portrait.dragonborn` | `portraits/dragonborn` | yes | 192x192 | ok | Dragonborn | `identity.generic` | unused |
| `portrait.elf-archer` | `portraits/elf-archer` | yes | 192x192 | ok | Elf archer | `identity.generic` | unused |
| `portrait.explorer` | `portraits/explorer` | yes | 192x192 | ok | Explorer | `identity.generic` | app.js |
| `portrait.hunter` | `portraits/hunter` | yes | 192x192 | ok | Hunter | `identity.generic` | unused |
| `portrait.knight-woman` | `portraits/knight-woman` | yes | 192x192 | ok | Knight woman | `identity.generic` | unused |
| `portrait.martial-artist` | `portraits/martial-artist` | yes | 192x192 | ok | Martial artist | `identity.generic` | unused |
| `portrait.masked-ninja` | `portraits/masked-ninja` | yes | 192x192 | ok | Masked ninja | `identity.generic` | unused |
| `portrait.monk` | `portraits/monk` | yes | 192x192 | ok | Monk | `identity.generic` | unused |
| `portrait.ninja` | `portraits/ninja` | yes | 192x192 | ok | Ninja | `identity.generic` | unused |
| `portrait.pirate` | `portraits/pirate` | yes | 192x192 | ok | Pirate | `identity.generic` | unused |
| `portrait.priestess` | `portraits/priestess` | yes | 192x192 | ok | Priestess | `identity.generic` | unused |
| `portrait.rogue-silver-hair` | `portraits/rogue-silver-hair` | yes | 192x192 | ok | Rogue silver hair | `identity.generic` | unused |
| `portrait.samurai` | `portraits/samurai` | yes | 192x192 | ok | Samurai | `identity.generic` | unused |
| `portrait.samurai-woman` | `portraits/samurai-woman` | yes | 192x192 | ok | Samurai woman | `identity.generic` | unused |
| `portrait.sorceress` | `portraits/sorceress` | yes | 192x192 | ok | Sorceress | `identity.generic` | unused |
| `portrait.thief` | `portraits/thief` | yes | 192x192 | ok | Thief | `identity.generic` | unused |
| `portrait.traveler` | `portraits/traveler` | yes | 192x192 | ok | Traveler | `identity.generic` | unused |
| `portrait.vampire` | `portraits/vampire` | yes | 192x192 | ok | Vampire | `identity.generic` | unused |
| `portrait.warrior` | `portraits/warrior` | yes | 192x192 | ok | Warrior | `identity.generic` | unused |
| `portrait.wizard` | `portraits/wizard` | yes | 192x192 | ok | Wizard | `identity.generic` | unused |
| `portrait.zombie` | `portraits/zombie` | yes | 192x192 | ok | Zombie | `identity.generic` | unused |

### potion

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `potion.acid` | `potions/acid` | yes | 96x96 | ok | Acid potion | `item.consumables` | unused |
| `potion.empty` | `potions/empty` | yes | 96x96 | ok | Empty bottle | `item.consumables` | unused |
| `potion.fire` | `potions/fire` | yes | 96x96 | ok | Fire potion | `item.consumables` | unused |
| `potion.generic` | `potions/generic` | yes | 96x96 | ok | Potion | `item.consumables` | unused |
| `potion.healing` | `potions/healing` | yes | 96x96 | ok | Healing potion | `item.consumables` | icons.js |
| `potion.love` | `potions/love` | yes | 96x96 | ok | Love potion | `item.consumables` | unused |
| `potion.mana` | `potions/mana` | yes | 96x96 | ok | Mana potion | `item.consumables` | unused |
| `potion.poison` | `potions/poison` | yes | 96x96 | ok | Poison potion | `item.consumables` | unused |

### section

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `section.abilities` | `ui/abilities` | yes | 96x96 | ok | Abilities | `generic` | icons.js |
| `section.ability-scores` | `ui/abilities` | yes | 96x96 | ok | Ability scores | `generic` | sheet.js |
| `section.attunement` | `ui/attunement` | yes | 96x96 | ok | Attunement | `generic` | inventory-ui.js |
| `section.bio` | `ui/bio` | yes | 96x96 | ok | Bio | `generic` | icons.js |
| `section.build` | `ui/build` | yes | 96x96 | ok | Build | `generic` | icons.js |
| `section.coins` | `items/coins` | yes | 96x96 | ok | Coins | `generic` | inventory-ui.js, sheet.js |
| `section.containers` | `items/containers` | yes | 96x96 | ok | Containers | `generic` | inventory-ui.js |
| `section.equipped` | `equipment-slots/armor` | yes | 96x96 | ok | Equipped | `generic` | inventory-ui.js |
| `section.hit-dice` | `ui/hit-dice` | yes | 96x96 | ok | Hit dice | `generic` | sheet.js |
| `section.inventory` | `ui/inventory` | yes | 96x96 | ok | Inventory | `generic` | icons.js, inventory-ui.js |
| `section.legacy` | `ui/incomplete` | yes | 96x96 | ok | Old sheet items | `generic` | inventory-ui.js |
| `section.notes` | `ui/notes` | yes | 96x96 | ok | Notes | `generic` | sheet.js |
| `section.play` | `ui/play` | yes | 96x96 | ok | Play | `generic` | icons.js |
| `section.proficiencies` | `actions/proficiency` | yes | 96x96 | ok | Proficiencies | `generic` | sheet.js |
| `section.quick-use` | `potions/healing` | yes | 96x96 | ok | Quick use | `generic` | inventory-ui.js |
| `section.saving-throws` | `ui/saving-throw` | yes | 96x96 | ok | Saving throws | `generic` | unused |
| `section.senses` | `ui/senses` | yes | 96x96 | ok | Senses and movement | `generic` | sheet.js |
| `section.skills` | `ui/skills` | yes | 96x96 | ok | Skills | `generic` | unused |
| `section.spell-slots` | `actions/inspiration` | yes | 96x96 | ok | Spell slots | `generic` | sheet.js |
| `section.spellbook` | `ui/spellbook` | yes | 96x96 | ok | Your spells | `generic` | sheet.js |
| `section.spells` | `spell-schools/spells-tab` | yes | 96x96 | ok | Spells | `generic` | icons.js, sheet.js |

### slot

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `slot.armor` | `equipment-slots/armor` | yes | 96x96 | ok | Armor slot | `inventory.generic` | inventory-ui.js |
| `slot.cloak` | `equipment-slots/cloak` | yes | 96x96 | ok | Cloak slot | `inventory.generic` | inventory-ui.js |
| `slot.focus` | `equipment-slots/focus` | yes | 96x96 | ok | Focus slot | `inventory.generic` | inventory-ui.js |
| `slot.hands` | `equipment-slots/hands` | yes | 96x96 | ok | Hands slot | `inventory.generic` | inventory-ui.js |
| `slot.head` | `equipment-slots/head` | yes | 96x96 | ok | Head slot | `inventory.generic` | inventory-ui.js |
| `slot.legs` | `equipment-slots/legs` | yes | 96x96 | ok | Legs slot | `inventory.generic` | inventory-ui.js |
| `slot.main-hand` | `equipment-slots/main-hand` | yes | 96x96 | ok | Main hand slot | `inventory.generic` | inventory-ui.js |
| `slot.neck` | `equipment-slots/neck` | yes | 96x96 | ok | Neck slot | `inventory.generic` | inventory-ui.js |
| `slot.off-hand` | `equipment-slots/off-hand` | yes | 96x96 | ok | Off hand slot | `inventory.generic` | inventory-ui.js |
| `slot.ring` | `equipment-slots/ring` | yes | 96x96 | ok | Ring slot | `inventory.generic` | icons.js, inventory-ui.js |
| `slot.shield` | `equipment-slots/shield` | yes | 96x96 | ok | Shield slot | `inventory.generic` | app.js, inventory-ui.js, sheet.js |

### spell

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `spell.damage.generic` | `actions/damage` | yes | 96x96 | ok | Damage | `generic` | unused |
| `spell.school.generic` | `spell-schools/spells-tab` | yes | 96x96 | ok | Spell school | `generic` | (dynamic family), spell-icons.js |

### spell.damage

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `spell.damage.acid` | `damage-types/acid` | yes | 96x96 | ok | Acid damage | `spell.damage.generic` | unused |
| `spell.damage.bludgeoning` | `damage-types/bludgeoning` | yes | 96x96 | ok | Bludgeoning damage | `spell.damage.generic` | unused |
| `spell.damage.choose` | `damage-types/choose` | yes | 96x96 | ok | Choose a damage type | `spell.damage.generic` | unused |
| `spell.damage.cold` | `damage-types/cold` | yes | 96x96 | ok | Cold damage | `spell.damage.generic` | unused |
| `spell.damage.fire` | `damage-types/fire` | yes | 96x96 | ok | Fire damage | `spell.damage.generic` | icons.js |
| `spell.damage.force` | `damage-types/force` | yes | 96x96 | ok | Force damage | `spell.damage.generic` | unused |
| `spell.damage.lightning` | `damage-types/lightning` | yes | 96x96 | ok | Lightning damage | `spell.damage.generic` | unused |
| `spell.damage.multiple` | `damage-types/multiple` | yes | 96x96 | ok | Several damage types | `spell.damage.generic` | unused |
| `spell.damage.necrotic` | `damage-types/necrotic` | yes | 96x96 | ok | Necrotic damage | `spell.damage.generic` | unused |
| `spell.damage.piercing` | `damage-types/piercing` | yes | 96x96 | ok | Piercing damage | `spell.damage.generic` | unused |
| `spell.damage.poison` | `damage-types/poison` | yes | 96x96 | ok | Poison damage | `spell.damage.generic` | unused |
| `spell.damage.psychic` | `damage-types/psychic` | yes | 96x96 | ok | Psychic damage | `spell.damage.generic` | unused |
| `spell.damage.radiant` | `damage-types/radiant` | yes | 96x96 | ok | Radiant damage | `spell.damage.generic` | unused |
| `spell.damage.slashing` | `damage-types/slashing` | yes | 96x96 | ok | Slashing damage | `spell.damage.generic` | unused |
| `spell.damage.thunder` | `damage-types/thunder` | yes | 96x96 | ok | Thunder damage | `spell.damage.generic` | unused |

### spell.school

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `spell.school.abjuration` | `spell-schools/abjuration` | yes | 96x96 | ok | Abjuration school | `spell.school.generic` | (dynamic family) |
| `spell.school.conjuration` | `spell-schools/conjuration` | yes | 96x96 | ok | Conjuration school | `spell.school.generic` | (dynamic family) |
| `spell.school.divination` | `spell-schools/divination` | yes | 96x96 | ok | Divination school | `spell.school.generic` | (dynamic family) |
| `spell.school.enchantment` | `spell-schools/enchantment` | yes | 96x96 | ok | Enchantment school | `spell.school.generic` | (dynamic family) |
| `spell.school.evocation` | `spell-schools/evocation` | yes | 96x96 | ok | Evocation school | `spell.school.generic` | (dynamic family) |
| `spell.school.illusion` | `spell-schools/illusion` | yes | 96x96 | ok | Illusion school | `spell.school.generic` | (dynamic family) |
| `spell.school.necromancy` | `spell-schools/necromancy` | yes | 96x96 | ok | Necromancy school | `spell.school.generic` | (dynamic family) |
| `spell.school.spells-tab` | `spell-schools/spells-tab` | yes | 96x96 | ok | Spells | `spell.school.generic` | unused |
| `spell.school.transmutation` | `spell-schools/transmutation` | yes | 96x96 | ok | Transmutation school | `spell.school.generic` | (dynamic family) |

### ui

| Key | Asset | Exists | Size | Visual check | Accessible label | Fallback | Referenced by |
|---|---|---|---|---|---|---|---|
| `ui.abilities` | `ui/abilities` | yes | 96x96 | ok | Abilities | `generic` | feat-ui.js |
| `ui.approval` | `ui/approval` | yes | 96x96 | ok | Approval | `generic` | dm-space.js |
| `ui.attack` | `ui/attack` | yes | 96x96 | ok | Attack | `generic` | icons.js, sheet.js |
| `ui.attunement` | `ui/attunement` | yes | 96x96 | ok | Attunement | `generic` | unused |
| `ui.background` | `ui/background` | yes | 96x96 | ok | Background | `generic` | feat-ui.js, sheet.js |
| `ui.bio` | `ui/bio` | yes | 96x96 | ok | Bio | `generic` | app.js |
| `ui.bonus-action` | `ui/bonus-action` | yes | 96x96 | ok | Bonus action | `generic` | icons.js |
| `ui.build` | `ui/build` | yes | 96x96 | ok | Build | `generic` | icons.js, request-ui.js |
| `ui.companion` | `ui/companion` | yes | 96x96 | ok | Companion | `generic` | sheet.js |
| `ui.condition` | `ui/condition` | yes | 96x96 | ok | Condition | `generic` | icons.js |
| `ui.custom-content` | `ui/custom-content` | yes | 96x96 | ok | Custom content | `generic` | dm-space.js, inventory-ui.js, sheet.js |
| `ui.dm-secret` | `ui/dm-secret` | yes | 96x96 | ok | DM only | `generic` | dm-space.js |
| `ui.feat` | `ui/feat` | yes | 96x96 | ok | Feat | `generic` | feat-ui.js, icons.js, sheet.js |
| `ui.hit-dice` | `ui/hit-dice` | yes | 96x96 | ok | Hit dice | `generic` | unused |
| `ui.incomplete` | `ui/incomplete` | yes | 96x96 | ok | Incomplete | `generic` | dm-space.js, inventory-ui.js, sheet.js |
| `ui.inventory` | `ui/inventory` | yes | 96x96 | ok | Inventory | `generic` | icons.js, inventory-ui.js |
| `ui.lineage` | `ui/lineage` | yes | 96x96 | ok | Lineage | `generic` | feat-ui.js, sheet.js |
| `ui.locked` | `ui/locked` | yes | 96x96 | ok | Locked | `generic` | app.js, dm-space.js, homebrew-form.js, request-ui.js, sheet.js, wild-shape-ui.js |
| `ui.notes` | `ui/notes` | yes | 96x96 | ok | Notes | `generic` | feat-ui.js, sheet.js |
| `ui.pending` | `ui/pending` | yes | 96x96 | ok | Pending | `generic` | app.js, dm-space.js, sheet.js |
| `ui.play` | `ui/play` | yes | 96x96 | ok | Play | `generic` | dm-space.js |
| `ui.reaction` | `ui/reaction` | yes | 96x96 | ok | Reaction | `generic` | icons.js |
| `ui.ritual` | `ui/ritual` | yes | 96x96 | ok | Ritual | `generic` | spell-ui.js |
| `ui.saving-throw` | `ui/saving-throw` | yes | 96x96 | ok | Saving throw | `generic` | unused |
| `ui.senses` | `ui/senses` | yes | 96x96 | ok | Senses | `generic` | sheet.js |
| `ui.skills` | `ui/skills` | yes | 96x96 | ok | Skills | `generic` | app.js |
| `ui.spellbook` | `ui/spellbook` | yes | 96x96 | ok | Spellbook | `generic` | unused |
| `ui.temp-hp` | `ui/temp-hp` | yes | 96x96 | ok | Temporary hit points | `generic` | sheet.js |
| `ui.warning` | `ui/warning` | yes | 96x96 | ok | Warning | `generic` | unused |

## Combat Builder (2026-11-06)

**Reused from the registry:**
- `action.initiative`, `action.concentration`, `action.damage`, `action.heal`, `ui.temp-hp`, `ui.reaction`, `ui.condition`;
- `ui.abilities` (PC avatar fallback), `dm.creature`, `creature.dragon`, `creature.bear-head`, `dm.campaign`;
- the condition icons through `conditionIcon()`. Deafened, Exhaustion, Incapacitated, Prone and Unconscious fall back to
  `condition.generic-effect`.

**New: project-authored inline SVG line glyphs** in `js/combat-icons.js`:
- drawn for Tavern Ledger, private-table use, no third-party source;
- no files, no runtime URL;
- `currentColor`, 24 × 24 viewBox;
- decorative (`aria-hidden`) unless given a label.

| Key | Concept |
|---|---|
| `swords` | Combat Builder (top-bar link, page kicker) |
| `round` | round / "Normal (both)" advantage state |
| `next`, `prev` | Next / Previous turn, Skip |
| `adv`, `dis` | Advantage (double up chevron) / Disadvantage (double down chevron) |
| `hidden`, `shown` | hidden from players / reveal |
| `crown` | Legendary Actions, legendary filter |
| `shield` | Armor Class on rows |
| `heart` | form HP (Wild Shape) on rows |
| `pause`, `play` | Pause / Resume / Start |
| `flag` | Finish, finished summary |
| `undo` | Undo |
| `plus` | add |
| `bolt` | turn notes, ties |
| `skull` | Mark defeated |
| `bell` | reminders |
| `history` | history |
| `wifi_off` | offline |
| `help` | keyboard shortcuts |

The Tavern Ledger logo is not used as a combat icon. No emoji are used. The top-bar link repeats the `swords` path
inline in `index.html`.

## Added 2026-11-07: plants and two potion containers (custom item icons)

Same illustrated family, copied from the project's own icon pool `../icons/` (originals untouched; 512 px PNG copies in
`../icons_curated/plants/`), converted to 96 × 96 WebP like the other assets. Registered by `scripts/local/build_icon_registry.py`
(new folder `plants`, prefix `plant.`, fallback `item.mortar-pestle`).

| Asset | Source file | Registry key | Label | Use |
|---|---|---|---|---|
| plants/herb.webp | plants.png | plant.herb (alias inventory.herbs) | Herb sprig | Herbs & Plants default, gallery |
| plants/leaf.webp | grass.png | plant.leaf | Leaf | gallery |
| plants/flower.webp | flower.png | plant.flower | Flower | gallery |
| plants/wildflowers.webp | flower2.png | plant.wildflowers | Wildflowers | gallery |
| plants/mushroom.webp | mushroom.png | plant.mushroom | Mushroom | gallery |
| plants/seed.webp | plant.png | plant.seed | Seed | gallery |
| plants/berry.webp | plant2.png | plant.berry | Berries | gallery |
| plants/root.webp | thorn.png | plant.root | Root or thorny vine | gallery |
| potions/flask.webp | potion.png | potion.flask | Flask | gallery |
| potions/bottle.webp | drink.png | potion.bottle | Bottle | gallery |

Resin uses the existing `item.crystal`; ingredient the existing `item.mortar-pestle`. New alias `inventory.potion` →
`potion.generic` (Potions filter). The registry change is additive (12 keys added, none changed).
