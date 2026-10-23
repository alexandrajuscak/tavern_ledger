# Spell icon coverage

Generated 2026-10-22 by `scripts/local/spell_icon_coverage.py` from the local database, using the app's own resolver
(`js/spell-icons.js`). Machine-readable: `data/reports/spell_icon_coverage.json`.

## The rule

**Spell school → one primary spell icon.** Every spell view (spellbook cards, details dialog, catalog picker, DM custom spell
preview, published and assigned campaign spells, mobile cards) uses `resolveSpellIcon()`:

| Spell data | Primary icon |
|---|---|
| school is one of the eight schools | that school's icon (`spell.school.<school>`) |
| school missing or not recognised | the generic spell icon (`spell.school.generic`); the badge says "School not resolved" |
| school icon not registered / file fails to load | the generic spell icon (registry fallback, then the load-error fallback) |

Damage type, healing, temporary hit points, control, movement, summoning, the spell name, class lists and automation status
never choose the primary icon. Damage types stay visible as colored text chips (Fire orange, Necrotic deep green, "+" for
types dealt together, "Choose one … or …" for a choice); the school badge, school colour and card edge stay on every card.
A spell without damage is not "unrepresented": its school icon represents it.

## Totals

| Measure | Count |
|---|---|
| Spell versions | 575 |
| Unresolved school | 0 |
| Generic fallback icon | 0 |
| Icon not taken from the school | 0 |
| Missing asset file | 0 |
| Broken path (file does not load) | 0 |
| Blank asset (no visible pixels) | 0 |
| Missing accessible label | 0 |
| Catalog picker and spellbook show different icons | 0 |
| Campaign custom spells | 1 |

## Count by school

| School | Icon key | Spell versions |
|---|---|---|
| Abjuration | `spell.school.abjuration` | 60 |
| Conjuration | `spell.school.conjuration` | 108 |
| Divination | `spell.school.divination` | 40 |
| Enchantment | `spell.school.enchantment` | 61 |
| Evocation | `spell.school.evocation` | 114 |
| Illusion | `spell.school.illusion` | 36 |
| Necromancy | `spell.school.necromancy` | 44 |
| Transmutation | `spell.school.transmutation` | 112 |

## Damage chips (not icons)

| Damage data | Spell versions |
|---|---|
| one damage type | 175 |
| several types dealt together ("+") | 5 |
| choose one type ("Choose one … or …") | 4 |
| several types in separate effects (listed with commas) | 8 |
| no damage | 383 |

## Examples

| Spell | School | Primary icon | Accessible label | Damage chips |
|---|---|---|---|---|
| Fireball | evocation | `spell.school.evocation` | Evocation school | fire |
| Cure Wounds | evocation | `spell.school.evocation` | Evocation school | — |
| Shield | abjuration | `spell.school.abjuration` | Abjuration school | — |
| Detect Magic | divination | `spell.school.divination` | Divination school | — |
| Misty Step | conjuration | `spell.school.conjuration` | Conjuration school | — |
| Hold Person | enchantment | `spell.school.enchantment` | Enchantment school | — |
| Chill Touch | necromancy | `spell.school.necromancy` | Necromancy school | necrotic |
| Minor Illusion | illusion | `spell.school.illusion` | Illusion school | — |
| Polymorph | transmutation | `spell.school.transmutation` | Transmutation school | — |
| Ice Storm | evocation | `spell.school.evocation` | Evocation school | bludgeoning, cold |
| Chromatic Orb | evocation | `spell.school.evocation` | Evocation school | acid, cold, fire, lightning, poison, thunder |

## Unresolved schools

| Spell | Version | Stored school |
|---|---|---|
| none | | |

## Campaign custom spells

| Spell | Version | School | Spellbook icon | Catalog icon | Damage chips |
|---|---|---|---|---|---|
| Ember Lance | `cc-6ac74091ba-v1` | evocation | `spell.school.evocation` | `spell.school.evocation` | fire |
