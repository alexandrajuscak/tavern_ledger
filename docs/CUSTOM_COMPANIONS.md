# Custom companion templates

A DM-authored companion (a cult's hound, a homebrew familiar, a mount) that the DM gives to characters. Lifecycle:
[CUSTOM_CONTENT_LIFECYCLE.md](CUSTOM_CONTENT_LIFECYCLE.md); companions in general: [CREATURE_DATA_MODEL.md](CREATURE_DATA_MODEL.md).

## Definition

| Field | Meaning |
|---|---|
| `creature` | a full stat block, same fields as a [custom creature](CUSTOM_CREATURES.md) |
| `hp_formula` | {base, per_level}: hit points of an instance (the DM can override per assignment with `hp_max`) |
| `rules` | text: initiative, commands, what happens when it drops to 0 HP |
| `rest_behavior` | text: how rests affect it |

Publishing creates a `creatures` row (`companion_eligible = true`, not Wild Shape eligible). The template's `dm_notes`
(e.g. "Spy of the cult") stay DM-only.

## Assignment

`dm_assign_content(template, characters, 'companion', {name, hp_max})` calls `add_character_companion` for each
character (as a DM grant) and links the instance to the template version (`character_companions.template_version_id`).
The player then manages the instance like any companion: current HP, notes, active – those are runtime and
player-managed in every preset. Adding a permanent companion themselves is `build.companion` (Standard / Strict:
approval); a campaign creature as companion is DM-only.

Tests: `dm_content_tests.sql` DC27, `governance_api_test.py` GA28, `dm_space_ui_test.py` DS35–DS36.
