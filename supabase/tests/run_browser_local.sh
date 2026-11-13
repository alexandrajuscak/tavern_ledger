#!/usr/bin/env bash
# Browser tests of the inventory UI, homebrew editor, derived character stats, lineages, spells, class levels and the class
# feature engine against the LOCAL Supabase stack (must already be running: run_supabase_local.sh --keep,
# or `supabase start`). Serves the app on http://localhost:5173 with python's http.server.
# Needs a Python with `playwright` installed (throwaway venv) and Microsoft Edge:  PYTHON=/path/to/venv/python bash ...
set -uo pipefail
cd "$(dirname "$0")/../.."
SB="${SUPABASE_CLI:-../.tools/supabase-2.118.0/supabase.exe}"
PY="${PYTHON:-python}"
PORT="${PORT:-5173}"   # pass PORT=5191 (or any free port) when your own dev server already uses 5173
if [ -s supabase/.temp/project-ref ]; then echo "ABORT: linked to a remote project"; exit 2; fi
ENV=$("$SB" status -o env 2>/dev/null)
export API_URL=$(echo "$ENV" | sed -n 's/^API_URL="\(.*\)"$/\1/p')
export ANON_KEY=$(echo "$ENV" | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p')
export SERVICE_ROLE_KEY=$(echo "$ENV" | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p')
[ -n "$API_URL" ] || { echo "local Supabase is not running"; exit 2; }
# synthetic users of a previous run (local database only)
# (characters first: a campaign whose custom items are still in an inventory cannot be deleted)
docker exec supabase_db_tavern_ledger psql -U postgres -qAt -c "delete from public.characters where owner_id in (select id from auth.users where email like 'ui-%@example.test' or email like 'hb-smoke-%@example.test' or email like 'local-smoke-%@example.test'); delete from public.items where owner_id in (select id from auth.users where email like 'hb-smoke-%@example.test' or email like 'local-smoke-%@example.test'); delete from public.campaigns where name in ('UI Test Campaign', 'UI Refinement Campaign', 'UI Hardening Campaign', 'UI Adversarial Campaign', 'UI Adversarial Campaign B'); delete from auth.users where email like 'ui-%@example.test' or email like 'hb-smoke-%@example.test' or email like 'local-smoke-%@example.test';" >/dev/null
export APP_URL="http://127.0.0.1:$PORT/"
export SCREENSHOT_DIR="${SCREENSHOT_DIR:-${TEMP:-/tmp}/tavern-ledger-screens}"
# the project server: 127.0.0.1 only, module MIME types, a listen backlog large enough for the parallel module loads
python scripts/local/serve_frontend.py . "$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1
"$PY" supabase/tests/browser/inventory_ui_test.py
RC=$?
echo "== homebrew / legacy smoke test + focus regression"
"$PY" supabase/tests/browser/homebrew_smoke_test.py || RC=1
echo "== derived character stats (AC, armor warnings, weapon proficiency)"
"$PY" supabase/tests/browser/derived_stats_ui_test.py || RC=1
echo "== character lineages (picker, choices, derived values)"
"$PY" supabase/tests/browser/lineage_ui_test.py || RC=1
echo "== spells (catalog, spellbook, sources, export/import)"
"$PY" supabase/tests/browser/spell_ui_test.py || RC=1
echo "== classes, spell slots, Pact Magic and rests"
"$PY" supabase/tests/browser/class_slot_ui_test.py || RC=1
echo "== class feature engine (synthetic test class: features, choices, subclass, resources, reviews)"
"$PY" supabase/tests/browser/class_feature_ui_test.py || RC=1
# per-class phases of the official class catalog (class page, choices, resources, subclass, combat values)
for t in supabase/tests/browser/class_*_ui_test.py; do
  case "$t" in *class_slot_ui_test.py|*class_feature_ui_test.py) continue;; esac
  echo "== $(basename "$t" .py)"
  (cd supabase/tests/browser && "$PY" "$(basename "$t")") || RC=1
done
echo "== spell visual system (school and damage tokens, multi-type spells, readiness)"
(cd supabase/tests/browser && "$PY" spell_visual_ui_test.py) || RC=1
echo "== backgrounds (picker, 2024 increases, grants, equipment review, legacy, export / import)"
(cd supabase/tests/browser && "$PY" background_ui_test.py) || RC=1
echo "== proficiency resolution (class, lineage, background and manual sources)"
(cd supabase/tests/browser && "$PY" proficiency_ui_test.py) || RC=1
echo "== Wild Shape (picker, review, active form sheet, form HP and carry-over, Combat Wild Shape, Realtime, mobile)"
(cd supabase/tests/browser && "$PY" wild_shape_ui_test.py) || RC=1
echo "== DM Space, governance, approvals, feats and custom content (20261019*)"
(cd supabase/tests/browser && "$PY" dm_space_ui_test.py) || RC=1
echo "== Herbs & Plants identification (decoy, Examine with a physical roll, DM confirm, per-character reveal, leak checks)"
(cd supabase/tests/browser && "$PY" herb_identification_ui_test.py) || RC=1
echo "== per-character item reveal (DM Space Who knows what: reveal to one / party, partial, undo; player B never receives the truth)"
(cd supabase/tests/browser && "$PY" item_reveal_ui_test.py) || RC=1
echo "== player-first redesign (typography, sections, bottom navigation, home cards, icons, Build, Wild Shape vitals, DM Needs you)"
(cd supabase/tests/browser && "$PY" ux_redesign_ui_test.py) || RC=1
(cd supabase/tests/browser && "$PY" ui_refinement_ui_test.py) || RC=1
echo "== Skills blocks restored inside the Skills section + school-only spell icons (2026-10-22 correction)"
(cd supabase/tests/browser && "$PY" skills_spell_icon_ui_test.py) || RC=1
echo "== original character-sheet visual language: vitals, ability cards, inventory metrics, headings (2026-10-22 v6)"
(cd supabase/tests/browser && "$PY" original_ui_test.py) || RC=1
echo "== V6 product hardening: home, vitals, abilities, play, spells, inventory, build, Wild Shape, locks, DM, hidden data, a11y, reliability"
(cd supabase/tests/browser && "$PY" v6_product_hardening_ui_test.py) || RC=1
echo "== deployment: frontend environment selection (local / staging / production host / unknown host; hosted requests blocked)"
(cd supabase/tests/browser && "$PY" deployment_environment_test.py) || RC=1
echo "== synthetic data of the suites above removed before the isolated V6.2 suites (they start from zero residue)"
(cd supabase/tests/browser && "$PY" -c "import isolation; print('removed', isolation.cleanup()); r = isolation.residue(); print('residue', r); raise SystemExit(1 if r else 0)") || RC=1
echo "== V6.2 test isolation harness (synthetic setup, cleanup, interrupted cleanup, protected-table digests)"
(cd supabase/tests/browser && "$PY" v62_test_isolation_test.py) || RC=1
echo "== V6.2 adversarial API: hidden data sweep, authorization matrix, atomic approvals, custom content lifecycle, validation"
(cd supabase/tests/browser && "$PY" v62_adversarial_api_test.py) || RC=1
echo "== V6.2 adversarial UI: injection payloads, malformed numbers, interrupted / offline saves, error boundaries, deep links, storage"
(cd supabase/tests/browser && "$PY" v62_adversarial_ui_test.py) || RC=1
echo "== V6.2 import safety, multi-session, Realtime soak, long-session soak, performance"
(cd supabase/tests/browser && "$PY" v62_import_session_soak_test.py) || RC=1
echo "== production incident 2026-10-23: cancelled obsolete reads, Realtime attribution and reconnect, catalog pickers (150 ms latency)"
(cd supabase/tests/browser && "$PY" production_timeout_incident_test.py) || RC=1
echo "== fluent read architecture: one request per open, tab bundles, coalesced reloads, 2 Realtime bindings, fallback, cache isolation"
(cd supabase/tests/browser && "$PY" fluent_read_ui_test.py) || RC=1
echo "== gameplay polish: icons, coin calculator, Hungry Jaws counter, Magic Initiate spells, type-aware DM item editor"
(cd supabase/tests/browser && "$PY" gameplay_polish_ui_test.py) || RC=1
echo "== Combat Builder: navigation, builder, library, initiative, turns, HP, effects, Realtime, homebrew, responsive, a11y"
(cd supabase/tests/browser && "$PY" combat_builder_ui_test.py) || RC=1
echo "== Combat Builder API: authorization matrix, RLS, player-safe read model, change log"
"$PY" supabase/tests/api/combat_api_test.py || RC=1
echo "== Feat removal and ability sources: review dialog, source-granted feats, governance, Realtime, ability rows, Combat Builder follow-through"
(cd supabase/tests/browser && "$PY" feat_removal_ui_test.py) || RC=1
echo "== Combined follow-up: final-total Initiative, Wild Shape overflow, class options and infusions in Play, herbs, icons, deletion"
(cd supabase/tests/browser && "$PY" combined_followup_ui_test.py) || RC=1
echo "== Active features and content management: lineage / feat Play cards, feat choice repair, Combat Builder features, usage, delete, duplicate official"
(cd supabase/tests/browser && "$PY" active_features_ui_test.py) || RC=1
echo "== Performance release 2026-11: resource-only refresh, Home cards through the read cache, catalog caches on a user switch"
(cd supabase/tests/browser && "$PY" performance_release_ui_test.py) || RC=1
echo "== Forgot password + email links: flag off / on, PKCE and token_hash reset links, expired links, magic link user switch"
(cd supabase/tests/browser && "$PY" auth_reset_ui_test.py) || RC=1
exit $RC
