# Ability scores: source model

Audit of 2026-11-07 ([COMBAT_BUILDER_FOLLOWUP.md](COMBAT_BUILDER_FOLLOWUP.md)). The stored data and the server calculation
were correct for the reported case; the defect was the sheet's presentation. **No stored score was migrated.**

## Source of truth

```
 STORED (editable)                       STORED (choices)                                DERIVED on every read (never stored)
 ───────────────────                     ──────────────────                              ─────────────────────────────────────
 characters.strength … charisma  ──────► base_score
   (the sheet's input: BASE)                │
                                            ▼
 character_lineages (+ included flag) ──► lineage bonus  ── capped at 20 ──► lin_after
   lineage_trait_effects ability_bonus      │
                                            ▼
 character_backgrounds.ability_allocation ► background bonus ── capped at 20 ─► after_lineage
   (2024; {} when bonuses_included)         │
                                            ▼
 items / class features / feats ────────► _character_effects(): ability_override (highest; never lowers)
   class ASI choice "str:1"                 ability_bonus (summed) ── capped at 30 ──► score   (= effective)
   feat ability choice / fixed +N           │
                                            ▼
 character_transformations (Wild Shape) ─► STR/DEX/CON replaced by the form's scores (form_score)
                                            │
                                            ▼
                         get_character_derived_stats → abilities[k] = { base, score, modifier, bonus, override,
                           lineage_bonus, lineage_applied, lineage_included, lineage_sources[], background_bonus,
                           background_applied, sources[] (effect rows with source_name and value), form_score, form_name }
```

Calculated in `public._derived_stats_core` (definition of `20261017001300_wild_shape_engine.sql`, the latest), wrapped by
`_derived_stats_full`, `_feat_layer` and `_wild_shape_layer`; served by `get_character_derived_stats` (also inside
`get_character_reads`, the progressive path, cached per character revision).

| Question | Answer (audited) |
|---|---|
| Where is the editable base stored? | `characters.strength … charisma`. The sheet's number input edits exactly that column |
| Where are class bonuses stored? | As the **choice** (`character_feature_choice_values`, e.g. `str:1`, or `feat:<id>`); the +N is an effect row produced on read (`_character_feature_effects`) |
| Feat / item bonuses? | Feat rows + their choices (`character_feats`, `character_feat_choices`), items (`inventory_items` modifiers): effect rows on read |
| Lineage / background? | `character_lineages` (+ `ability_bonuses_included`), `character_backgrounds.ability_allocation` (+ `bonuses_included`) |
| How is the effective score calculated? | Only on the server, as drawn above |
| Is a calculated total persisted? | **No.** No column holds an effective score; nothing writes one back |
| Does the manual editor change base or effective? | **Base** (the input's accessible name is now "Strength base score"; a "Base" caption appears when bonuses apply) |
| Can a source bonus be counted twice? | No: each source is one effect row / one allocation; "already included" flags suppress lineage / background bonuses for characters whose stored scores contain them; the class ASI's "Already included in my ability scores" option sets the choice to `applied_manually` (no effect row) |
| Wild Shape | `form_score` replaces STR/DEX/CON; INT/WIS/CHA are the character's ("Retained from character"); `base` stays the character's base |
| Export / import | Exports carry the base columns and the source choices (class choices, feats, lineage, background), never an effective score; import re-creates the choices, and the score is derived again: no double application |
| Class changes | Removing / changing the ASI choice or the class removes its effect rows on the next read; nothing to reconcile in stored data |
| Read cache | Base edits bump the character revision (`tl_cache_rev` on `characters`); choice / feat / lineage / background rows bump it too |

## Root cause of the stale "+1 = 16"

`js/sheet.js` (`renderDerived`) printed one note per ability:

```
parts = lineage_applied, background_applied, (score − base − lineage − background) labelled "items"
note  = parts.join(', ') + ' = ' + derived.score
```

1. **Stale total.** The input shows the base as the user types; `derived.score` is the server value from the last read. The
   note kept the old total until the save finished and the derived read came back (about one second locally; indefinitely
   when the save was queued offline, refused by governance or failed). Example: base 15 + ASI +1 → "+1 items = 16"; type 13 →
   still "= 16" until the re-read ("= 14").
2. **Wrong label.** Everything that was not lineage or background (a class ASI, a feat, an item) was called "items": the
   Fighter's ASI read "+1 items".

It was presentation only: the server never double-counted, nothing stale was stored, and the modifier already used the server's
adjustment.

## Presentation now

Ability card (`statsHTML` / `renderAbilitySources` in `js/sheet.js`):

| Element | Content | Source |
|---|---|---|
| Modifier | +3 | as before |
| "Base" caption + input | 15 | `characters.strength` (editable) |
| **Score 17** | the authoritative effective score, only when it differs from the base | `derived.abilities.str.score`, shown **only while `derived.base` equals the base on screen**; otherwise "Score updating…" (never client arithmetic) |
| Source rows | `+1 Lineage: Ability Score Increase` · `+1 Fighter: ASI` | one row per source: lineage (`lineage_bonus`, names from `lineage_sources`), background (`background_bonus`), every effect in `sources` (`+N` or "Sets to N" for an override). A capped source says so: "+2 Lineage (+1 applied: max 20)" |
| Total | `Bonuses from sources: +2` | only with two or more additive sources |
| Wild Shape | "From form" pill with the form's score; note "Wolf form · character base score 10"; no source rows | `form_score`, `form_name`, `base` |

No row shows "= value". Screen readers hear "+1 Strength from Fighter: Ability Score Improvement" (the visible text abbreviates
"Ability Score Improvement" to "ASI"), "Strength score 17 (base 15 plus the sources below)", and "Bonuses to Strength from
sources: +2 in total". The rows come from the same server response as the score.

## A separate calculation defect (documented, not changed)

Effect bonuses (`ability_bonus`: items, class ASIs, feats) are added **after** the 20-cap and capped only at 30, so a class ASI
on a base of 19 gives 21 (SRD: an Ability Score Improvement cannot raise a score above 20; some items legitimately can).
A correct fix needs per-source caps inside `_derived_stats_core` and changes effective scores of affected characters, so it is
out of scope here. Local data: **0** characters are affected today (no score above 20 from an ASI or feat). Listed in
[V6_KNOWN_LIMITATIONS.md](V6_KNOWN_LIMITATIONS.md).

## Semantic equality

Derived stats (`_derived_stats_full`, all fields) of all 35 local characters were compared with the follow-up migration applied
and with its rollback applied (inside a rolled-back transaction): **identical**. The ability-display change is frontend-only.

## Tests

`supabase/tests/browser/feat_removal_ui_test.py` A1–A34 (rows, total, authoritative score, "updating", base increase /
decrease, saving throw / skills, legacy `?fluent=0`, Wild Shape physical and retained, screen-reader text, 820 / 390 / 360).

## Re-validation in the combined release (2026-11-07 evening)

No change to the calculation or the presentation. The rows keep: Base input, server-confirmed "Score N" (shown only when the
server's base equals the input, otherwise "updating…"), one row per source ("+1 Fighter: ASI"), "Bonuses from sources: +2"
when there are several, and no "= value" anywhere. Covered again by `feat_removal_ui_test.py` in the full browser runner and by
`fluent_read_tests.sql` / `progressive_read_tests.sql` (derived stats unchanged).
