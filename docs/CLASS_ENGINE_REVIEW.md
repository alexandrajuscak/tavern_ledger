# Class engine review

State after the "implement all official classes" task (2026-10-17). All 13 official classes (2014 rules; Artificer from
Tasha's) are implemented on one generic engine: no runtime code names a class. Every class and subclass is data in
`data/classes/features/*.json` and `data/classes/options/*.json`, validated and turned into
`supabase/seed/class_features.sql` by `scripts/data-migration/generate_class_feature_seed.py`. Coverage per class:
[CLASS_COVERAGE.md](CLASS_COVERAGE.md). Progress log: [CLASS_IMPLEMENTATION_LOG.md](CLASS_IMPLEMENTATION_LOG.md).

## Engine building blocks

| Block | Where | Used by |
|---|---|---|
| Features, versions, unlocks by level, optional replacements (Tasha's) | `20261015001800` | every class |
| Scaling tables (dice, numbers, text, formulas) | `class_feature_scaling` | Sneak Attack, Rage Damage, Martial Arts, Ki DC ... |
| Choices (skill, expertise, tool, language, ability, ASI / feat, spell, option catalog, subclass), prerequisites, picks by level, distinct groups | `20261015001800`, `…000100`, `…000300`, `…000500` | every class |
| Effects: proficiency, expertise, half proficiency, ability bonus / maximum, AC formula / bonus, speed, senses, resistances / immunities, condition immunities, save advantage / bonus (aura), attack / damage bonus (weapon and ability conditions), extra attack, critical range, attacks, attack riders (dice by level or by slot, slot pool), spell grants (always prepared, at will, without slot), spell list additions, attunement limit, feature save DC, transformation rules | `class_feature_effects` + derived wrapper | all |
| Resources: uses, points, pools (spend by amount), dice, recharge by level, short-rest partial recovery, slot recovery (budget, max level, pact pool), slot conversion | `class_feature_resources` | Second Wind, Ki, Lay on Hands, Arcane Recovery, Font of Magic, Eldritch Master ... |
| Spellcasting sources per class row, Pact Magic, multiclass slots, spellbook acquisition, temporary slots | `20261015001700`, `…000300` | all casters |
| Active states (effects only while a state is on; starting spends a resource; rests end them) | `…000700` | Rage, Mindless Rage |
| Creature catalog, transformations (form HP, carry-over), companions | `…000800` | Wild Shape, Circle Forms, Elemental Wild Shape, Wild Companion, Homunculus Servant |
| Infusions (managed item modifiers on inventory instances), attunement limit by class effect, attunement required by a modifier | `…000900` | Infuse Item, Replicate Magic Item, Magic Item Adept / Savant / Master |
| Guided class setup (Add Class preview with prerequisites, starting equipment review) | `…000600` | all classes |

## Safety and integrity

- RLS on every table; character state tables have read policies through `can_access_character` (owner, campaign DM,
  admin) and **no direct write grants**: all changes go through SECURITY DEFINER RPCs that check `auth.uid()`, use
  `set search_path = public, pg_temp`, lock the character row for the change, and validate everything.
- Managed item modifiers (infusions) cannot be applied or removed with the generic modifier policies; only the infusion
  RPCs may (guarded by a transaction-local setting).
- Catalog changes are idempotent upserts with scoped cleanup; checksums are tested (seed run twice).
- Every migration has a rollback (newest first, refusing while official content still uses its objects); the catalog
  rollback refuses while characters use catalog subclasses or have infused items.

## Automation honesty

Every feature carries `automation` (Automatic / Partly automatic / Reminder) and notes on what is applied and what the
player resolves. Totals: 74 automatic, 78 partly automatic, 94 reminders, 0 unresolved (246 feature versions).
Examples of deliberate reminders: Reckless Attack, Frenzy exhaustion, Stunning Strike targets, Experimental Elixir effects,
Relentless Rage DCs, beast form ability substitution rules beyond the stat block.

## Known gaps (documented, not hidden)

- Starting wealth: only the Artificer page states it (5d4 × 10 gp); other class pages do not, so `starting_gold` is empty.
- Artificer multiclass proficiencies: not on the class page and not in the SRD; not granted automatically.
- Rage Damage is added to equipped STR melee weapons; thrown and unarmed STR attacks are a reminder.
- Wild Shape: the beast stat block, form HP and carry-over are automated; mixing the character's mental scores and
  proficiencies into beast attacks is shown as a rule, not computed.
- Infusions whose effect is not numeric (Boots of the Winding Path, Resistant Armor's chosen type ...) are shown as a
  note on the item; item-type limits that the catalog cannot express (a helmet, a ring) accept any gear with the hint.
- Infusion bonuses after a level change wait for "Update infusions" (outdated flag), never silently.
- Mystic is excluded (abandoned UA); Unearthed Arcana subclasses and options are a backlog (92 subclasses) and appear only
  as playtest options requiring DM permission where the class page lists them.

## Performance note

The derived read model resolves all class effects per call (about 80 ms for one derived read and 300 ms for the class page read model on the local stack, measured on a sample character).
The per-class SQL suites recompute it many times (20-level snapshots); on the plain PostgreSQL test container that takes
minutes per class. A materialized per-character effect cache would be the next optimization if the hosted project shows
the same latency.
