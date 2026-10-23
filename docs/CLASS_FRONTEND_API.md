# Class frontend API

How the frontend reads and changes class data. Every rule (levels, slots, choices, limits, costs, prerequisites) is decided
by the database; the JavaScript modules only call RPCs and render what comes back. All write RPCs check `auth.uid()` and
`can_access_character` (owner, campaign DM, admin), run with a fixed `search_path`, lock the character row (`for update`)
for the duration of the change, and return the new read model. No module names a class: everything is catalog driven.

## Modules

| Module | Role |
|---|---|
| `js/class-api.js` | class rows, levels, slots, Pact Magic, rests, feature choices, optional features, resources, slot recovery / conversion, temporary slots, active states, guided setup (preview, starting equipment) |
| `js/class-ui.js` | Classes card (Bio tab), class editor (version / subclass), level change review, Slot Tracker |
| `js/class-setup.js` | guided **Choose class / Add class (multiclass)** dialog with live preview; starting equipment review |
| `js/feature-ui.js` | class page (Features tab): overview, Next actions, At a glance (attacks, riders, DCs, quick resources, states), subclass picker, features by level, choices, resources, level change review |
| `js/slot-actions.js` | slot recovery (Arcane Recovery, Natural Recovery, Harness Divine Power, Eldritch Master), Flexible Casting, slot riders (Divine Smite, Eldritch Smite) |
| `js/spell-api.js`, `js/spell-ui.js` | Spells tab: sources (DC / attack, spellbook), Add Spell (acquisition), readiness groups |
| `js/creature-api.js`, `js/creature-ui.js` | creature catalog, Wild Shape and companion API calls, Companions card |
| `js/wild-shape-ui.js` | Wild Shape idle panel, form picker (filters, favorites, compare), transformation review, active form sheet, HP / Combat Wild Shape / revert dialogs (docs/WILD_SHAPE_UI.md) |
| `js/infusion-ui.js` | Infused items card and Infuse dialog |

## Read models

| RPC | Returns |
|---|---|
| `get_character_class_summary(character)` | class rows (level, version, subclass, contribution, spellcasting counts), total level, proficiency bonus, caster level, warnings (multiclass prerequisites) |
| `get_character_spell_slots(character)` | standard slots, Pact Magic, temporary slots, slot mode and breakdown |
| `get_character_class_features(character)` | per class: features by level (status, automation, scaling, category), choices (status, options, castable level), subclass block, spellcasting, review items; resources |
| `get_character_resources(character)` | class and manual resources (max, remaining, die, recharge, config: slot recovery / conversion) |
| `get_character_derived_stats(character)` | abilities, saves (`class_bonus` from auras), skills, AC, speed, senses, resistances / immunities, `condition_immunities` (names) and `condition_immunity_sources`, proficiencies, weapon attacks with class bonuses, `feature_attacks`, `attack_riders` (`uses_slot`, `slot_pool`, `dice_by_slot`), `situational_advantages`, `feature_dcs`, `active_states`, `ability_maximums` |
| `get_character_spellbook(character)` | spells with grants, sources (DC / attack, spellbook summary, `expanded_spells`) |
| `get_character_states(character)` | states the active features declare (Rage): active, started_at, the resource it spends |
| `get_character_transformation(character)` | Druid level, total level, Moon, settings, resources, rules, the active form with its authoritative transformed `sheet`; every option with `status`, `allowed`, `reasons[]`, `reason` (compatibility), `cost`, `elemental`, `favorite`, `last_used`, `duration_minutes`; the last 12 events (docs/TRANSFORMATION_ENGINE.md) |
| `get_character_infusions(character)` | known infusions with item candidates and refusals, infused item limit, active infusions (`outdated` after a level change) |
| `preview_character_class_change(character, row, level, version)` | what a level / version change would do (nothing stored) |
| `preview_character_class_add(character, version, level, subclass)` | what adding a class would do: features, proficiencies, choices, slots, prerequisites of every class with scores, starting equipment (first class only) |
| `get_class_starting_equipment(version)` | groups, options, items with catalog candidates |
| tables (RLS read) | `creatures`, `character_companions`, `character_active_states`, `character_transformations`, `character_infusions`, `character_starting_equipment`, `class_starting_equipment` |
| `get_character_proficiencies(character)` | every proficiency with all its sources (manual, class, feature, lineage, background); docs/PROFICIENCY_RESOLUTION.md |
| `get_character_background(character)`, `get_background_catalog()` | background read models (docs/BACKGROUNDS.md) |

## Changes

| RPC | Effect |
|---|---|
| `set_character_class`, `remove_character_class` | add / change / remove a class row (level, version, subclass, primary) |
| `set_character_feature_choice`, `set_character_optional_feature` | store a choice (validated: kind, list, prerequisites, castable level) / switch an optional replacement |
| `expend_character_resource(character, key, amount)`, `restore_character_resource` | spend / restore; pools (Lay on Hands, Ki) by amount |
| `expend_standard_spell_slot`, `expend_pact_magic_slot`, restores, `set_spell_slot_state` | slots (manual correction needs a reason) |
| `recover_spell_slots(character, resource, levels)` | Arcane / Natural Recovery, Harness Divine Power; pool `pact` recovers every Pact slot (Eldritch Master) |
| `convert_spell_slot`, `use_temporary_spell_slot`, `restore_temporary_spell_slot` | Font of Magic |
| `short_rest_character`, `long_rest_character` | rests (resources, slots); every active state ends (`states_ended`) |
| `start_character_state(character, key, spend)`, `end_character_state` | Rage: start spends a use unless `spend = false` |
| `start_transformation(character, creature, options)`, `damage_active_transformation`, `heal_active_transformation`, `set_transformation_hp`, `end_transformation(character, reason)` | Wild Shape: server-checked form, cost and duration; equipment merge / drop / wear; damage at 0 ends the form and carries the excess over once (`result.carryover`) |
| `combat_wild_shape_heal(character, slot_level, pool, roll)`, `use_form_ability(character, ability, use / roll / restore, roll)` | Combat Wild Shape healing (one slot, validated roll); recharge and once-per-rest form abilities |
| `set_seen_forms`, `set_form_favorite`, `set_wild_shape_settings`, `set_transformation_equipment`, `change_transformation_hp` (compatibility) | seen forms and DM grants, favorites, seen rule (unrestricted: DM only), equipment during a form |
| `add_character_companion`, `update_character_companion`, `remove_character_companion` | companions (catalog or custom); HP clamped |
| `apply_infusion(character, infusion, item, replicate)`, `remove_infusion`, `refresh_infusions` | Infuse Item; managed item modifiers cannot be applied or removed directly |
| `apply_class_starting_equipment(character, version, selections)` | adds the chosen starting equipment to the inventory once (primary class only) |
| `set_character_spell_acquisition` | how a spell entered the spellbook |
| `set_character_background(character, version, ability, choices, replacements, options)`, `clear_character_background` | background selection (validated; choices may stay open) |
| `preview_background_equipment(character, package)`, `apply_background_equipment(character, package, picks)` | background equipment review, applied once |

## UI contracts

- Buttons use `data-action` (sheet dispatcher) or `data-cf-action` (class page handler); both are delegated on the sheet
  root, so a button works wherever it is rendered (class page, At a glance, Combat tab).
- `data-focus-key` keeps keyboard focus across re-renders; `restoreDrafts` keeps unsaved choice edits.
- Every dialog (`openModal`) closes with Escape and returns focus; status texts use `aria-live="polite"`.
- Errors from the database (`22023` validation, `23505` duplicates, `42501` access) are shown as toasts with the server's message.

<!-- 20261019 governance/feats/content -->
## Governance, feats and DM Space modules (20261019)

| Module | Purpose |
|---|---|
| `js/supabase.js` | wraps `supabase.rpc` and announces governance refusals (`TLAPR`, `TLDMO`, `TLDIS`, `TLLCK`) as the `tavern:governance` event; `isGovernanceError` |
| `js/store.js` | autosave never retries a governance refusal; refused build fields dispatch `tavern:save-refused` |
| `js/governance-api.js` | campaign rules, character governance, requests, audit |
| `js/request-ui.js` | lock / setup banner, pending tray, "Ask your DM" dialog, request list (mounted by the sheet) |
| `js/feat-api.js`, `js/feat-ui.js` | feat catalog, Feats card, picker (`assign` / `pick` / `view`), choices |
| `js/dm-api.js`, `js/dm-space.js`, `js/content-editors.js` | the DM Space ([DM_SPACE.md](DM_SPACE.md)) |
