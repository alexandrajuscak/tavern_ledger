# Feat system audit (2026-11-09)

Scope: all 408 official feat versions (2014 and 2024 rule sets kept separate) and campaign custom feats, through every way a
feat reaches a character: direct assignment (`character_feats`: direct, dm_grant, campaign_reward, approved_request, import),
background grant (`background_feat_grants`, optional parameter), lineage feat pick (`character_lineage_choices` value
`feat:<id>`, Variant Human / Custom Lineage) and class Ability Score Improvement pick (`character_feature_choice_values`
`feat:<id>`). The per-version table (classification, choices, spell / resource grants, Play / Spells visibility, automation,
granting backgrounds, defect) is in `docs/ACTIVE_GAMEPLAY_FEATURE_AUDIT.md` > Feats.

## Confirmed defects

| # | Feat(s) | Defect | Root cause | Fix | Production impact |
|---|---|---|---|---|---|
| D1 | **Magic Initiate 2024 and 2014** (every feat with a `spell_list` or `option` choice) | Choices of a feat granted by a **lineage** (Variant Human), a class **ASI**, a background without a fixed list, or a direct feat whose choices were skipped could not be completed: the spell-list radios were empty, the cantrip and level-1 pickers stayed at "Choose the spell list first", only the ability was saved, and the UI still said **"Choices saved."** | `get_character_feats` built each choice without its `options` (only the feat picker's `get_feat_detail` had them); `openFeatChoices` rendered `spell_list` options from `c.options \|\| c.config.options`, and Magic Initiate 2024's config holds only `parameter_map`. The background path worked only because Sage / Acolyte / Guide fix the list through `parameter_map`. | Server: every `spell_list` / `option` choice carries `options` (`20261109000100`). Client: `choicesWithOptions` falls back to the feat version's own options (older server, cached read); the save toast reports what is still open ("Saved, but not complete yet. Choose …") instead of "Choices saved." | **1 grant** (Variant Human → Magic Initiate 2024): 1 of 4 choices stored, no spells. Not auto-filled (the player chooses); now possible. |
| D2 | **Resilient 2014 and 2024** | Shown as "automated: Saving throw proficiency" but the save stayed unproficient. | `_character_feat_effects` resolved the save-proficiency effect, whose choice is the feat's +1 ability, with the ability as its **target**; the derived resolver reads `target = 'save'` + ability in `value_text`. | `_character_feat_effects`: such an effect is `target 'save'`, `value_text` = the chosen ability (`20261109000100`). Removal undoes it (feat_removal F17b). | **0** production characters hold Resilient (read-only check): no production derived value changes. |
| D3 | any feat with a stored choice that became invalid | An invalid stored value (a spell no longer on the chosen list, a removed option) stayed silently active. | `_sync_character_feats` checked only completeness. | INVALIDATED state: `_feat_choice_issues` re-validates stored values with the same rules as a save; such a grant is treated as incomplete (no stale spell grant) and Build says "Choose again: … is no longer valid". | **0** invalid stored values in production. |

Previously fixed and re-verified here: Magic Initiate via Acolyte / Guide / Sage (`20261031000100`, coalesce of fixed list),
feat removal (`20261107000100`, atomic, audited, idempotent), feat revision triggers (Realtime / Combat Builder).

Known and **not** changed (documented): ASI applied after the 20 cap (base 19 + ASI 2 = 21) — 0 production characters over
20 (read-only check, Boons excluded); many feats are descriptive ("See the source for the benefits", 162 versions): no Play card,
Build only.

## Choice state machine

`get_character_feats` returns per grant `state` and per choice `status` (`20261109000100`):

| State | Condition | Mechanics | Build shows |
|---|---|---|---|
| INCOMPLETE | a required choice has fewer picks than its minimum | effects that need the choice are inactive; **no spell source** (no partial grant) | "Next step: Choose Spell list, Cantrips …" + Choose… |
| COMPLETE → **APPLIED** | all required choices stored and valid | effects, spell source + spells, free-cast counters, resources active | the feat card, no next step |
| INVALIDATED | a stored value fails validation now | treated as incomplete: spells removed, nothing stale stays active | "Next step: Choose again: Cantrips is no longer valid" |
| PENDING APPROVAL | governance requires approval (standard preset) | nothing changes until the DM approves (TLAPR → change request) | the request in the campaign's Ask your DM flow |
| inactive | the granting source is no longer active (lineage changed, ASI feature inactive) | resources kept with their spent count but inactive; spells removed | "Inactive: lineage changed" |
| REMOVED | direct assignment removed | choices, feat-only spell source, resources, effects gone; revisions bumped; one audit event | gone from Build, Play, Spells |

A partial save stores the picks that were made (the next step names the rest); "Choices saved." appears only when nothing is
open.

## Spell-selecting feats — the 18-point workflow

Feats: Magic Initiate 2014 (list → casting ability from the list option), Magic Initiate 2024 (list + spellcasting ability),
Fey Touched 2014 / 2024 and Shadow Touched 2014 / 2024 (+1 ability → casting ability; one level-1 spell of two schools; fixed
Misty Step / Invisibility), Telekinetic / Telepathic (fixed spell, ability from the +1). Same shared mechanism for all
(`_store_feat_choices` → `_sync_character_feats`), so the fixes apply to every one of them.

| # | Check | Evidence |
|---|---|---|
| 1 | options load (also on the edit path) | FC2, FC15; browser F2 |
| 2 | options are eligible (list / level / school) | FC9 (off-list refused), FC18 (wrong school refused); `_feat_choice_value_error` |
| 3 | selection is saved | FC4, FC6; browser F4b |
| 4 | selection reloads | browser F5 |
| 5 | complete choices create grants | FC6, FC16, FC19 |
| 6 | grants appear in Spells | FC8; browser F8 |
| 7 | correct source label | FC7 ("Magic Initiate (Lineage: Variant Human)") |
| 8 | correct casting ability | FC7 (WIS), FC16 (INT from the Wizard list option), FC19 (WIS from the +1) |
| 9 | spell attack / save DC | from the source's casting ability in the spellbook (spell_tests, FC8) |
| 10 | free-use state | FC16 (one free cast of the level-1 spell), FC19 (two free casts, always prepared) |
| 11 | no duplicate source | FC22, FC23; production read-only: 0 duplicates |
| 12 | replacement | FC10 (one cantrip swapped, no orphan) |
| 13 | removal removes only that source | FC20; feat_removal F11–F13 |
| 14 | another source keeps the spell | FC20 (class Guidance stays), feat_removal F12 (background Magic Initiate keeps it) |
| 15 | export / import keeps the choice | FC21; feat_removal F28–F29 |
| 16 | progressive Spells / feats bundle | FC11 (`get_character_reads` serves options and state; global cache revision bumped) |
| 17 | legacy fallback | browser F9 (`?fluent=0`) |
| 18 | Realtime to another session | browser R1 / R2 (grant and removal reach the open Play tab); feat revision triggers |

## Direct removal and source-granted feats

Unchanged backend (`20261107000100`, `docs/FEAT_REMOVAL.md`): one atomic `remove_character_feat` with a server-generated
consequence preview (`preview_character_feat_removal`, executed and rolled back), governance gate after the access check, one
audit event, idempotent, revision + cache invalidation. Source-granted feats have no removable row: Build shows "Granted by your
background / lineage / an Ability Score Improvement" with **Change background… / Change lineage choice… / Change choice…**, and
never a Remove button the backend would refuse. New in this release: removal also removes the Play card and Ready-to-use counter
of the feat (targeted re-render), and Resilient's save proficiency.

### Test matrix (32 items)

| # | Item | Evidence |
|---|---|---|
| 1 | direct assignment | F1 |
| 2 | owner removal, relaxed governance | F2, F2b |
| 3 | DM removal | F3, F4c; browser F3 |
| 4 | admin removal | FC28 (an administrator removes directly in an approval campaign; audited once) |
| 5 | approval-required request | F4, F4b, P3, FC27; browser F4–F4d |
| 6 | locked character | F8, F9, P4; browser F8 |
| 7 | unrelated user denied | F5, F7 |
| 8 | unrelated DM denied | F5 (DM of another campaign gets the same not-found) |
| 9 | anonymous denied | F6 |
| 10 | duplicate removal | F24, F31 |
| 11 | simultaneous removal | feat_removal_concurrency_test.sh (9/0), F22 (one audit) |
| 12 | consequence preview | P1, P2, P6 |
| 13 | ability feat | F14a, F14 |
| 14 | Tough maximum HP | F15a, F15, F16–F16c |
| 15 | Magic Initiate spell grants | F11a, F11 |
| 16 | same spell from another source | F12, F12b, FC20 |
| 17 | feat resource | F13a, F13 |
| 18 | proficiency from two sources | F17, F17c (class CON save stays) |
| 19 | action removed from Play | browser R2 (Interception card leaves Play) |
| 20 | resource removed from Play | F13 + glance re-render (Ready to use reads the same resources) |
| 21 | spell removed from Spells | F11; FC20 |
| 22 | background feat | F18; browser F18, F21b |
| 23 | lineage feat | F19; browser F19 |
| 24 | class (ASI) feat | F20, F20b, F21; browser F20, F21 |
| 25 | export / import | F28, F29, FC21 |
| 26 | Realtime | F26c; browser F25, F27a, R1, R2 |
| 27 | progressive path | F26; FC11 |
| 28 | legacy fallback | browser F27, F9 |
| 29 | Combat Builder detail refresh | browser C3–C5 (feat_removal_ui), active_features C1 |
| 30 | audit | F30, F22 |
| 31 | friendly errors | F24, F31 |
| 32 | no campaign-name leakage | F5b, F5c, F5d |

## Production reconciliation (read-only, counts only)

| Check | Count | Action |
|---|---|---|
| assigned spell-selecting feats | 2 grants (Magic Initiate 2024 via Background: Sage — complete, 4 spells; via Lineage: Variant Human — incomplete) | none |
| incomplete feat choices | 1 (the Variant Human grant: ability stored; list, cantrips, spell missing) | **not auto-filled**; Build now shows the Next step and the choice dialog works |
| stored choices without grants (complete, no source) | 0 | none |
| grants without stored choices | 0 | none |
| duplicate feat spell sources | 0 | none |
| invalid stored values | 0 | none |
| orphan choice rows / orphan active feat resources | 0 / 0 | none |
| directly assigned (removable) feats | 1 | none |
| Resilient holders / scores above 20 from ASI | 0 / 0 | none |

No reconciliation data patch is needed or applied: the only affected grant needs the player's own spell choices.

## Tests

`supabase/tests/feat_choice_state_tests.sql` (28 checks; against the pre-release definitions 11 of the first 23 fail, which
is the defect), `feat_removal_tests.sql` (60), `feat_removal_concurrency_test.sh`, `classes/feat_tests.sql`,
`gameplay_polish_tests.sql` (Magic Initiate via backgrounds), `browser/active_features_ui_test.py` (F1–F9, R1–R2),
`browser/feat_removal_ui_test.py`.
