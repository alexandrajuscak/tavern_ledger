# Class feature choices

Part of the class feature engine ([CLASS_FEATURE_ENGINE.md](CLASS_FEATURE_ENGINE.md)). Choices are data: the UI builds
the control from the definition (no form per feature).

## Definition (`class_feature_choices`)

| Column | Meaning |
|---|---|
| `feature_version_id` | the feature the choice belongs to |
| `kind` | `option`, `skill`, `expertise`, `language`, `tool`, `weapon`, `item`, `proficiency_group`, `ability`, `spell`, `asi`, `free_text`, `number`, `subclass` |
| `min_picks` / `max_picks` | required / allowed number of values; `config.picks_by_level` = `[[level, picks], ...]` scales both |
| `level` | class level at which the choice opens (never before its unlock) |
| `parent_choice_id` + `parent_option_id` | dependent sub-choice: open only while that option is chosen in the same unlock |
| `config` | `from` (allowed values), `exclude`, `spell_list`, `spell_level`, `max_spell_level`, `points` (ASI), `keys` / `total` (number), `group`, `category` |
| `allow_free_text` | values `text:...` allowed in addition to the structured kind |
| `replaceable` | the rules allow changing it later (Martial Versatility, Eldritch Versatility) |
| `applies_to` | `always`, `primary_class`, `multiclass` |
| `prerequisites` | structured (see below) |

Options (`class_feature_choice_options`): id, label, short summary, `option_group` (shown as groups), `data`, own
`prerequisites`. Effects and resources can be bound to an option (`option_choice_id` + `option_id`): a fighting-style
option is just an option with its effect.

A choice is stored per **unlock instance**: the same ASI feature unlocked at levels 4 and 8 has two independent choices.

## Character storage

`character_feature_choices` (character, class row, unlock, choice, `manual_status`: `applied_manually` for an ASI already
in the scores, `confirmed` for a prerequisite the DM allowed) and `character_feature_choice_values` (pick, value). Values:
option ids, skill / language / item / group ids, ability keys, spell version ids, `str:2` (ASI), `feat:<name>`
(placeholder), `text:<...>`, `key:n` (number). The subclass choice is the class row's `subclass_version_id`.

## Status (read model)

| Status | Meaning |
|---|---|
| `complete` | enough valid values (ASI: the points add up, or a feat, or "already in my scores") |
| `incomplete` | open, fewer values than required — listed under incomplete choices |
| `over_selected` | more values than allowed now (e.g. after a level decrease that lowered `picks_by_level`) |
| `optional` | `min_picks = 0`, nothing chosen |
| `locked` | its feature is not active yet / level not reached |
| `disabled` | the parent option is not chosen |
| `not_applicable` | primary-class-only choice on a multiclass row, or the other way round |
| `inactive_preserved` | values are stored but the choice is not open (feature inactive, level lowered, parent changed); kept, not applied |
| `invalid` | expertise in a skill the character is no longer proficient in (expertise is not applied) |

Changing the parent option or lowering the level never deletes a selection.

## Validation (`set_character_feature_choice`)

Refused: unknown option / skill / language / item / group / ability; a spell not on `config.spell_list` or of the wrong
level; duplicates; more than `max`; fewer than `min` (unless importing); a choice of an inactive feature; a choice that
is not open yet; a dependent choice before its parent; a choice not applicable to this class row; expertise without
proficiency (manual, lineage or class) or a second expertise in the same skill; an ASI over its points or a feat
combined with increases; an option whose evaluable prerequisite is unmet.

## Prerequisites

`{"all": [...]}` or `{"any": [...]}` with items:

| Type | Evaluated | Blocks? |
|---|---|---|
| `class_level`, `total_level`, `subclass`, `choice` | always (structural) | yes (unlock inactive / selection refused) |
| `ability`, `proficiency`, `spell`, `feature`, `spellcasting` | with derived data (read model, write RPC) | at selection: yes; later (e.g. a score lowered): warning only |
| `text` | needs a manual confirmation (`manual_status = confirmed`) | no; warning "confirm with your DM" |
| anything unknown | `unknown` | never |

## Ability Score Improvement

Kind `asi`, `config.points = 2`, `allow_feat`. Options: +2 to one ability, +1 to two, or a feat placeholder
(`feat:<name>`, no mechanics until the feat catalog exists). Applied only when chosen; "Already included in my ability
scores" keeps it complete without adding the bonus. Incomplete ASIs are listed. Scores above 20 are warned about.

## UI

The Features tab renders each choice inside its feature card: radio buttons (one), checkboxes (several), grouped options,
a subclass select, a spell select filled from the class spell list, ASI controls, number inputs, text. Status badges,
prerequisite notes, "Opens at level N", "Depends on an earlier choice", "Kept, inactive". Save / Clear per choice; the
server answers with the full resolved state.

<!-- 20261019 governance/feats/content -->
## Feat instead of an Ability Score Improvement (20261019)

The ASI choice offers "Choose a feat…" next to the ability increase (`js/feature-ui.js`): the feat picker opens in `pick`
mode with eligibility for the character, and the value is stored as `feat:<version id>`. The feat's own choices are then
made on the Feats card. Older free-text values (`feat:<name>`) stay allowed and are reported as unresolved. In a campaign
the choice is governed (`choice.asi` / `choice.feat`).
