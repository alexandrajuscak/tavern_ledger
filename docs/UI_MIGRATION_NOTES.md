# UI migration notes (redesign of 2026-10-22)

The redesign is frontend-only. **No SQL, RPC, RLS, governance policy or rules-engine behaviour changed.** All data is
read and written through the same RPCs as before.

## Where things moved

| Before | After |
|---|---|
| Combat tab | **Play** (key `combat`) |
| Stats tab | **Abilities** (key `stats`) |
| Features tab | **Build** (key `features`) |
| Resources tab | Play → Ready to use (quick Use) and the hand-tracked resources; resource limits, dice and recovery: Build → Class features → "Resources: limits, dice and recovery" |
| Notes tab | Bio → notes (`#notes-section`) |
| Bio → Classes, Lineage, Background, Pending choices | Build (the pending choices are now "Reminders") |
| Bio → Portrait | Bio → Identity (with the name) |
| Header Level Up | Build → Next steps (`#level-up-slot`), labelled by campaign rules |
| Features → At a glance | Play → Ready to use (`#combat-states [data-cf-glance]`); attack facts and riders: Play → Attacks (`#feature-attacks`) |
| Features → Companions | Play → Companions |
| Speed tile input (base speed) | the tile shows the effective speed; the base input is under Abilities → Other |
| "Requests" link | header chip (`data-action=open-requests`); the tray shows only when something is pending |

Old stored tab preferences (`resources`, `notes`, `attacks`) open the section that now holds them.

## Files

- New: `css/fonts.css`, `fonts/` (Inter, Alegreya, OFL texts), `assets/icons/` (WebP icon family + `SOURCE_ICONS.md`),
  `js/icons.js`, `supabase/tests/browser/ux_redesign_ui_test.py`, and the `docs/UI_*.md`, `UX_*.md` and
  `PLAYER_JOURNEY_REVIEW.md` documents.
- Changed: `index.html` (no Google Fonts, skip link, top bar readout slot), `css/styles.css` (tokens, typography,
  v4 blocks at the end), `js/sheet.js` (sections, header, vitals, Play, Build, Bio), `js/app.js` (home, sign-in),
  `js/store.js` (`listCharacterBadges`), `js/feature-ui.js` (glance export, no glance in Build), `js/spell-ui.js`
  (spell card), `js/inventory-ui.js` (equipment, icons), `js/feat-ui.js` (groups, icons), `js/request-ui.js` (onState,
  icons), `js/dm-space.js` (Overview), `js/content-editors.js` (type icons), `js/governance-api.js` (preset text),
  `js/class-ui.js`, `js/derived-ui.js`, `js/utils.js` (toast roles) and wording in several modules ("Bio tab" →
  "Build tab" where the target moved).

## Tests updated to the new structure

| Test | Change |
|---|---|
| `background_ui_test.py`, `class_setup_ui_test.py`, `class_slot_ui_test.py`, `lineage_ui_test.py`, `class_ui_common.py` | class, lineage and background steps use the Build tab (`features`); exports switch to Bio first |
| `class_feature_ui_test.py` | Build for the class card; resource cards opened under Build; mobile check on Play |
| `class_martial_ui_test.py`, `class_hybrid_ui_test.py`, `class_barbarian_ui_test.py` | Ready to use on Play; Sneak Attack, Divine Smite, Favored Foe and the critical range are read from Play → Attacks |
| `dm_space_ui_test.py` | personal notes on Bio |
| `derived_stats_ui_test.py`, `lineage_ui_test.py` | the speed note now reads "Base 30 ft, now 20 ft (…)" |

## Deliberately deferred

- **Icon licence.** Verify the licence of the curated icon set and add attribution if required (`docs/UI_ICON_SYSTEM.md`).
- **Portrait picker.** Let players choose one of the curated portraits (`assets/icons/portraits/`) without uploading.
- **Picker redesign.** Lineage, background, feat, spell, item and Wild Shape pickers have the new type and colours, but
  keep their own layouts. One shared picker component (search, collapsible filters, compact cards, review step) is the
  next UX task.
- **Companion gameplay.** Companions are shown on Play. A full companion sheet (actions, HP controls, initiative) is
  future work.
- **Conditions and health.** Conditions are labelled chips with no mechanical effect yet. A health and conditions engine
  is future work.
- **Combat dashboard.** Not built. With Play gathering attacks, timing groups and Ready to use, the audit did not show a
  need for a separate dashboard. Revisit after table use.
- **Demo / test grouping on Home.** Fixture characters are grouped by campaign. A separate "Demo" group would need a
  fixture flag in the data.
- **DM Content editor steps.** The editor keeps its grouped form. A stepped editor is future work.
- **Spell list virtualisation.** Not needed at current sizes.

## Refinement of 2026-10-22 (second pass)

- **Selectors and markup:** sheet sections are `section.tl-section` with `h2.tl-section-title` (was `.card` + `h3`). Abilities
  has `#abilities-scores`, `#abilities-saves`, `#abilities-skills`, `#abilities-senses`, `#abilities-hitdice`,
  `#abilities-profs`; ability cards are `.ab-card` (`.ab-block` is the restored Skills block, see Correction); `#senses-list` is new; `#lineage-stats` is in Senses and movement
  under "Size, languages, resistances and other traits"; the base speed and initiative bonus inputs moved to "Adjust by hand". Next steps
  re-renders as `#build-next-wrap`. Inventory: `.inv-side` holds `.inv-equipment`, `.inv-attunement`, `.inv-quick-use`,
  `.inv-containers`, `.inv-legacy`; the Items heading is `h2#inv-items-title`; the summary is no longer a card.
- **Heading levels:** spell source titles, class rows and slot panels are h3; spell level groups h4; spell card titles h5; Class
  features "Next actions" h3; Wild Shape panel h3 / h4 (were h4 / h5); Play timing groups h2.
- **Icons:** `js/icon-registry.js` (generated) + `js/icons.js` resolver with fallbacks; spell icons from `js/spell-icons.js`.
  `schoolIcon()` was removed in the correction (unused; the school mapping lives in `js/spell-icons.js` only).
- **New character:** `newCharacterDialog()` is a five-step dialog; `local_dev_smoke_test` skips the lineage and class steps.
- **Export:** `race` only for legacy text; `lineage` gains `lineageId`, `name`, `versionLabel` (`docs/character.schema.json`).
- **Tests:** new `supabase/tests/browser/ui_refinement_ui_test.py` (68 checks, in `run_browser_local.sh`); updated
  `lineage_ui_test.py` (18b) and `local_dev_smoke_test.py` (5).
- **Local server:** `scripts/local/serve_frontend.py` listens with a backlog of 128 (the default 5 refused connections under
  the parallel module and icon loads on Windows).
- **Files:** `js/section.js`, `js/spell-icons.js`, `js/icon-registry.js` (new); `js/icons.js`, `js/sheet.js`, `js/app.js`,
  `js/store.js`, `js/lineage-ui.js`, `js/class-setup.js`, `js/class-ui.js`, `js/spell-ui.js`, `js/spell-api.js`,
  `js/inventory-ui.js`, `js/feat-ui.js`, `js/feature-ui.js`, `js/wild-shape-ui.js`, `js/dm-space.js`, `js/homebrew-form.js`,
  `js/content-editors.js`, `js/transfer.js`, `css/styles.css`; assets `damage-types/multiple.webp`, `damage-types/choose.webp`,
  `creatures/bear.webp` (replaced); scripts `scripts/local/build_icon_registry.py`, `icon_audit.py`, `spell_icon_coverage.py`;
  reports `data/reports/icon_audit.json`, `data/reports/spell_icon_coverage.json`.
- **Deferred:** shared picker component; full creation wizard (ability score generation, background, equipment, spells);
  portrait picker; review of the 8 ambiguous spell-damage versions and the Fire Shield / Destructive Wave data; licence of the
  icon set; sub-lineage content policy (the server checks the base version only).

## Correction of 2026-10-22 (third pass)

- **Skills:** `#abilities-skills` now holds `.ab-grid.skill-groups` with one `.ab-block[data-skill-group=<ability>]` per ability
  that has skills: `.ab-left` (`.ability-name`, `.ability-mod[data-derive="mod:<ability>"]`) and `ul.prof-list.ab-list`
  (`aria-label="<Ability> skills"`) with the same rows as before the refinement (`.prof-dot[data-action=cycle-skill]`, `.bonus`,
  `.li-name`, `.dis-badge`). Removed: `ul.skill-list` and `.li-ability` (markup and CSS). Selectors `[data-derive="skill:…"]`,
  `[data-dis="skill:…"]` and `[data-action=cycle-skill][data-k=…]` are unchanged.
- **Spell icons:** `resolveSpellIcon(s)` returns `{ key, requested, school, label, coverage }` (no `relation`,
  `damageTypes`, `kind`, `review`); `data-spell-icon` on the img is the school id or `generic`. Damage for texts and chips:
  `spellDamage(s)` (`damageText()` uses it). The badge fallback text is "School not resolved" (was "Unknown school").
- **Scripts:** `spell_icon_coverage.py` reports counts by school, unresolved, fallback, missing / broken / blank assets;
  `icon_audit.py` no longer treats `spell.damage.*` as a run-time family.
- **Tests:** new `supabase/tests/browser/skills_spell_icon_ui_test.py` (in `run_browser_local.sh`); `ui_refinement_ui_test.py`
  SI13–SI31 now expect school icons.
- **Files:** `js/sheet.js` (statsHTML Skills only), `css/styles.css` (Abilities block only), `js/spell-icons.js`,
  `js/spell-ui.js` (damageText, badge fallback), `js/icons.js` (`schoolIcon` removed).

## v5 of 2026-10-22 (fourth pass): vitals, six abilities, Skills, medieval typography

| Area | Change | Files |
|---|---|---|
| Vitals | Collapsed summary line, labelled collapse control, mobile default collapsed, authoritative maximum shown as a value, shield AC, restrained quick resources, Damage/Heal result message | `js/sheet.js`, `css/styles.css` |
| Base maximum HP | Moved from the vitals to Build → Classes (`.build-hp`, same governed `hp_max` field) | `js/sheet.js` |
| Abilities | Six-ability strip (abbreviation, full name, modifier, score; Wild Shape form score and source chip); true minus sign | `js/sheet.js`, `css/styles.css` |
| Skills | All six blocks (Constitution included), score pill | `js/sheet.js`, `css/styles.css` |
| Typography | Cinzel self-hosted; `--font-display-medieval`, `--font-ui`, `--type-*`; `sectionHead({ variant })` | `fonts/cinzel-*.woff2`, `fonts/OFL-Cinzel.txt`, `css/fonts.css`, `index.html`, `js/section.js`, `css/styles.css` |
| Spell icons | Unused `damageIcon()` removed; the resolver stays school-only | `js/icons.js` |

Not restored on purpose:
- the old frontend Cinzel-everywhere rules (labels, buttons, modal titles, counters);
- the save row inside the Skills blocks (saving throws keep their own section);
- the editable base maximum next to Damage and Heal;
- per-level legacy slot pips in the vitals when a class slot table exists.

Tests changed:
- new: `vitals_abilities_ui_test.py`;
- `skills_spell_icon_ui_test.py`: six blocks, score pills;
- `ux_redesign_ui_test.py`: UX2/UX6 now expect Cinzel for title, name and AC; UX18 expands the phone vitals first;
- `derived_stats_ui_test.py`: the 390 px check expands the vitals first.

## v6 of 2026-10-22 (fifth pass): the original visual language

| Area | Change | Files |
|---|---|---|
| Headings | One system: gold Cinzel major titles, white Cinzel component titles, Inter functional headings, tracked-capital labels | `css/styles.css` (v6 block) |
| Vitals | Original label style and gold AC shield; collapsed = original compact components (+ temp and state badges); the v5 one-line summary removed | `js/sheet.js`, `css/styles.css` |
| Abilities | One "Ability scores and skills" section: summary tiles, legend, six cards with save + skills. The strip and the separate Saving throws / Skills sections removed. Hit Dice with Death Saves, Senses, Proficiencies below | `js/sheet.js`, `css/styles.css` |
| Proficiencies | Gold-tinted active tiles (granted solid, manual dashed) | `css/styles.css` |
| Inventory | Metric cards (Items, Weight, Attuned, Coins with Edit), summary-only refresh on coin edits | `js/inventory-ui.js`, `js/sheet.js`, `css/styles.css` |

Tests changed:
- new: `original_ui_test.py`;
- removed: `vitals_abilities_ui_test.py`, which tested the v5 strip and summary line;
- `skills_spell_icon_ui_test.py`: K-series for the cards;
- `ui_refinement_ui_test.py`: section names and section selectors;
- `inventory_ui_test.py`: 2c and 13a read the metric values.

Ids kept: `#abilities-scores`, `#abilities-hitdice`, `#abilities-senses`, `#abilities-profs`. Ids removed:
`#abilities-saves`, `#abilities-skills`.

## V6.1 hardening (2026-10-22)

| Area | Change | Files |
|---|---|---|
| Network | supabase-js 2.117.2 self-hosted (`vendor/supabase-js/`, deferred classic script); no runtime CDN | `index.html`, `js/supabase.js`, `vendor/supabase-js/*` |
| Errors | `friendlyError()`; autosave stops on permanent refusals; longer, deduplicated error toasts | `js/utils.js`, `js/store.js`, `js/feat-api.js`, `js/dm-api.js`, `js/governance-api.js`, `js/class-api.js` |
| Home | Loading marks instead of legacy AC / base max; 6 parallel derived reads | `js/app.js` |
| Sheet | One derived / proficiency / spellbook read per open; HP ≤ authoritative maximum; hit dice ≤ level; lock reason per lock mode | `js/sheet.js` |
| Headings | h4 → h3 card titles, h5 → h4 background parts, h6 → h5 Wild Shape parts, DM section h2 | `js/sheet.js`, `js/derived-ui.js`, `js/background-ui.js`, `js/lineage-ui.js`, `js/wild-shape-ui.js`, `js/dm-space.js` |
| Dialogs | Focus moves into dialogs without a field | `js/utils.js` |
| CSS | v6.1 block: card-title display, touch targets, button wrapping | `css/styles.css` |
| Tests | New `v6_product_hardening_ui_test.py`; CDN allowlists removed (9 files); `local_demo_smoke_test.py` deterministic and self-restoring | `supabase/tests/browser/*`, `supabase/tests/run_browser_local.sh` |
