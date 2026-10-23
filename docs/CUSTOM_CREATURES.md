# Custom creatures and Wild Shape forms

DM-authored stat blocks for a campaign: beasts a Druid may learn as Wild Shape forms, creatures that can be companions,
or plain campaign monsters. They are rows of `creatures` ([CREATURE_DATA_MODEL.md](CREATURE_DATA_MODEL.md)) with
`content_scope = 'campaign'`. Lifecycle: [CUSTOM_CONTENT_LIFECYCLE.md](CUSTOM_CONTENT_LIFECYCLE.md); Wild Shape rules:
[WILD_SHAPE_RULES.md](WILD_SHAPE_RULES.md).

## Definition

`size`, `creature_type`, `subtype`, `alignment`, `armor_class`, `armor_type`, `hit_points`, `hit_dice`, `speed`
{walk, climb, swim, fly, burrow}, `abilities` {str … cha}, `saving_throws`, `skills` {skill: bonus}, `senses`
{darkvision, passive_perception …}, `languages`, `challenge_rating`, `xp`, `proficiency_bonus` (default from the CR),
`damage_vulnerabilities` / `damage_resistances` / `damage_immunities` / `condition_immunities`, `traits` [{name, summary}],
`actions` [{name, kind: melee / ranged / other, attack_bonus, reach, damage [{dice, type}], summary}], `reactions`,
`wild_shape_eligible` (default true for a beast), `companion_eligible`.

Publishing creates the `creatures` row with the campaign, the author, `mechanics_status = 'complete'` and source label
*Campaign custom*; the attack and damage numbers of the stat block are used as written.

## Wild Shape

* A campaign creature is **never** a Wild Shape option by itself: `_form_options` lists it only after a **DM grant**
  (`set_seen_forms(..., 'dm_grant')`, from Assign → *Wild Shape form*). A player cannot mark a campaign creature as seen
  (DM-only), even in a relaxed campaign.
* After the grant the normal Wild Shape limits apply (Druid level, CR, fly / swim speeds by level, Circle of the Moon);
  the form is taken, damaged and left through the same RPCs as official beasts.
* Archiving hides it from new grants; grants already made are not removed (the general archive rule).

Tests: `dm_content_tests.sql` DC25–DC26, `governance_api_test.py` GA26–GA27, `dm_space_ui_test.py` DS31–DS34.
