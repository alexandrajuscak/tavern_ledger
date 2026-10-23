# Custom feats

DM-authored feats for a campaign. They become normal rows of the feat catalog ([FEAT_DATA_MODEL.md](FEAT_DATA_MODEL.md)),
so prerequisites, choices, effects, the picker and the derived stats treat them exactly like official feats. Lifecycle:
[CUSTOM_CONTENT_LIFECYCLE.md](CUSTOM_CONTENT_LIFECYCLE.md).

## Definition

| Field | Meaning |
|---|---|
| version `ruleset` | 2024 or 2014 (a custom feat belongs to one ruleset; it is never merged with another version) |
| `category` | general, origin, fighting_style, epic_boon, other |
| `repeatable` | once, repeatable, repeatable_distinct (+ `distinct_choice`: the choice that must differ), `max_count` |
| `min_level`, `prerequisite_text` | shown in the picker |
| `prerequisites` | [{kind: character_level / ability / armor_proficiency / spellcasting / lineage / feat / text, target, value, label, group}] – evaluated by `_feat_prereq_eval`; `text` needs the DM's confirmation |
| `choices` | [{key, kind, label, min, max, config, options}] – the editor's *Ability Score Increase* block becomes an `ability_increase` choice {amount, max, from} |
| `effects` | [{type, target, value, value_text, choice, activation, conditions, label}] – speed_bonus, ac_bonus, initiative_bonus, hp_per_level, hp_flat, ability_bonus, save_bonus, attack_bonus, damage_bonus, resistance, proficiency, expertise, sense, informational |
| `spells` | [{spell, choice, mode, ability, ability_choice, uses, uses_slots, label}] → `feat_spell_grants` |
| `resources` | [{key, name, max: {fixed} or {terms: [{of: proficiency_bonus}]}, recharge}] → `feat_resource_grants` |

Publishing creates `feats` + `feat_versions` (`status = 'homebrew'`, source *Campaign custom feat*), prerequisites, choices
and options, effects, spell and resource grants. Automation is `automated` when every effect is mechanical,
`partially_automated` when an effect is a reminder, `informational` without effects or choices.

## How it behaves

* Campaign members see it in the feat picker with the **Campaign custom** badge. Picking it is governed by `choice.feat`
  (and `content_allow_custom`); the DM grants it as `dm_grant` or `campaign_reward` from Assign.
* Effects reach the character through `_character_feat_effects` (derived stats, proficiencies, HP), resources and spells
  through `_sync_character_feats`, exactly like official feats ([FEATS.md](FEATS.md)).
* Backgrounds (custom or official 2024) can grant a custom origin feat.

Tests: `dm_content_tests.sql` DC24 (a reward applies speed 30 → 35) and DC28 (a custom background with its origin feat),
`governance_api_test.py` GA25, `dm_space_ui_test.py` DS30 (the feat appears with the campaign badge).
