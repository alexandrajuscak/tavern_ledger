#!/usr/bin/env bash
# Full LOCAL Supabase stack test (Supabase CLI + Docker): real Postgres image, GoTrue Auth, PostgREST, Realtime, Storage.
# Never touches a remote project: it refuses to run if the project is linked, and only uses --local commands.
# Usage: SUPABASE_CLI=/path/to/supabase bash supabase/tests/run_supabase_local.sh [--keep]
# NOTE: starts from an empty volume (`supabase stop --no-backup`), so it also deletes local DEVELOPMENT data
# created with scripts/start-local.ps1 (docs/LOCAL_DEVELOPMENT.md).
set -uo pipefail
cd "$(dirname "$0")/../.."
SB="${SUPABASE_CLI:-../.tools/supabase-2.118.0/supabase.exe}"
DB=supabase_db_tavern_ledger
EXCLUDE=studio,imgproxy,mailpit,edge-runtime,logflare,vector,supavisor,postgres-meta
FAIL=0
pass() { echo "PASSED  $1"; }
fail() { echo "FAILED  $1"; FAIL=1; }
sb() { "$SB" "$@" 2>&1 | grep -v "new version of Supabase CLI\|recommend updating"; return "${PIPESTATUS[0]}"; }
psqlx() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$DB" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
q() { docker exec -i "$DB" psql -U postgres -At -q -c "$1"; }
# expected counts: migrations from the folder, catalog sizes from the generated class feature seed summary
N=$(ls supabase/migrations/2*.sql | wc -l | tr -d ' ')
FV=$(python -c "import json; print(json.load(open('data/reports/classes/class_feature_seed_summary.json'))['counts']['feature_versions'])")
SC=$(python -c "import json; print(json.load(open('data/reports/classes/class_feature_seed_summary.json'))['counts']['subclasses_catalogued'])")
# the class catalog migrations (after 20261015001800) and their rollbacks, newest first (one rollback per migration)
K=$(ls supabase/migrations/2*.sql | awk -F/ '$NF > "20261015001800_z"' | wc -l | tr -d ' ')
CATALOG_RB="rollback_party_item_knowledge rollback_custom_item_icons rollback_crafting_v1 rollback_item_knowledge_reveal rollback_herb_identification rollback_character_conditions_unified rollback_content_deletion_history rollback_content_management rollback_active_feature_timing rollback_feat_choice_state rollback_class_option_activation rollback_items_herbs_icons_deletion rollback_combat_initiative_wild_shape rollback_feat_removal rollback_combat_builder_functions rollback_combat_builder_schema rollback_cache_put_no_wait rollback_gameplay_polish rollback_progressive_fluent_reads rollback_fluent_read_architecture rollback_derived_stats_items_lookup rollback_v62_hardening rollback_feat_backfill rollback_derived_stats_performance rollback_dm_read_models rollback_hidden_dm_data rollback_dm_content rollback_feat_catalog rollback_change_requests rollback_campaign_governance rollback_wild_shape_engine rollback_backgrounds rollback_proficiency_resolver rollback_rest_report_fix rollback_infusions_and_attunement rollback_creatures_and_transformations rollback_martial_engine_extensions rollback_class_setup_flow rollback_hybrid_caster_extensions rollback_spells_ux rollback_spellcasting_class_extensions rollback_class_page_read_model rollback_class_engine_extensions"
[ "$(echo $CATALOG_RB | wc -w | tr -d ' ')" = "$K" ] || { echo "ABORT: CATALOG_RB lists $(echo $CATALOG_RB | wc -w) rollbacks for $K migrations"; exit 2; }
SEEDS="supabase/seed/reference_data.sql supabase/seed/item_effects.sql supabase/seed/spells.sql supabase/seed/classes.sql supabase/seed/class_features.sql supabase/seed/creatures.sql supabase/seed/lineages.sql supabase/seed/feats.sql supabase/seed/backgrounds.sql supabase/seed/catalog_play_timing.sql"
# per-class SQL tests (supabase/tests/classes): harness + class file + report in one session
class_tests() {
  local ok=0 f out
  for f in supabase/tests/classes/*_tests.sql; do
    out=$(cat supabase/tests/classes/_harness.sql "$f" supabase/tests/classes/_report.sql | psqlx 2>&1)
    echo "$out" | grep -E "FAILED|ERROR"; echo "   $(basename "$f" .sql): $(echo "$out" | grep -E "passed, [0-9]+ failed")"
    echo "$out" | grep -q " 0 failed" || ok=1
  done
  return $ok
}
suite() {   # suite <file> <label>
  local out; out=$(psqlx < "$1" 2>&1)
  echo "$out" | grep -E "FAILED|ERROR"; echo "$out" | grep -E "passed, [0-9]+ failed"
  echo "$out" | grep -q " 0 failed" && pass "$2" || fail "$2"
}

# ---- safety: local only ----------------------------------------------------------------------------
if [ -s supabase/.temp/project-ref ]; then echo "ABORT: this checkout is linked to a remote project (supabase/.temp/project-ref)"; exit 2; fi
python scripts/db/sync_base_migration.py --check || exit 1
python scripts/data-migration/generate_class_feature_seed.py --check >/dev/null && pass "class feature data valid and class_features.sql current (generator --check)" \
  || fail "class feature generator --check"

sb stop --no-backup >/dev/null 2>&1 || true   # this project only: start from an empty local volume
echo "== 1. supabase start (fresh volume: migrations + seed from config.toml)"
sb start -x "$EXCLUDE" | grep -E "Applying|Seeding|Skipping|error|ERROR" || true
[ "$(q 'select count(*) from supabase_migrations.schema_migrations')" = "$N" ] && pass "$N migrations recorded in supabase_migrations.schema_migrations" || fail "migration history"
[ "$(q 'select count(*) from public.items')" = 1146 ] && pass "seed loaded 1146 items" || fail "seed item count"
[ "$(q 'select count(*) from public.lineages')" = 47 ] && [ "$(q "select count(*) from public.lineage_versions")" = 133 ] \
  && pass "lineage seed loaded 47 lineages / 133 versions" || fail "lineage seed counts"
[ "$(q 'select count(*) from public.spell_versions')" = 574 ] && [ "$(q 'select count(*) from public.lineage_trait_effects where spell_version_id is not null')" = 137 ] \
  && pass "spell seed loaded 574 spell versions; 137 lineage spell grants linked" || fail "spell seed counts"
[ "$(q 'select count(*) from public.class_versions where hit_die is not null')" = 13 ] && [ "$(q 'select count(*) from public.class_version_levels')" = 260 ] \
  && [ "$(q 'select count(*) from public.spell_slot_progression_levels')" = 289 ] \
  && pass "class seed loaded 13 class versions, 260 class levels, 289 slot progression rows" || fail "class seed counts"
[ "$(q "select count(*) from public.class_versions where subclass_level is not null")" = 13 ] && [ "$(q 'select count(*) from public.subclass_versions')" = "$SC" ] \
  && [ "$(q 'select count(*) from public.class_feature_versions')" = "$FV" ] \
  && pass "class feature seed: 13 subclass levels, $SC catalogued subclasses, $FV official feature versions" || fail "class feature seed"
echo "   postgres: $(q 'show server_version')"

echo "== 2. seed re-run (idempotent)"
SUM1=$(psqlx -At < supabase/tests/lineage_catalog_checksum.sql); SP1=$(psqlx -At < supabase/tests/spell_catalog_checksum.sql)
CL1=$(psqlx -At < supabase/tests/class_catalog_checksum.sql); CF1=$(psqlx -At < supabase/tests/class_feature_catalog_checksum.sql)
psqlx < supabase/seed/spells.sql >/dev/null 2>&1; psqlx < supabase/seed/classes.sql >/dev/null 2>&1; psqlx < supabase/seed/class_features.sql >/dev/null 2>&1; psqlx < supabase/seed/creatures.sql >/dev/null 2>&1; psqlx < supabase/seed/lineages.sql >/dev/null 2>&1; psqlx < supabase/seed/feats.sql >/dev/null 2>&1; psqlx < supabase/seed/backgrounds.sql >/dev/null 2>&1
SUM2=$(psqlx -At < supabase/tests/lineage_catalog_checksum.sql); SP2=$(psqlx -At < supabase/tests/spell_catalog_checksum.sql)
CL2=$(psqlx -At < supabase/tests/class_catalog_checksum.sql); CF2=$(psqlx -At < supabase/tests/class_feature_catalog_checksum.sql)
[ -n "$CF1" ] && [ "$CF1" = "$CF2" ] && pass "class feature seed run twice: catalog checksum unchanged ($CF1)" || fail "class feature seed not idempotent ($CF1 / $CF2)"
[ -n "$CL1" ] && [ "$CL1" = "$CL2" ] && pass "class seed run twice: progression checksum unchanged ($CL1)" || fail "class seed not idempotent ($CL1 / $CL2)"
[ -n "$SP1" ] && [ "$SP1" = "$SP2" ] && pass "spell seed run twice: catalog checksum unchanged ($SP1)" || fail "spell seed not idempotent ($SP1 / $SP2)"
[ -n "$SUM1" ] && [ "$SUM1" = "$SUM2" ] && pass "lineage seed run twice: catalog checksum unchanged ($SUM1)" || fail "lineage seed not idempotent ($SUM1 / $SUM2)"
cat $SEEDS | psqlx >/dev/null 2>&1 && [ "$(q 'select count(*) from public.items')" = 1146 ] && pass "seed re-run" || fail "seed re-run"

echo "== 3. legacy data path: base schema -> legacy rows -> inventory migrations -> seed -> migrate_legacy_inventory()"
sb db reset --local --version 20261015000000 --no-seed | grep -E "Applying|error|ERROR" || true
psqlx < supabase/tests/02_legacy_fixture.sql && pass "legacy fixture loaded on the base schema" || fail "legacy fixture"
sb migration up --local | grep -E "Applying|error|ERROR" || true
[ "$(q 'select count(*) from supabase_migrations.schema_migrations')" = "$N" ] && pass "migration up applied all migrations on top of legacy data" || fail "migration up"
cat $SEEDS | psqlx >/dev/null 2>&1 || fail "seed after migration up"
psqlx < supabase/tests/03_legacy_migration_check.sql 2>&1 | grep -E "PASSED|ERROR" || true

echo "== 4. SQL tests inside the Supabase database (real auth schema and roles)"
OUT=$(cat supabase/tests/01_expected_counts.sql supabase/tests/inventory_tests.sql | psqlx 2>&1)
echo "$OUT" | grep -E "FAILED|ERROR" ; echo "$OUT" | grep -E "passed, [0-9]+ failed"
echo "$OUT" | grep -q " 0 failed" && pass "SQL test suite on Supabase Postgres" || fail "SQL test suite on Supabase Postgres"
suite supabase/tests/derived_stats_tests.sql "derived character stats SQL tests"
suite supabase/tests/lineage_tests.sql "character lineage SQL tests"
suite supabase/tests/spell_tests.sql "spell catalog / spellbook SQL tests"
suite supabase/tests/class_slot_tests.sql "class levels / spell slots / rests SQL tests"
class_tests && pass "per-class SQL tests (supabase/tests/classes)" || fail "per-class SQL tests"
FX1=$(psqlx < supabase/tests/fixtures/class_feature_engine_fixture.sql 2>&1); FX2=$(psqlx < supabase/tests/fixtures/class_feature_engine_fixture.sql 2>&1)
[ -z "$FX1$FX2" ] && [ "$(q "select count(*) from public.class_feature_unlocks where class_version_id like 'engine-test%' or subclass_version_id like 'engine-test%'")" = 28 ] \
  && pass "synthetic class feature fixture loaded twice (28 unlocks, test scope)" || fail "class feature fixture"
suite supabase/tests/class_feature_tests.sql "class feature engine SQL tests"
bash supabase/tests/feature_resource_concurrency_test.sh "$DB" | tail -1 | grep -q PASSED && pass "concurrent final use of a class resource succeeds once" || fail "class resource concurrency"
WSC=$(bash supabase/tests/wild_shape_concurrency_test.sh "$DB" 2>/dev/null | grep -c "^PASSED")
[ "$WSC" = 4 ] && pass "Wild Shape concurrency: final use, lethal damage, revert vs damage, healing vs damage (4 / 4)" || fail "Wild Shape concurrency ($WSC / 4)"
GVC=$(bash supabase/tests/governance_concurrency_test.sh "$DB" 2>/dev/null | grep -c "^PASSED")
[ "$GVC" = 7 ] && pass "change request concurrency: double approval, approve/reject, approve/cancel, stale correction, lock, idempotency (6 + summary)" || fail "change request concurrency ($GVC / 7)"
bash supabase/tests/crafting_concurrency_test.sh "$DB" | tail -1 | grep -q PASSED && pass "crafting concurrency: two DMs approve at once, approve vs cancel (exactly once)" || fail "crafting concurrency"
bash supabase/tests/party_knowledge_concurrency_test.sh "$DB" | tail -1 | grep -q PASSED && pass "party knowledge concurrency: a share never waits or deadlocks (pending + sync)" || fail "party knowledge concurrency"
T1=$(psqlx -At < supabase/tests/feat_catalog_checksum.sql); psqlx < supabase/seed/feats.sql >/dev/null 2>&1; T2=$(psqlx -At < supabase/tests/feat_catalog_checksum.sql)
[ -n "$T1" ] && [ "$T1" = "$T2" ] && pass "feat seed idempotent (checksum $T1)" || fail "feat seed idempotency"
python scripts/data-migration/generate_feat_seed.py --check >/dev/null && pass "feat data valid, feats.sql and FEAT_COVERAGE.md current (generator --check)" || fail "feats.sql or FEAT_COVERAGE.md out of date"

echo "== 4-000. rollback of the class catalog content and the 20261017* migrations"
GUARD=$(psqlx < supabase/rollback/rollback_class_engine_extensions.sql 2>&1)   # expected to fail while official content uses it
echo "$GUARD" | grep -q "run rollback_class_catalog.sql first" && pass "rollback_class_engine_extensions.sql refuses to run while official class content exists" \
  || fail "rollback_class_engine_extensions.sql guard"
psqlx < supabase/rollback/rollback_class_catalog.sql >/dev/null 2>&1 && [ "$(q "select count(*) from public.class_features where content_scope = 'official'")" = 0 ] \
  && [ "$(q "select count(*) from public.class_features where content_scope = 'test'")" -gt 0 ] \
  && pass "rollback_class_catalog.sql removed the official class content only (test fixture kept)" || fail "rollback_class_catalog.sql"
# the 20261017* migrations, newest first; each rollback restores the definitions of the migration before it
for rb in $CATALOG_RB; do
  psqlx < "supabase/rollback/$rb.sql" >/dev/null 2>&1 && pass "$rb.sql applied" || fail "$rb.sql"
done
[ "$(q 'select count(*) from supabase_migrations.schema_migrations')" = $((N-K)) ] \
  && [ "$(q "select count(*) from information_schema.tables where table_name = 'class_starting_equipment'")" = 0 ] \
  && pass "the $K class catalog migrations are rolled back ($((N-K)) migrations left)" || fail "class catalog migration rollbacks"
suite supabase/tests/class_feature_tests.sql "class feature engine tests pass on the restored 1800 functions"

echo "== 4-00. rollback of the class feature engine only: class, spell and derived tests still pass"
GUARD=$(psqlx < supabase/rollback/rollback_class_levels.sql 2>&1)   # expected to fail while the feature engine exists
echo "$GUARD" | grep -q "run rollback_class_features.sql first" && [ "$(q 'select count(*) from supabase_migrations.schema_migrations')" = $((N-K)) ] \
  && pass "rollback_class_levels.sql refuses to run while the class feature engine exists" || fail "rollback_class_levels.sql guard"
psqlx < supabase/rollback/rollback_class_features.sql >/dev/null 2>&1 \
  && [ "$(q "select count(*) from pg_tables where schemaname = 'public' and (tablename like 'class_feature%' or tablename in ('subclasses', 'character_feature_choices', 'character_optional_features'))")" = 0 ] \
  && [ "$(q 'select count(*) from supabase_migrations.schema_migrations')" = $((N-K-1)) ] && [ "$(q "select count(*) from public.classes")" = 13 ] \
  && [ "$(q "select count(*) from information_schema.columns where table_name = 'character_resources' and column_name = 'feature_resource_id'")" = 0 ] \
  && pass "rollback_class_features.sql removed only the class feature engine ($((N-K-1)) migrations left, fixture gone)" || fail "rollback_class_features.sql"
OUT=$(psqlx < supabase/tests/class_slot_tests.sql 2>&1); echo "$OUT" | grep -E "passed, [0-9]+ failed"
OUT2=$(psqlx < supabase/tests/spell_tests.sql 2>&1); echo "$OUT2" | grep -E "passed, [0-9]+ failed"
OUT3=$(psqlx < supabase/tests/derived_stats_tests.sql 2>&1); echo "$OUT3" | grep -E "passed, [0-9]+ failed"
echo "$OUT" | grep -q " 0 failed" && echo "$OUT2" | grep -q " 0 failed" && echo "$OUT3" | grep -q " 0 failed" \
  && pass "class, spell and derived tests pass on the restored 1700 / 1600 / 1500 functions" || fail "tests after class feature rollback"
echo "== 4-0. rollback of the class level feature only: spell, lineage and derived tests still pass"
GUARD=$(psqlx < supabase/rollback/rollback_spells.sql 2>&1)   # expected to fail; captured first because pipefail hides a grep match
echo "$GUARD" | grep -q "run rollback_class_levels.sql first" && [ "$(q 'select count(*) from supabase_migrations.schema_migrations')" = $((N-K-1)) ] \
  && pass "rollback_spells.sql refuses to run while the class level feature exists" || fail "rollback_spells.sql guard"
psqlx < supabase/rollback/rollback_class_levels.sql >/dev/null 2>&1 \
  && [ "$(q "select count(*) from pg_tables where schemaname = 'public' and tablename in ('character_classes', 'class_version_levels', 'character_resources', 'character_spell_slot_state')")" = 0 ] \
  && [ "$(q 'select count(*) from supabase_migrations.schema_migrations')" = $((N-K-2)) ] && [ "$(q 'select count(*) from public.classes')" = 9 ] \
  && pass "rollback_class_levels.sql removed only the class level feature ($((N-K-2)) migrations left)" || fail "rollback_class_levels.sql"
OUT=$(cat supabase/tests/spell_tests.sql | psqlx 2>&1); echo "$OUT" | grep -E "passed, [0-9]+ failed"
OUT2=$(psqlx < supabase/tests/derived_stats_tests.sql 2>&1); echo "$OUT2" | grep -E "passed, [0-9]+ failed"
echo "$OUT" | grep -q " 0 failed" && echo "$OUT2" | grep -q " 0 failed" && pass "spell and derived tests pass on the restored 1600 / 1500 functions" \
  || fail "spell / derived tests after class rollback"
echo "== 4a. rollback of the spell feature only: lineage and derived tests still pass"
psqlx < supabase/rollback/rollback_spells.sql >/dev/null 2>&1 \
  && [ "$(q "select count(*) from pg_tables where schemaname = 'public' and (tablename like '%spell%' and tablename not in ('spells', 'spell_slots') or tablename like 'class%')")" = 0 ] \
  && [ "$(q 'select count(*) from supabase_migrations.schema_migrations')" = $((N-K-3)) ] \
  && pass "rollback_spells.sql removed only the spell feature ($((N-K-3)) migrations left; free-text spells and slots kept)" || fail "rollback_spells.sql"
suite supabase/tests/lineage_tests.sql "lineage tests pass without the spell feature"
echo "== 4b. rollback of the lineage feature only, derived stats on the restored functions, then re-apply everything"
psqlx < supabase/rollback/rollback_lineages.sql >/dev/null 2>&1 \
  && [ "$(q "select count(*) from pg_tables where schemaname = 'public' and tablename like '%lineage%'")" = 0 ] \
  && [ "$(q 'select count(*) from supabase_migrations.schema_migrations')" = $((N-K-4)) ] \
  && pass "rollback_lineages.sql removed only the lineage feature ($((N-K-4)) migrations left)" || fail "rollback_lineages.sql"
suite supabase/tests/derived_stats_tests.sql "derived stats tests pass on the restored 20261015001400 functions"
sb migration up --local | grep -E "Applying|error|ERROR" || true
psqlx < supabase/seed/spells.sql >/dev/null 2>&1; psqlx < supabase/seed/classes.sql >/dev/null 2>&1; psqlx < supabase/seed/class_features.sql >/dev/null 2>&1; psqlx < supabase/seed/creatures.sql >/dev/null 2>&1; psqlx < supabase/seed/lineages.sql >/dev/null 2>&1; psqlx < supabase/seed/feats.sql >/dev/null 2>&1; psqlx < supabase/seed/backgrounds.sql >/dev/null 2>&1
OUT=$(psqlx < supabase/tests/lineage_tests.sql 2>&1); echo "$OUT" | grep -E "passed, [0-9]+ failed"
OUT2=$(psqlx < supabase/tests/spell_tests.sql 2>&1); echo "$OUT2" | grep -E "passed, [0-9]+ failed"
OUT3=$(psqlx < supabase/tests/class_slot_tests.sql 2>&1); echo "$OUT3" | grep -E "passed, [0-9]+ failed"
class_tests; CT=$?
psqlx < supabase/tests/fixtures/class_feature_engine_fixture.sql >/dev/null 2>&1
OUT4=$(psqlx < supabase/tests/class_feature_tests.sql 2>&1); echo "$OUT4" | grep -E "passed, [0-9]+ failed"
echo "$OUT" | grep -q " 0 failed" && echo "$OUT2" | grep -q " 0 failed" && echo "$OUT3" | grep -q " 0 failed" && echo "$OUT4" | grep -q " 0 failed" \
  && [ "$CT" = 0 ] && [ "$(q 'select count(*) from supabase_migrations.schema_migrations')" = "$N" ] \
  && pass "all rolled-back migrations re-applied with migration up; lineage, spell, class, per-class and feature tests pass again" || fail "re-apply"

echo "== 5. concurrency (two psql sessions)"
bash supabase/tests/concurrency_test.sh "$DB" | tail -1 | grep -q PASSED && pass "concurrent double use" || fail "concurrent double use"

echo "== 6. Supabase specifics"
RT=$(q "select string_agg(tablename, ',' order by tablename) from pg_publication_tables where pubname = 'supabase_realtime' and tablename in ('inventory_items','inventories','character_equipment','inventory_item_modifiers','owned_assets')")
[ "$RT" = "character_equipment,inventories,inventory_item_modifiers,inventory_items,owned_assets" ] && pass "Realtime publication contains the inventory tables" || fail "Realtime publication: $RT"
RT=$(q "select string_agg(tablename, ',' order by tablename) from pg_publication_tables where pubname = 'supabase_realtime' and tablename like 'character_lineage%'")
[ "$RT" = "character_lineage_choices,character_lineages" ] && pass "Realtime publication contains the lineage selections" || fail "Realtime lineage tables: $RT"
RT=$(q "select string_agg(tablename, ',' order by tablename) from pg_publication_tables where pubname = 'supabase_realtime' and tablename in ('character_spells', 'character_spellcasting_sources')")
[ "$RT" = "character_spellcasting_sources,character_spells" ] && pass "Realtime publication contains the character spell tables" || fail "Realtime spell tables: $RT"
RT=$(q "select string_agg(tablename, ',' order by tablename) from pg_publication_tables where pubname = 'supabase_realtime' and tablename in ('character_classes', 'character_spell_slot_state', 'character_temporary_spell_slots', 'character_resources')")
[ "$RT" = "character_classes,character_resources,character_spell_slot_state,character_temporary_spell_slots" ] \
  && pass "Realtime publication contains classes, slot state, temporary slots and resources" || fail "Realtime class tables: $RT"
RT=$(q "select string_agg(tablename, ',' order by tablename) from pg_publication_tables where pubname = 'supabase_realtime' and tablename in ('character_feature_choices', 'character_optional_features')")
[ "$RT" = "character_feature_choices,character_optional_features" ] && pass "Realtime publication contains the feature choices and optional features" || fail "Realtime feature tables: $RT"
SI=$(q "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'v' and 'security_invoker=true' = any(c.reloptions)")
[ "$SI" = 9 ] && pass "all 9 views are security_invoker" || fail "security_invoker views: $SI"
SD=$(q "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prosecdef and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')")
echo "   SECURITY DEFINER functions without a fixed search_path: $SD (base schema helpers are counted too)"
TRGM=$(q "select coalesce((select extnamespace::regnamespace::text from pg_extension where extname = 'pg_trgm'), 'not installed')")
echo "   pg_trgm: $TRGM (deferred by the index audit; nothing depends on it)"

echo "== 7. API contract tests (GoTrue + PostgREST, real JWTs)"
ENV=$("$SB" status -o env 2>/dev/null)
export API_URL=$(echo "$ENV" | sed -n 's/^API_URL="\(.*\)"$/\1/p')
export ANON_KEY=$(echo "$ENV" | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p')
export SERVICE_ROLE_KEY=$(echo "$ENV" | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p')
python supabase/tests/api/api_contract_test.py || FAIL=1
(cd supabase/tests/api && python class_catalog_api_test.py) || FAIL=1
(cd supabase/tests/api && python wild_shape_api_test.py) || FAIL=1
(cd supabase/tests/api && python governance_api_test.py) || FAIL=1
unset ANON_KEY SERVICE_ROLE_KEY

echo "== 8. rollback script on Supabase, then clean re-creation with db reset"
psqlx < supabase/rollback/rollback_inventory.sql >/dev/null 2>&1 && [ "$(q "select count(*) from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE'")" = 11 ] \
  && pass "rollback_inventory.sql returned the database to the base schema" || fail "rollback on Supabase"
sb db reset --local | grep -E "error|ERROR" || true
[ "$(q 'select count(*) from public.items')" = 1146 ] && [ "$(q 'select count(*) from supabase_migrations.schema_migrations')" = "$N" ] \
  && [ "$(q 'select count(*) from public.class_feature_versions')" = "$FV" ] \
  && [ "$(q "select count(*) from public.class_features where content_scope = 'test'")" = 0 ] \
  && pass "db reset --local re-created the database from migrations + seed (no test fixture)" || fail "db reset"

[ "${1:-}" = "--keep" ] || sb stop --no-backup >/dev/null
echo; [ "$FAIL" = 0 ] && echo "ALL SUPABASE CHECKS PASSED" || echo "SOME SUPABASE CHECKS FAILED"
exit "$FAIL"
