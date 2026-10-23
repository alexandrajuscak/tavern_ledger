# Feats

The versioned feat catalog and the feat engine. Data model: [FEAT_DATA_MODEL.md](FEAT_DATA_MODEL.md); what is covered and
automated: [FEAT_COVERAGE.md](FEAT_COVERAGE.md); campaign custom feats: [CUSTOM_FEATS.md](CUSTOM_FEATS.md).

## Rules the engine follows

* **Versions, not names.** "Alert" exists as `alert-2014` and `alert-2024` with different mechanics. A character holds an
  exact version; nothing ever converts one into the other (a DM can remove one and grant the other). The picker shows the
  ruleset, category, source and status badges.
* **Categories** (2024): Origin, General, Fighting Style, Epic Boon (+ "other" for setting / older feats). The catalog
  filters by category; a 2024 background grants an Origin feat. (Class Fighting Style features keep their own option list
  from the class feature engine; Fighting Style feats can be taken through the picker where a rule allows it.)
* **Sources** of a feat on a character: a direct grant (player pick where the campaign allows it, DM grant, campaign
  reward, approved request, import), the 2024 background's Origin feat, a lineage feat choice (Variant Human, Custom
  Lineage), or an Ability Score Improvement taken as a feat. Each is a grant; removing the source removes only what it gave
  (FT8, FT20, FT23).
* **ASI or feat.** At an Ability Score Improvement level the class feature choice offers either the ability increase or
  "Choose a feat…" (the picker in `pick` mode); the feat then resolves with the class feature as its source (FT10). Losing
  the level deactivates it (FT12).
* **Prerequisites** are evaluated for the character: level, abilities, proficiencies, spellcasting, other feats, lineage,
  size, features (FT9, FT32). Text prerequisites the engine cannot check are "unresolved": the DM confirms them. The
  campaign setting `unmet_prerequisites` decides whether an unmet prerequisite blocks, can be proposed to the DM, or only
  the DM may override it (`dm.prerequisite_override`, reason recorded and audited, FT29).
* **Repeatability**: once, repeatable, or repeatable with a different choice (Elemental Adept, Magic Initiate 2024,
  Skilled 2024) (FT7, FT24, FT25).
* **Choices** (ability, skill, tool, language, spell list, spells, damage type, weapon, option) are validated on the server;
  an incomplete choice keeps the dependent effects inactive and the feat shows "Choose…" (FT15–FT17).
* **Effects** are resolved on read and flow into the derived stats like class features, with "Feat: <name>" as the source:
  Alert adds the proficiency bonus to initiative (FT6), Tough raises the maximum HP by 2 per level without rewriting the
  stored base (FT11), Resilient adds the ability and the saving throw (FT14), Lucky gives a resource with its recharge (FT19),
  Magic Initiate adds its spells under a feat spellcasting source (FT21–FT23).
* **Governance**: in a campaign, taking, removing or changing a feat is `choice.feat` (Standard / Strict: approval, with a
  preview of the change, FT26–FT28); content policy filters playtest / ruleset / custom feats for players. Outside a campaign
  the player manages feats freely.

## UI

* **Feats card** (Features tab, `js/feat-ui.js`): every feat with its source, ruleset and category badges, automation level,
  choices ("Choose…" when incomplete), notes, details, remove (direct feats). "+ Add feat" opens the picker.
* **Feat picker**: search; filters for category, ruleset, status, repeatable, and what a feat grants (ability increase,
  spells, proficiency); tags; "Eligible only" (prerequisites evaluated for the character),
  badges (ruleset, category, status, campaign custom, automation), detail panel with prerequisites and choices; a feat the
  campaign does not allow shows the reason and cannot be taken; in an approval campaign "Take this feat" opens the "Ask your
  DM" dialog.
* ASI choices and lineage feat choices use the same picker in `pick` mode.
* The HP card shows the effective maximum: "Maximum 48: base 40 + 8 from Tough."
* JSON export / import carries feats (`feats` in `docs/character.schema.json`).

## Data pipeline

```
scripts/data-migration/feats_fetch.py      -> data/raw/feats_html/ (cached pages; re-runs use the cache)
scripts/data-migration/feats_extract.py    -> data/feats/feats_extracted.json
data/feats/feat_mechanics.json              (hand-authored mechanics: effects, choices, spells, resources)
scripts/data-migration/generate_feat_seed.py -> supabase/seed/feats.sql, data/reports/feat_coverage.json, docs/FEAT_COVERAGE.md
generate_feat_seed.py --check               (fails when the seed or the coverage doc is out of date; run by run_supabase_local.sh)
```

Only short summaries and structured mechanics are stored, with the source URL; full rules prose is not copied. Playtest
(Unearthed Arcana) pages are imported with status `playtest`, never as official content.

## Tests

`supabase/tests/classes/feat_tests.sql` (FT1–FT35), `supabase/tests/feat_catalog_checksum.sql` + the seed idempotency check
in `run_local.sh` (408 versions after a second seed run), `governance_tests.sql` G16b (content policy),
`dm_space_ui_test.py` DS17–DS28c (picker, eligibility, request, approval, Feats card, HP), `class_transfer_ui_test.py`
TR2b / TR6b (export / import).
