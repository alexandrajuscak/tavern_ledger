# Custom spells

A DM-authored spell for one campaign. Lifecycle, rights and assignment: [CUSTOM_CONTENT_LIFECYCLE.md](CUSTOM_CONTENT_LIFECYCLE.md).
Editor: DM Space → Content Library → New → Spell (`js/content-editors.js`).

## Definition (`dm_content_versions.definition`)

| Field | Meaning |
|---|---|
| `level` | 0 (cantrip) – 9 |
| `school` | `spell_schools.id` |
| `class_lists` | class spell list ids (`wizard-spell-list` …); the spell is added to those lists **for this campaign only** (`class_spell_list_entries.provenance = 'campaign_custom'`) |
| `casting_time` | {unit: action / bonus_action / reaction / minute / hour / special, amount, raw}; `reaction_trigger` |
| `range` | {type: self / touch / distance / sight / unlimited / special, distance, unit} |
| `area` | {shape: cone / cube / sphere / line / cylinder / radius, size} |
| `duration` | {type: instantaneous / timed / until_dispelled / permanent / special, amount, unit}; `concentration`, `ritual` |
| `components` | {v, s, m, material, cost_gp, consumed} |
| `attack_type` / `save_ability` | melee / ranged spell attack, or the saving throw ability |
| `effects` | [{category: damage / healing / temp_hp / condition / utility / other, dice, flat, adds_spell_mod, damage_types, half_on_save, timing, scaling {type: none / slot_level / character_level, dice, base}, notes}] |
| `higher_levels` | text |

The version's `ruleset` (2014 or 2024), `name`, `summary`, `player_text` (description players read) and `dm_notes` are
version columns. Publishing creates `catalog_spells` + `spell_versions` (`status = 'current'`, `rule_status = 'homebrew'`,
source label *Campaign custom*, no source URL), `spell_effects` and their damage types. The automation level is
`partially_automated` when effects exist, otherwise `informational`.

## How it behaves

* Members of the campaign see it in the spell catalog and the spellbook search (with the **Campaign custom** badge); other
  users never see it. The DM notes are never part of a player read model.
* A player learns or prepares it through the normal spellbook RPCs; the campaign rule `spell.assign_custom` decides whether
  that needs approval (Standard / Strict: yes). The DM can assign it directly (`known`, `innate`, `always_prepared`).
* Attack and save numbers, damage dice and scaling come from the existing spell engine ([SPELLS.md](SPELLS.md)); there is no
  separate code path.
* A new version supersedes the old one for new picks; characters keep the version they learned until the DM assigns the
  new one. Archiving hides it from new picks only.

Tests: `dm_content_tests.sql` DC1, DC3–DC15 (rights, draft visibility, validation, publish once, visibility for members and
outsiders, no in-place edits, exact-version assignment, new version, archive), `governance_api_test.py` GA16–GA22,
`dm_space_ui_test.py` DS7–DS13 (the editor end to end: draft, preview card, publish, player view, assignment, spellbook).
