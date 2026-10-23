# Spellcasting sources

Every spell on a character comes from a source. A character can have any number of sources; the same spell from two
sources is one spellbook entry with two grants, each with its own DC and attack bonus.

## Source types

| Type | Stored | Typical use |
|---|---|---|
| `class` | yes | linked to a character class (`character_class_id`, created when the class is added): follows the class version, list, preparation and ritual mode; level and limits checked. Unlinked class sources are `is_preview` (no class rules) |
| `subclass` | yes | expanded or always-prepared subclass spells |
| `feat` | yes | Magic Initiate, Fey Touched, ... (feats are not a catalog yet) |
| `item` | yes | wands, staffs; usually a fixed DC / attack |
| `manual` | yes | anything the player enters by hand |
| `other` | yes | everything else |
| `lineage` | no | resolved from the selected lineage (innate, no slots, uses and recharge from the trait) |

## Spell Save DC and Spell Attack Bonus

Computed per source by `_spell_stat`, from the derived ability modifiers and proficiency bonus
(`get_character_derived_stats`):

- Save DC = `fixed_dc`, otherwise `8 + proficiency bonus + ability modifier + dc_bonus`
- Attack bonus = `fixed_attack_bonus`, otherwise `proficiency bonus + ability modifier + attack_bonus`

Both come with a breakdown. A grant may override the ability (`character_spells.casting_ability`) only with an ability
listed in the source's `allowed_abilities`. Lineage grants use the trait's fixed or chosen ability; when the choice is
still open, `ability_needed` is true and no DC is shown.

## Known, prepared, always prepared

- A grant must be at least one of known, prepared or always prepared.
- `always_prepared` only on a source with `always_prepared_allowed`; it does not count against the prepared limit.
- `set_character_spell_prepared` toggles preparation; a spell that is only prepared cannot be unprepared (remove it).
- Source counters: known (counting toward the limit), prepared (excluding always prepared), always prepared, total.
- Class sources (migration 1700): the **prepared limit** (`ability modifier + class level / divisor`, minimum 1; Cleric,
  Druid, Wizard, Paladin, Artificer) is enforced: preparing a counted spell beyond it is refused; going over because an
  ability score dropped is a warning, nothing is unprepared, unpreparing always works. Cantrips, always-prepared spells
  and other sources never count. **Cantrips known and spells known** limits (Bard, Sorcerer, Ranger, Warlock, Eldritch
  Knight, Arcane Trickster) are shown with over-limit warnings, not enforced.
- Class sources accept spells only up to the class's own highest spell level (Warlock: Pact slot level), not before the
  class's spellcasting starts, and no cantrips for Paladin / Ranger. Spells above the level after a level reduction are
  kept and reported.

## Ritual castability

Per grant: `ritual_allowed` set explicitly, or the spell is a ritual and the source's `ritual_mode` allows it:
`prepared` (prepared or always prepared), `known` (known or prepared), `spellbook` (in the spellbook, i.e. known),
`none`. Lineage grants are never ritual-castable.

## Spell lists

A source may reference a class spell list. With `enforce_spell_list` an off-list spell is rejected
("Fireball is not on the spell list of Artificer"); without it, the grant is accepted and marked
`on_source_list = false`.

## Slots

`uses_spell_slots` on the source and `uses_spell_slot` on the grant (cantrips never). Slot maximums come from the
character's classes and are used by hand on the Spells tab ([SPELL_SLOTS.md](SPELL_SLOTS.md)); casting a spell does not
consume a slot automatically.

## Security

- All writes go through the RPCs (direct inserts, updates and deletes are revoked).
- The caller must be able to access the character (`can_access_character`: owner, campaign DM, admin).
- A source id from another character is rejected; payload keys outside the allowed list (`character_id`,
  `created_by`, ...) are rejected.
- Spells must be visible to the caller (`can_view_spell`).

## Class feature spell grants (20261015001800)

Source type `class_feature` (key `feature:<class row id>`, label "<Class> features"): spells granted by active class or
subclass features ([CLASS_FEATURE_ENGINE.md](CLASS_FEATURE_ENGINE.md)). Flags from the effect: always prepared, ritual,
uses slots, counts against limits (reported only); casting ability from the effect or the class (subclass) ability.
The source is derived, never stored: deactivating or removing the feature removes only this grant; the same spell from
another source stays. Feature spells are never counted against the class source's prepared limit.
