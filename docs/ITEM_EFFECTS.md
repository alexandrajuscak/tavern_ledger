# Item effects (R-D1, migration 20261114000500)

Magic items can change a character automatically: a bonus to an ability score, a skill, a saving throw, Armor Class,
Initiative or speed, or a spell the character can cast. The DM authors them in **DM Space → Content → Item**; the sheet
applies them and shows where each bonus comes from. Rollback: `supabase/rollback/rollback_item_effects.sql` (keeps every
authored effect in backup tables).

## When an effect applies

| "When" in the editor | Meaning |
|---|---|
| While equipped | the item is in an equipment slot |
| While attuned | the character is attuned to it (an item that requires attunement only works attuned) |
| While equipped and attuned | both |
| While carried | the item is in the character's own inventory |
| Permanent, when used | applied **once** when the consumable is used up, and it stays after the item is gone |

Effects of an item that is not equipped / attuned are listed as **Not counted** (with the reason) next to the value they
would change: the AC breakdown and the tooltips of saving throws, skills and Initiative (the derived stats also carry them
for abilities and speed: `inactive_effects`).

## Effects

| Effect | Target | Value | Example |
|---|---|---|---|
| Ability score + | an ability | -10 … +10 | Belt: +2 Constitution |
| Ability score set to | an ability | 1 … 30 (never lowers a higher score) | Gauntlets of Ogre Power: Strength 19 |
| Skill + | a skill | -10 … +10 | +3 Religion |
| Saving throw + | an ability, or none = all saves | -10 … +10 | Cloak of Protection: +1 all saves |
| Armor Class + | — | -10 … +10 | +1 AC |
| Initiative + | — | -10 … +10 | +2 Initiative |
| Speed + / Speed − | — | feet | +10 ft |
| Resistance | a damage type | — | resistance to fire |
| Advantage / Disadvantage on a skill | a skill | — | advantage on Stealth |

Stacking: different items add up (a Ring and a Cloak of Protection give +2 to saves). "Set to" takes the highest. Two
items of the same stack group (seeded catalog data only) count once, the best one.

**Permanent ability increases** (Hag's Hair, Tomes and Manuals) are capped: the score goes up to 20 unless the effect has a
**Maximum score** (a Manual of Bodily Health: 22). A +1 at 20 applies nothing; the ability card shows "none applied: max 20".
They are applied after lineage and background increases, before "set to" effects and other item bonuses.

## Granted spells

Each granted spell has a source of power:

- **Uses per rest**: N free casts, its own counter, back after a short or a long rest (the rests recharge it);
- **At will**: no slot, no counter (cantrips, or "at will" items);
- **Uses the character's spell slots**.

The spell appears in the **Spells** tab marked "Magic item: <item>", with "1 of 1 left per long rest" and a **Use** button
(the counter is also a resource on the Play tab). The spellcasting ability is the one the DM chose, else the character's.
A spell from an item that is no longer equipped / attuned / carried disappears; its counter is kept (unattune and attune
again does not refill it). A permanent spell (from a used consumable) stays.

## Permanent effects of used items

Using a consumable with permanent effects writes them to the character **once per use** (a repeated request, e.g. a network
retry, uses nothing and applies nothing). Each is recorded with its source (`character_permanent_effects`): the ability
card shows "+1 Hag's Hair (permanent)". The **DM** sees a **Revert** button there (`revert_permanent_effect`): the bonus is
removed, the record stays with the date and the reason. Players have no access to the table; they see their own bonuses
through the sheet. Used from a party stash (no character), nothing permanent is applied.

## Unidentified items

An unidentified item works mechanically (the character wears it), but the player only ever sees its **disguise**: the
bonus source reads "Dull pendant", not the true name, on the sheet, in the spell source, the spell counter and in every
read channel (bundle, derived stats, `tl_cache`, Realtime rows of the spell tables). The DM sees "Periapt of the Lich
(unidentified)". After identification the true name appears. Using an unidentified consumable applies its permanent
effects, but the answer names none of them ("your DM tells you what happens").

## Authoring (DM Space)

DM Space → Content → New item (or New version of a published one) → sections **Effects (applied automatically)** and
**Granted spells** → Validate → Publish. Only DM content items can have effects; player homebrew cannot. Every published
version has its own catalog row and effects: copies players already hold keep the version they have.

### Examples

**Amulet of Speak with Dead** (wondrous item, requires attunement)
- Granted spells: Speak with Dead · Uses per rest · Uses 1 · Long rest · While attuned · Wisdom.

**Hag's Hair** (gear, consumable)
- Effects: Ability score + · Wisdom · 1 · Permanent, when used.

**Gauntlets of Ogre Power** (wondrous item, requires attunement)
- Effects: Ability score set to · Strength · 19 · While attuned (or While equipped and attuned).

**Cloak of Protection** (wondrous item, requires attunement)
- Effects: Armor Class + · 1 · While attuned; Saving throw + · (no target) · 1 · While attuned.

**Manual of Bodily Health** (consumable)
- Effects: Ability score + · Constitution · 2 · Permanent, when used · Maximum score 22.

## Data model

- `item_effects` (20261015001400) + kinds `initiative_bonus`, `skill_bonus`, activation `permanent`, column `max_score`.
- `item_spell_grants (item_id, seq, spell_version_id, casting at_will|spell_slots|per_rest, uses, recharge, activation, ability)`.
- `character_permanent_effects`: one row per applied effect / spell, per use request and unit; `reverted_at` instead of delete.
- Materialized grants: `character_spellcasting_sources.item_grant_key` (`ii:<inventory row>` / `pe:<permanent row>`),
  `character_spells`, `character_resources` (`item-…` / `itemp-…`, source type `item`). `_sync_item_spell_grants` runs from
  triggers on inventory rows, equipment, identification and permanent rows.
- Derived stats: `_character_item_effect_rows` (one source for every viewer, masked labels) → `_character_effects` →
  `_derived_stats_core`: `abilities.*.permanent_sources`, `saving_throws.*.item_sources`, `skills.*.item_bonus` /
  `item_sources`, `initiative.item_sources`, `inactive_effects` on abilities, saves, skills, initiative and speed,
  `permanent_effects`.

## Known limits

- An equipped "Ability score +" item is not capped at 20 (as before: up to 30); only permanent increases have a maximum.
- The spell source label stored for the player is the disguise; the DM's spellbook view shows the true name.
- Equipping / attuning an item with a granted spell writes the party log line "Spell added" (as feats do).
- Weapon actions, special and condition blocks of weapon cards come in R-D2.
