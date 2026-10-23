# Wild Shape audit (2026-10-17, before the Wild Shape gameplay engine)

State of the repository before `20261017001300_wild_shape_engine.sql`. Rules version: the 2014 Druid (`druid-phb`) and
Circle of the Moon (`druid-moon-phb`) already used by the catalog. No 2024 Wild Shape rule is mixed in.

## Current functionality

| Area | Where | What it did |
|---|---|---|
| Creature catalog | `creatures` (`20261017000800`), seed `creatures.sql` from `creatures_fetch.py` / `generate_creature_seed.py` (dnd5eapi.co, SRD 5.1, CC-BY-4.0) | 334 creatures (87 beasts, 4 elementals). Size, type, AC, HP, hit dice, speed, abilities, saves, skills, senses (raw), resistances / immunities, CR, PB. Traits are **name only**; actions are name, kind, attack bonus, reach and damage, with multiattack as an action list. |
| Eligibility | effect `transform_form` in `druid.json` (Wild Shape: CR 1/4, 1/2, 1 by level; no swim below 4, no fly below 8) and `druid-moon-phb` (Circle Forms CR table 1, 2, 3, 4, 5, 6 at 2, 6, 9, 12, 15, 18; Elemental Wild Shape at 10 for 2 uses), `_transform_refusal`, `get_character_transformation.options` | Correct CR, swim and fly limits by **class level** (the class row's level, so multiclass-safe). The lowest-cost allowed rule wins. |
| Transformation | `character_transformations` (one row per character), `start_transformation`, `change_transformation_hp`, `end_transformation` | Spends the resource, stores form HP (max = catalog HP), damage at 0 ends the form and carries the excess to `characters.hp_current`, healing is capped at the maximum. |
| Resource | `druid-wild-shape-phb-uses`: 2 uses, short or long rest, unlimited from level 20 (`[20, null]`) | Rests restore it. |
| UI | `js/creature-ui.js` (`transformHTML`, `openFormPicker`), class page and Combat tab containers | Picker with search and "only forms I can take" (reason text for the others), stat block, form HP with Damage / Heal / Return. |
| Export | `transfer.js` exports companions; the active transformation is not exported | |

## Confirmed bugs and gaps

1. **Physical abilities are not replaced.** The derived stats keep the character's STR, DEX and CON while transformed. For
   example, Showcase Druid as a Brown Bear shows STR 10 instead of 19. Saves, skills, attacks and AC based on those
   abilities are therefore wrong.
2. **AC, speed and senses stay the character's** (worn armor, Unarmored Defense, darkvision) instead of the form's.
3. **Saves and skills** neither gain the creature's proficiencies nor apply the "higher printed bonus" comparison.
4. **Equipment** behavior is not modelled: worn armor and item effects keep applying while transformed.
5. **Normal HP is not protected in the UI.** The main HP card still edits `characters.hp_current` directly while
   transformed. Carry-over damage ignores the normal form's temporary HP. The form has no temporary HP.
6. **No events or history**, no duration (`started_at` only), no expiry, and no end reason.
7. **Concurrency:** `end_transformation` does not lock the character row. `change_transformation_hp` locks only the
   transformation row, and the character row is updated without the character lock.
8. **No seen-form model, favorites or recent forms.** Every eligible form can be taken.
9. **Actions** have no save DCs, secondary effects, targets, ranges, escape DCs, recharge or per-rest usage. Traits have no
   text or grouping. 35 distinct traits and 34 actions with secondary effects exist in the eligible pool.
10. **Combat Wild Shape healing** (spend a slot for 1d8 per slot level) is only a reminder.
11. **Spellcasting restriction, Beast Spells and Archdruid** are informational effects only, with no "can cast now" state.
12. **The form picker** only has search and an eligibility filter: no CR, size or movement filters, no compare, no
    favorites, and no grouping of elemental forms.

## Discovery sources

- **Druid and Circle of the Moon** (rules source): `data/raw/classes_html/druid.html` and `druid_moon.html` (wikidot, cached).
- **Fandom "Beast Shapes"** (requested discovery source): refused automated access (HTTP 403 to the fetcher, 402 to the
  web reader) on 2026-10-17. This is recorded in the coverage report; nothing was copied from it.
- **RPGBOT Wild Shape** (`data/raw/classes_html/ref_rpgbot-wild-shape.html`, cached): used **only** as the discovery list of
  beast names, CR and source book codes. Its ratings and commentary are never used as rules or shown.

## Licensing

Mechanics come from the SRD 5.1 (CC-BY-4.0) through dnd5eapi.co, with attribution on every creature row. Non-SRD beasts
(Volo's, Tomb of Annihilation and others) have no licensed structured source here. They are listed in the coverage report
as unavailable and are never fabricated. Trait and action summaries are written for this project. The SRD prose is not
stored.

## Required changes

- **Schema:**
  - `creatures`: add `traits` with groups and summaries, structured `actions` (DC, save, effect summary, range, targets,
    escape DC, usage), structured `senses`, `mechanics_status`.
  - `character_transformations`: add form temp HP, the normal-HP snapshot, duration and expiry, elemental flag, equipment
    modes and per-form action state.
  - New tables: `character_wild_shape_settings`, `character_seen_forms`, `character_form_favorites`,
    `character_transformation_events`.
- **Engine:**
  - Physical ability substitution in `_derived_stats_core`.
  - A Wild Shape layer on the derived stats (AC choice, movement, senses, saves and skills with creature proficiencies, the
    form's resistances).
  - Equipment suppression in `_character_effects`.
  - Locked damage, heal and adjust RPCs with temp HP and events.
  - Seen-form and DM-grant eligibility.
  - Combat Wild Shape healing.
  - Spellcasting state.
  - Expiry checked on read and on every mutation.
- **UI:** a new picker (filters, compare, favorites), an active Wild Shape mode, and HP routing while transformed.

## Scope exclusions

- No 2024 Wild Shape rules.
- No combat target engine: attacks and save effects are shown with dice and DCs, never applied to other creatures.
- No map, space or mount placement. Size information only.
- No automatic unconscious handling (a reminder plus forced revert).
- No non-SRD beast mechanics.
- No full concentration engine: the existing "Concentrating" condition is shown and kept.
