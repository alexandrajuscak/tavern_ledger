# UX redesign task log (started 2026-10-22)

Local-only "complete player-first UX, IA and visual design review". No commit/push/deploy/remote.
Source of truth for progress after a context reset.

## Rules
- Do not change mechanics/RLS/governance. UI + docs only, unless a genuine bug (document + test + fix).
- Heavy suites sequentially. Test frontend on 5191; never touch the user's 5173 server.
- Restore task-start data at the end (method: memory tavern-ledger-slots-backgrounds / dm-governance).

## Steps
- [x] 1 start local env (Docker was stopped; supabase start; my server: python scripts/local/serve_frontend.py . 5191)
- [x] 2 backup %USERPROFILE%/tavern-ledger-local-backups/2026-10-22_before_ux_redesign.dump (sha256 0275AA32...),
      fingerprints ..._fingerprint.txt / _extra / _gov (new fingerprint_gov.sql). Start: 2 users, 34 chars, 5 campaigns, 40 migrations.
- [x] 3 audit (docs/UX_INFORMATION_ARCHITECTURE_AUDIT.md); probe script scratchpad ux/probe.py
- [ ] 4 journeys (docs/PLAYER_JOURNEY_REVIEW.md)
- [ ] 5 IA, typography, tokens, icons, components (docs)
- [ ] 6 implementation (navigation, home, header, overview, stats, combat, spells, inventory, build, feats, WS, approvals, DM, pickers, states)
- [ ] 7 responsive / keyboard / a11y review, usability doc
- [ ] 8 focused browser tests, full browser suite once
- [ ] 9 restore, persistence, stop, final report

## Implementation notes (2026-10-22)
- fonts self-hosted: fonts/*.woff2 + css/fonts.css (Inter UI, Alegreya display only: brand, .title, .char-name, .dm-title h1)
- icons: assets/icons (curated webp 96px, portraits 192px) + assets/icons/ui (29 extra, SOURCE_ICONS.md); js/icons.js
- sheet tabs: keys kept (combat/stats/spells/inventory/features/bio) labels Play/Abilities/Spells/Inventory/Build/Bio;
  resources->Play, notes->Bio, class/lineage/background/choices->Build. Bottom nav <=700px. Topbar mini vitals.
- Play: Ready to use (#combat-states = glanceHTML attackFacts:false), Wild Shape, Attacks, timing groups incl. catalog class features
- Build: Next steps (level-up gating via governance onState), classes, class features (+ #class-resources details), lineage,
  background, feats (grouped by source), reminders, own features
- CSS: v4 blocks appended at end of css/styles.css
- home: listCharacterBadges (store.js), derived max HP/AC per card (cached cardstats:<id>:<updated_at>)
- DM overview: Needs you list
- NEXT: update browser tests for moved sections, run focused suites, docs.
- 2026-10-22 later: all focused browser suites green after test updates (see UI_MIGRATION_NOTES "Tests updated").
  local_demo_smoke 19/23: 13/14/15a/15b fail on demo slot-state drift (task-start dump already differs from fixture
  expectations; the test's rests mutate demo data) -> restore fixes data, not a UI issue.
- docs written: UX audit, journeys, design system, typography, tokens, icons, components, usability, migration notes;
  appended: FRONTEND_UX_REVIEW, DM_SPACE_UX_REVIEW, SPELL_VISUAL_SYSTEM, WILD_SHAPE_UI, LOCAL_MANUAL_TESTING (sec 15), LOCAL_DEVELOPMENT.
- full browser suite started (PORT=5192), log scratchpad ux/full_browser.log
- REMAINING: full-suite result, keyboard check (skip link first), screenshots to tavern-ledger-local-backups/ui-review-2026-10-22,
  restore task-start data (+ seeder fixtures), persistence check, stop services + 5191 server, final report.
- DONE 2026-10-22: full browser suite 22/23 suites green in one run + spell_ui rerun 28/28 after selector fix (566 checks);
  local_dev_smoke 21/21; keyboard fixes (quiet tray focusable, AC focus ring); screenshots in
  tavern-ledger-local-backups/ui-review-2026-10-22; task-start data restored (42 fingerprint rows identical), logins OK,
  stop/start persistence OK; supabase stopped, 5191 server stopped. Nothing committed. Final report delivered.
