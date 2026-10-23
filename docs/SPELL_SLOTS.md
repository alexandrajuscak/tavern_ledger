# Spell slots and Pact Magic

Slot maximums are derived from the character's classes on every read; only usage is stored.
Migration `20261015001700_class_levels_and_slots.sql`; tables per level in
[CLASS_PROGRESSION_COVERAGE.md](CLASS_PROGRESSION_COVERAGE.md).

## Progressions (`spell_slot_progressions`, 289 rows)

| Id | Kind | Used for |
|---|---|---|
| `standard-caster` | full | Bard, Cleric, Druid, Sorcerer, Wizard by class level; every multiclass spellcaster by effective caster level |
| `half-caster` | half | Paladin and Ranger single-class tables (nothing at 1st level) |
| `artificer-tce-slots` | half | Artificer single-class table (2 slots at 1st level) |
| `third-caster` | third | Eldritch Knight / Arcane Trickster (from fighter / rogue level 3); foundation only |
| `pact-magic` | pact | Warlock: slots and one slot level per Warlock level, never above 5th |

Every class table was parsed from its class page and compared with the shared table it uses (any difference stops the
generator). The standard table equals the Black Citadel multiclass table. Spell level and character level are different
things: a 5th-level Wizard has 3rd-level slots, not 5th-level ones.

## Which table applies

1. Classes whose spellcasting is active (class level ≥ start level; Fighter / Rogue only with a spellcasting subclass
   from level 3) and that use standard slots are counted.
2. **One** such class: its own single-class table at its class level (Paladin 5 → 4 / 2).
3. **Two or more**: the standard table at the effective caster level = full levels + ⌊half Paladin / Ranger⌋ +
   ⌈half Artificer⌉ + ⌊third Eldritch Knight / Arcane Trickster⌋ (capped at 20).
4. Warlock levels never count here: Pact Magic is a separate pool.

The breakdown (class, level, contribution type, raw and rounded contribution, active, reason) is returned with the slots.

**Artificer rounding** is stored as `half_up`: Tasha's multiclass rule rounds the Artificer's half up, and the Artificer
single-class table equals the standard table at ⌈level / 2⌉ at every level (checked by the generator). Black Citadel
says "rounded down"; recorded as a source conflict, not used.

## Spell access is per class, not per slot

A multiclass character can have higher slots than one class may use. Each class source exposes its own
`max_spell_level` (from its class table; for Warlock the Pact slot level). Adding a spell to a class source is refused
above that level, before the class's spellcasting starts, and for cantrips in classes without cantrips (Paladin,
Ranger). Manual, item, feat and lineage sources keep their own rules.

## Pact Magic

Separate pool: `slots` and `slot_level` per Warlock level (all slots share the level), recovered on a short or long rest.
Using a Pact slot needs no level choice. A Warlock spell of a lower level is cast with the current Pact slot level.
Mystic Arcanum (6th-9th level spells at Warlock 11, 13, 15, 17) is **not** a Pact slot and is not implemented; no
6th-9th level Pact slots exist. Future free casts use `character_resources` with `spell_version_id` and `cast_level`.

## Runtime state

| Table | Stores |
|---|---|
| `character_spell_slot_state` | `expended` per (character, pool, slot level); pool `standard` (levels 1-9) or `pact` (level 0) |
| `character_temporary_spell_slots` | future created slots (feature, item, manual): level, quantity, expended, source, expiry (`short_rest`, `long_rest`, `manual`) |
| `character_resource_events` | every use, restore, manual correction and rest, with the acting user |

Expended counts are stored (not remaining): remaining = max − expended, never below zero. When a maximum drops (a lower
class level), the stored count is kept and the remaining value is clamped to zero; a restore still works. Temporary
slots are listed separately and never change the class maximum.

## RPCs

| RPC | |
|---|---|
| `get_character_spell_slots(character)` | standard slots (max, expended, remaining), Pact Magic, temporary slots, legacy manual slots, casting options per spell level (which standard levels / Pact slot could pay), breakdown, rest descriptions |
| `expend_standard_spell_slot(character, slot_level, reason)` / `restore_standard_spell_slot(...)` | one slot of exactly that level; no combining, no partial slots |
| `expend_pact_magic_slot(character, reason)` / `restore_pact_magic_slot(...)` | one Pact slot |
| `set_spell_slot_state(character, pool, slot_level, expended, reason)` | authorized manual correction; a reason is required; logged as `manual_set` (no-op corrections are not logged) |

All of them check access (`can_access_character`), lock the character row (`for update`) so two requests can never spend
the last slot twice (tested with two parallel sessions and two parallel API calls), validate the level and the pool,
write an event and return the new slot state. No client-provided user id is accepted. Nothing casts a spell.

## UI (Spells tab → Spell slots)

Standard slots: one line per slot level with filled / empty circles, "2 / 4 remaining", Use and Restore. Pact Magic: its
own panel ("Slot level: 3rd", circles, remaining, "come back on a short or long rest"). Temporary slots are listed when
present. Short Rest / Long Rest buttons (also in the header) show what this version restores before acting. Manual
adjust (pool, used count, reason). The old manual slot tracker stays visible only for characters without class slots.
