# Class feature engine

Migration `20261015001800_class_feature_engine.sql`. A data-driven engine for class and subclass features: nothing in the
frontend or the derived-stats code knows a class or feature by name.

```
class version + class level + subclass version + feature unlocks + choices + optional features + resources + effects
  = resolved class state (get_character_class_features)
```

Related: [CLASS_FEATURE_CHOICES.md](CLASS_FEATURE_CHOICES.md), [CLASS_RESOURCES.md](CLASS_RESOURCES.md),
[SUBCLASS_FOUNDATION.md](SUBCLASS_FOUNDATION.md), [FIGHTER_IMPLEMENTATION_PLAN.md](FIGHTER_IMPLEMENTATION_PLAN.md),
audit: [CLASS_FEATURE_ENGINE_AUDIT.md](CLASS_FEATURE_ENGINE_AUDIT.md).

**Status:** the engine is complete; the **official** feature catalog is empty. Classes are filled in one by one, Fighter
first. Synthetic test content ("Engine Test Class") lives only in
`supabase/tests/fixtures/class_feature_engine_fixture.sql` and is marked `content_scope = 'test'`.

## Catalog

| Table | Meaning |
|---|---|
| `class_features` | canonical identity of a feature (class, optional subclass, name, scope) |
| `class_feature_versions` | the rules implementation of one source: name, short project-authored summary (no rules prose), source book / label / URL, source status (official, optional rule, playtest, test fixture), current / legacy, `superseded_by_version_id`, **automation**, activation, repeatable |
| `class_feature_unlocks` | class version **or** subclass version + class level → feature version; `is_optional`, `replaces_unlock_id` + `replacement_mode` (`replace` / `modify`), structured `prerequisites`, display order |
| `class_feature_scaling` | scaled values: `[[level, value], ...]` by class (or total) level: use counts, dice, bonuses, ranges, attack counts |
| `class_feature_choices` / `_options` | structured choices (see CLASS_FEATURE_CHOICES.md) |
| `class_feature_effects` | structured effects incl. proficiency, spell and attack grants |
| `class_feature_resources` | resource definitions (see CLASS_RESOURCES.md) |

A legacy feature version is never replaced automatically by a newer one: unlocks point at explicit feature versions, and a
class version change keeps the old selections for review.

### Automation status

`automated` (fully applied), `partially_automated` (part calculated, the rest is the player's / DM's), `informational`
(shown with level and source; no mechanics applied), `unresolved` (could not be represented yet). Each effect has its own
automation; an `informational` effect is listed but never applied. The UI shows a badge per feature and a coverage line.

## Unlock resolution

`_character_feature_unlocks(character)` returns every unlock of every class row with a status:

| Status | Meaning |
|---|---|
| `active` | level reached, optional feature selected, subclass active, structural prerequisites met, not replaced |
| `locked` | class level below the unlock level |
| `available` | optional feature that is not selected |
| `replaced` | an active replacement with `replacement_mode = 'replace'` points at it |
| `subclass_inactive` | subclass feature while the subclass is inactive (below its level, other class version) |
| `prerequisite_unmet` | a structural prerequisite (class level, total level, subclass, chosen option) is not met |

Raising the level activates features, opens choices and recalculates resources and scaling. Lowering it deactivates them;
their effects stop, their resources become inactive and their choices are kept as `inactive_preserved`. Nothing is
deleted. Removing a replacement restores the base feature.

## Effects

`class_feature_effects.effect_type`: `proficiency` (skill, save, armor, weapon, tool, group, language), `expertise`,
`ability_bonus` (ASI), `ac_bonus`, `ac_formula` (unarmored defense), `attack_bonus` / `damage_bonus` (weapon conditions
`ranged`, `melee`, `one_handed_melee_only`), `save_bonus`, `initiative_bonus` (value or proficiency bonus), `speed_bonus`,
`resistance`, `immunity`, `skill_advantage` / `skill_disadvantage`, `carrying_capacity_bonus`, `spell`, `attack`,
`extra_attack`, `critical_range`, and the placeholders `attunement_limit`, `ritual_casting`, `spellcasting_source`,
`resource_modifier`, `informational` (stored, shown, not applied yet).

Activation (`_character_class_effects`): the feature must be active; `min_level`; `applies_to` (`always`,
`primary_class` = only for the first class, `multiclass` = only when multiclassing into it); option filter (only while an
option is chosen); values from a choice; equipment conditions `armor: worn | none | not_heavy`, `shield: worn | none`;
an ASI marked "already in my scores" adds nothing. Temporary stances are never represented as permanently active.

Removing a class removes only the effects of that class row: manual proficiencies, lineage grants, item effects, other
spell sources and manual attacks are separate sources and stay.

## Grants in the existing read models

- **Derived stats** (`get_character_derived_stats`): additive class effects go through `_character_effects` (AC
  breakdown, inactive effects, ability sources); proficiency matching includes class grants; the class layer adds skill
  `class_proficient` / `class_expertise` (expertise only for a skill proficient from any source), save
  `class_proficient` (primary class), class proficiencies in the list with `source_type = 'class'`, languages, weapon
  conditional bonuses, `feature_attacks`, `attacks_per_action` (Extra Attack does not stack: highest), `critical_range`,
  initiative, immunities, unarmored AC formulas (competing with 10 + DEX only when no armor is worn) and `class_features`.
- **Spellbook** (`get_character_spellbook`): feature spells are grants of the source `feature:<class row>`
  ("<Class> features"): always prepared / known, counts-against flags (reported), slot use, ritual, casting ability (effect
  data or the class's ability). The class's own prepared count never includes them. Deactivating the feature removes only
  this source; another source of the same spell stays.
- **Attacks**: `feature_attacks` (name, ability incl. `finesse` / `spell`, dice by level, damage type, range). Contextual
  legality (Sneak Attack, once per turn, advantage) is informational.

## Resolution order

1. stored character data → 2. class versions and levels (total level, proficiency bonus) → 3. primary-class rules →
4. subclass selection → 5. class feature unlocks → 6. optional and replacement features → 7. feature choices →
8. subclass feature unlocks → 9. class / subclass proficiencies → 10. class / subclass spell grants → 11. active feature
effects → 12. class resources → 13. lineage effects → 14. equipment and item effects → 15. manual overrides.

In the derived-stats code the additive layers are summed (order does not change a sum): the 1500 core computes base
data, lineage and items, the class feature effects joined into `_character_effects` and `_proficiency_match`, then the
class layer wrapper; the manual AC override still wins last.

## Read model

`get_character_class_features(character)` (RLS: owner, campaign DM, admin; never writes): per class row the subclass
(selected, selection level, status, options), features (status, automation, scaling now / next, replaces / replaced by,
choices, resources, effects with active state and reason, source link), choices (status, values with labels and
prerequisite results, options), next level preview, review items (selections that no longer match the version /
subclass); plus resources, incomplete choices, warnings, automation coverage, grants (proficiencies, spells, attacks,
attack count, critical range, effects), the resolution order and limitations.

## Level change and class version change review

`preview_character_class_change(character, class row, level?, version?)` makes the change in a savepoint, reads the full
state, rolls the savepoint back and returns the difference: level, total level, proficiency bonus, features activated /
deactivated, choices added / made inactive, resource changes (maximum, die, active), standard slots, Pact Magic, spell
access and prepared limit, subclass status, proficiency changes, new warnings and review items. Nothing is stored. The
Bio level select and the version editor show it and apply the change only after confirmation (`set_character_class`).

A version change keeps the subclass (shown as incompatible when it belongs to another version) and the stored choices
(listed as review items). Choices are not mapped between versions automatically.

## Write path (RPCs only; RLS forbids direct writes)

`set_character_feature_choice`, `set_character_optional_feature`, `set_character_subclass` (through
`set_character_class`), `expend_character_resource`, `restore_character_resource`, `set_character_resource_state`,
`import_character_class_features`. All are security definer with a fixed `search_path`, check `auth.uid()` and
`can_access_character`, lock the character row (one change at a time), validate that the class row, unlock and choice
belong together, and never accept an owner id.

## Security

Catalog tables: readable by everyone, writable by nobody through the API. Character tables (`character_feature_choices`,
`_values`, `character_optional_features`, class resource rows): readable by owner / campaign DM / admin, written only by
the RPCs. A forged resource key of another character is refused ("not granted").

## Limitations

- Temporary features (stances, Rage, concentration) are informational; there is no active-effect system yet.
- `attunement_limit`, `ritual_casting`, `spellcasting_source`, `resource_modifier` effects are stored and shown only.
- `counts_against_known_limit` of feature spells is reported, not enforced.
- The ASI cannot raise a score above 20 by the rules; the engine warns (`ability_above_20`) but does not cap.
- Feats are a placeholder (`feat:<name>`) until a feat catalog exists.
- Multiclass proficiency lists are represented with `applies_to`; no official class data uses them yet.

## Future class compatibility review

How the engine will carry the other classes; "gap" marks an additive extension (no redesign) to make in that class's task.

| Class | Needs | How |
|---|---|---|
| Rogue | Expertise, Sneak Attack dice, Cunning Action, subclass | `expertise` choice (two unlocks); `class_feature_scaling` dice `[[1,"1d6"],[3,"2d6"],...]` shown on an informational attack modifier (eligibility contextual); Cunning Action informational; subclass unlock at 3 |
| Wizard | spellbook, Arcane Recovery, prepared spells, school, copying spells | existing spellbook source (1600 / 1700); Arcane Recovery = resource `fixed 1` long rest + informational slot recovery (gap: an RPC that restores slots up to half the level, later); school = subclass at 2; copying is a spellbook action (future) |
| Cleric | prepared casting, Channel Divinity, domain spells | prepared limit (1700); resource table `[[2,1],[6,2],[18,3]]` short rest; domain spells = subclass `spell` effects with `always_prepared` and `min_level`; subclass at 1 |
| Bard | Bardic Inspiration, die scaling, Expertise, Jack of All Trades, Magical Secrets | resource `ability cha, minimum 1` + `die_by_level`, recovery long → short at 5 (gap: a recharge-by-level column or two resource rows with `min_level`); Jack of All Trades: gap `skill_half_proficiency`; Magical Secrets = `spell` choice with any list (`config.spell_list` omitted, `max_spell_level`), `counts_against_known_limit` |
| Sorcerer | Sorcery Points, Metamagic, slot conversion | resource `class_level` long rest; Metamagic = option choice (`picks_by_level`) once a metamagic option list exists; Font of Magic conversion uses temporary slots (1700) — future RPC |
| Paladin | Lay on Hands, Divine Smite, auras, oath spells, Channel Divinity | resource `class_level × 5` (pool); Divine Smite informational (slot use is a player action); aura bonus = `save_bonus` with value = CHA (gap: ability-valued effect) — informational until then; oath spells like domain spells |
| Ranger | replacement features, fighting style, subclass, companions | optional unlocks with `replaces_unlock_id` (TCE Deft Explorer, Favored Foe); option choice; companion = informational (future companion engine) |
| Warlock | Pact Boon, invocations with prerequisites, Mystic Arcanum, patron spells | option choice; invocations = option choice with `picks_by_level`, `replaceable`, option prerequisites (`class_level`, `feature`, `spell`); Mystic Arcanum = 1700 `character_resources` free-cast rows or feature `spell` effects with `uses` 1 long rest; patron expanded list = subclass data |
| Druid | Wild Shape uses, creature catalog, transformation | resource table `[[2,2]]` short rest; forms and transformation state: future engines ([WILD_SHAPE_FUTURE_DESIGN.md](WILD_SHAPE_FUTURE_DESIGN.md)); features informational until then |
| Monk | unarmored defense, martial arts dice, Ki, movement | `ac_formula` (10 + DEX + WIS, no armor / shield) — implemented and tested; `attack` with `dice_by_level` and ability `finesse`; resource `class_level` short rest; `speed_bonus` with `min_level` effects and `armor: none` (gap: `shield: none` combined — supported) |
| Artificer | infusions, attunement limit, item modifiers, companions | `attunement_limit` effect stored (gap: inventory attunement check must read it); infusions = future item-modifier engine; Steel Defender = future companion |

No class requires a destructive change: every gap above is a new effect type, a new column or a new RPC on top of the
existing tables.

<!-- 20261019 governance/feats/content -->
## Feats, governance and requests (20261019)

* Feats are a second effect layer: `_character_feature_effects` = class effects ∪ feat effects (`_character_feat_effects`,
  same row shape), read by the derived stats, proficiencies and attacks ([FEATS.md](FEATS.md)).
* An Ability Score Improvement choice can hold `feat:<version>`; it is validated by `_cf_choice_error` (eligibility,
  repeatability) and resolves as a feat grant `asi:<class row>:<unlock>:<choice>` with the class feature as source.
* In a campaign, class, subclass, feature and optional-feature changes are governed (`build.*`, `choice.class_feature`,
  `choice.optional_feature`); a refused change becomes a request whose ops call the same RPCs
  ([APPROVAL_WORKFLOWS.md](APPROVAL_WORKFLOWS.md)). Confirming a text prerequisite is DM-only.
