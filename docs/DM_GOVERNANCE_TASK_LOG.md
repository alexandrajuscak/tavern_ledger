# DM governance, DM Space and feat catalog: task log

Working log of the 2026-10-19 task (feat catalog + DM governance + approvals + central DM Space). LOCAL ONLY:
no hosted Supabase, no remote command, no deploy, no commit, no push. Read this file first after a context reset.

## Task-start state

- Backup: `%USERPROFILE%\tavern-ledger-local-backups\2026-10-19_before_dm_governance.dump`
  (sha256 `DC5B30D8783F629057AF2BF9AE4BC367C09CA26D282CFC06297C53E0B485B0C7`, 2,349 TOC entries, `pg_restore -l` OK).
- Fingerprints: `..._fingerprint.txt` (fingerprint.sql, 19 rows), `..._fingerprint_extra.txt` (fingerprint_extra.sql, 7 rows).
- Counts: 2 auth users, 30 characters, 1 campaign, 2 campaign members, 32 applied migrations, 2 homebrew items.
- Restore method: data-only `pg_restore` of public + auth users/identities onto the current schema after truncating, then
  re-run seeds (see memory notes of the earlier tasks).

## Architecture decisions (fixed)

1. **Governance is enforced in the database.** `public._gov_gate(character, action)` is called at the top of every
   governed SECURITY DEFINER RPC (injected by a builder from the live definitions) and by a `characters` BEFORE UPDATE
   trigger for direct column writes made by the `authenticated` role (writes made inside definer RPCs run as the owner
   and are gated by the RPC itself). Decisions: `player_managed`, `approval_required`, `dm_only`, `disabled`.
   Campaign DMs and admins always pass (except an archived character); characters without a campaign are ungoverned
   (no DM exists). `approval_required` raises SQLSTATE `TLAPR` so the UI can offer "Request approval".
2. **Presets** `relaxed`, `standard`, `strict`, `custom` + per-action overrides. Campaigns that existed before the
   migration get an explicit `relaxed` row (closest to the old behavior) and a migration report row. Campaigns created
   by a signed-in user get `standard` (insert trigger). A campaign without a row (created by SQL / seeds / tests)
   resolves to `relaxed` and is reported as "not configured".
3. **Approval requests** hold a whitelisted list of operations (`ops`: op key + typed args) that map 1:1 to existing
   domain RPCs. Preview = apply the ops inside a sub-transaction, capture a before/after review snapshot, roll back.
   Approve = lock request, verify revision + baseline (stale detection), apply the ops through the domain RPCs inside a
   sub-block; failure => `apply_failed` with the error, nothing partially applied.
4. **Custom content** = `dm_content` (identity, author, campaign or private library) + `dm_content_versions`
   (draft document validated per type) + publications. Publishing materializes the version into the existing typed
   catalog tables (spells, items, feats, creatures, backgrounds, lineages, companion templates, conditions) with the
   campaign as visibility scope, so every existing picker and engine uses it. Published versions are immutable; new
   mechanics = new version; archive keeps existing references.
5. **Feats**: old `public.feats` (11 version rows) is renamed `feat_versions`; a new canonical `feats` table is created.
   Effects use the class-feature effect vocabulary and enter the derived stats through `_character_feat_effects`
   (same row shape as `_character_class_effects`). Resources and spell grants are materialized into
   `character_resources` / `character_spellcasting_sources` by `_sync_character_feats`.
6. **Hidden data** lives in DM-only tables (RLS: campaign DM / admin) and never in player-readable rows.

## Progress

- [x] A1-10 audit: docs/DM_GOVERNANCE_AUDIT.md, docs/DM_SPACE_AUDIT.md
- [x] B1 migration 20261019000100_campaign_governance (builder: scratchpad/gov/build_gov.py = gov_static.sql + 75 live RPC
      definitions with one injected gate line each; rebuild ONLY from a database where it is not applied yet — the builder
      refuses already-gated functions) and 20261019000200_change_requests (hand-written).
- [x] B2 SQL suite supabase/tests/classes/governance_tests.sql 56/56 (scratchpad/gov/tx_test.sh runs a class-harness test
      with unapplied migrations inside one rolled-back transaction on the live local DB).
- [x] B3 applied to the live local DB (`migration up`, 34 migrations); rollbacks rollback_campaign_governance.sql (generated)
      and rollback_change_requests.sql. Regressions on the live DB: all 19 per-class suites green (wild_shape fixed: only
      loosening enforce->warn is gated), spell 45, lineage 84, class_slot 86, derived 56, class_feature 95.
      Intended behavior changes in tests: only DMs author homebrew (inventory_tests / derived_stats_tests fixtures give
      alice a one-person campaign she DMs; the campaign axe is authored by the DM; message expectations widened);
      prerequisite confirmation is DM-only (class_feature_tests F9b2). inventory_tests needs the plain runner (legacy
      fixture) -> validate in Phase G.
- [x] B4 suites/rollbacks registered in run_local.sh + run_supabase_local.sh (+ feat seed idempotency, generator --check)
- [x] B5 supabase/tests/governance_concurrency_test.sh 6/6 (found + fixed a real race: review now locks the character row
      before the stale check; retry also re-checks staleness). set_character_lock locks the character row too.
- [x] C/E backend: 20261019000400_dm_content (builder scratchpad/gov/build_content.py = content_static.sql + live edits of
      _form_options / set_seen_forms / add_character_companion; rollback generated, tail by mk_content_tail.py),
      20261019000500_hidden_dm_data, 20261019000600_dm_read_models (hand-written + rollbacks). Applied live (38 migrations).
      SQL suite classes/dm_content_tests.sql 37/37 (publish found 6 real materializer bugs, all fixed).
- [x] C/E/F frontend: js/governance-api.js, request-ui.js (lock/setup banner, pending tray, approval dialog fed by the
      'tavern:governance' event that supabase.js emits for TLAPR/TLDMO/TLDIS/TLLCK; store.js never retries refused writes),
      feat-api.js, feat-ui.js (Feats card, picker, choices; ASI + lineage "Choose a feat…"), dm-api.js, dm-space.js
      (#/dm/<section>), content-editors.js; inventory homebrew creation hidden for non-DMs; CSS appended. Probe:
      no console errors, no overflow at 390 px. get_dm_party is batched (5 per call) because of the 8 s PostgREST timeout.
- [x] browser test supabase/tests/browser/dm_space_ui_test.py 48/48; local_dev_smoke 21/21 (the signed-up user now DMs a
      campaign before the homebrew steps); class_transfer 9/9 incl. feat export/import (TR2b/TR6b)
- [x] D feat catalog (schema, data pipeline, effects, integrations, picker)
      D1 DONE feats_fetch.py (407 pages cached, 0 failures; the task's 2014 URL /feats is 404 -> home page nav used),
         feats_extract.py -> data/feats/feats_extracted.json, hand mechanics data/feats/feat_mechanics.json (89 versions),
         generate_feat_seed.py -> supabase/seed/feats.sql (408 versions / 334 canonical; 22 automated, 218 partial,
         168 informational) + data/reports/feat_coverage.json. Seed order: ... lineages, feats, backgrounds (config.toml);
         backgrounds.sql generator now schema-aware (old feats table vs feat_versions).
      D2 DONE migration 20261019000300_feat_catalog (builder scratchpad/gov/build_feats.py = feat_static.sql + live-def
         rewrites cached in feat_orig_defs.json; rollback generated). Applied live + seed loaded (35 migrations).
      D3 DONE SQL suite classes/feat_tests.sql 35/35; background_tests BG1 now joins feat_versions; governance 56/56.
      Builders + caches are copied to %USERPROFILE%\tavern-ledger-local-backups\builders_2026-10-19\gov.
- [x] E custom content editors (js/content-editors.js; DM Space Content Library)
- [x] F player/DM UX
- [x] feats in character JSON (js/transfer.js + docs/character.schema.json "feats"); export waits for class data
- [x] 20261019000700_derived_stats_performance: _character_mods evaluated derived stats 7x (inlined SQL); now once.
      get_character_resources / spell_slots 1.3 s -> 0.15 s on a multiclass character; identical output (md5).
      Rollback rollback_derived_stats_performance.sql, registered in both runners. 39 migrations.
- [x] fix: change_requests_one_draft is now a deferred exclusion constraint ("Ask your DM" failed with a raw 23505 while a
      tray draft existed; found by the fixture seeder). governance_tests A31/A32 + G16b (content policy) -> 60/60.
- [x] sheet: effective max HP = base + feat bonus (HP card note, heal cap, long rest); dm_space_ui_test DS28b/DS28c (50/50)
- [x] fixtures: scripts/local/seed_local_demo.py governance_fixtures() (4 campaigns, add-only; verified after restore)
- [x] docs: DM_GOVERNANCE, APPROVAL_WORKFLOWS, CHARACTER_LOCKS, CAMPAIGN_CONTENT_POLICY, HIDDEN_DM_DATA, DM_SPACE,
      CUSTOM_CONTENT_LIFECYCLE, CUSTOM_SPELLS/ITEMS/FEATS/CREATURES/COMPANIONS, FEATS, FEAT_DATA_MODEL, FEAT_COVERAGE
      (generated by generate_feat_seed.py, --check covers it) + appended sections in 15 existing docs
- [x] G found + fixed: feats.sql needed source books only backgrounds.sql creates (fresh reset failed); migration
      20261019000800_feat_backfill (existing characters' feat resources, e.g. Showcase Monk Luck Points); rollbacks of
      dm_content / change_requests / feat_catalog dropped functions before the tables whose policies use them (+ feat
      rollback: check_function_bodies off, cascade on row-type deps, policy before column drops). Fresh-container
      rollback chain (scratchpad gov/rb_chain.sh) all ok. inventory_tests N3 retargeted (DM is author now) 200/200.
      Safety dump before validation: tavern-ledger-local-backups/2026-10-19_pre_validation_state.dump (B5D4C905…).
      Restore script: scratchpad gov/restore_start.sh (truncate dump tables cascade + auth.users, data-only restore,
      seeds, replay 0100 backfill; then 0800 sync).
- [x] run_local.sh PASSED (5th run, exit 0, 3429 suite checks; fixes: rollback_inventory drops all 135 new
      20261019 functions by name; F9b2 conditional on governance for the post-rollback rerun)
- [x] run_supabase_local.sh --keep PASSED (373 / 0)
- [x] browser suite (2nd full run): 523 PASSED / 0 FAILED; class_spell and spell_visual crashed on the sign-in page load
      in that run (runner's http.server) and PASSED alone (21/21, 13/13). Fixes listed in DM_SPACE_UX_REVIEW.md.
- [x] restore: task-start dump (sha256 verified) restored data-only as supabase_admin; fingerprints IDENTICAL (19 + 7
      rows, new columns feat_grant_key / template_version_id stripped); 0800 backfill -> Showcase Monk Luck Points.
- [x] fixtures: seeder added the 4 governance campaigns; second run left everything unchanged.
- [x] UX walkthrough (read-only) -> docs/DM_SPACE_UX_REVIEW.md; fixed footer wrap at 390 px, speed attribution to feats,
      readable labels, plural; dm_space 50/50, derived 35/35, martial 23/23 after the fixes; synthetic ui- users removed.
- [x] persistence: stop/start, identical counts. Services stopped; 5191 server stopped. Final report delivered.
