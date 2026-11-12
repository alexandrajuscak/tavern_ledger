#!/usr/bin/env bash
# PLAIN POSTGRESQL 15 test (not Supabase): a throwaway container with a small stand-in for Supabase's
# auth schema and API roles (00_local_harness.sql). Fast, but it does NOT test Supabase Auth, PostgREST,
# Realtime or Storage; use run_supabase_local.sh for that.
# Usage: bash supabase/tests/run_local.sh [--keep]
set -euo pipefail
cd "$(dirname "$0")/../.."
NAME=tavern-ledger-pgtest
MIG=supabase/migrations
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=local -e POSTGRES_DB=postgres postgres:15 >/dev/null
until docker exec "$NAME" pg_isready -U postgres -q 2>/dev/null; do sleep 1; done
sleep 2
psqlx() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
q() { docker exec -i "$NAME" psql -U postgres -At -q -c "$1"; }
step() { echo "== $1"; psqlx < "$1" 2>&1 | grep -v "^$" | grep -v "wal_level\|Set wal_level" || true; }
inventory_migrations() { ls $MIG/2*.sql | grep -v _base_schema.sql; }
catalog_migrations() { ls $MIG/2*.sql | awk -F/ '$NF > "20261015001800_z"'; }   # the class catalog migrations (20261017*)
# per-class SQL tests (supabase/tests/classes): harness + class file + report in one session; stops on a failure
class_tests() {
  for f in supabase/tests/classes/*_tests.sql; do
    echo "   $(basename "$f" .sql): $(cat supabase/tests/classes/_harness.sql "$f" supabase/tests/classes/_report.sql | psqlx | grep "passed,")"
  done
}

python scripts/db/sync_base_migration.py --check
step supabase/tests/00_local_harness.sql
step $MIG/20261015000000_base_schema.sql
step supabase/tests/02_legacy_fixture.sql
for f in $(inventory_migrations); do step "$f"; done
step supabase/seed/reference_data.sql
step supabase/seed/item_effects.sql
step supabase/seed/spells.sql
step supabase/seed/classes.sql
step supabase/seed/class_features.sql
step supabase/seed/creatures.sql
step supabase/seed/lineages.sql
step supabase/seed/feats.sql
step supabase/seed/backgrounds.sql
step supabase/seed/catalog_play_timing.sql
step supabase/tests/03_legacy_migration_check.sql
echo "== seed re-run (must be idempotent)"
cat supabase/seed/reference_data.sql supabase/seed/item_effects.sql supabase/seed/spells.sql supabase/seed/classes.sql supabase/seed/class_features.sql supabase/seed/creatures.sql supabase/seed/lineages.sql supabase/seed/feats.sql supabase/seed/backgrounds.sql supabase/seed/catalog_play_timing.sql | psqlx >/dev/null
[ "$(q 'select count(*) from public.items')" = 1146 ] && echo "PASSED  seed re-run kept 1146 items" || { echo "FAILED  seed re-run"; exit 1; }
echo "== tests"
cat supabase/tests/01_expected_counts.sql supabase/tests/inventory_tests.sql | psqlx | tail -n +1 | grep -v "^1$"
echo "== derived character stats tests"
psqlx < supabase/tests/derived_stats_tests.sql | grep -v "^1$"
echo "== derived stats item lookup (incident 2026-10-23, 20261029000100)"
psqlx < supabase/tests/derived_stats_items_lookup_tests.sql | grep -v "^1$"
echo "== character lineage tests"
psqlx < supabase/tests/lineage_tests.sql | grep -v "^1$"
echo "== spell tests"
psqlx < supabase/tests/spell_tests.sql | grep -v "^1$"
echo "== class level / slot / rest tests"
psqlx < supabase/tests/class_slot_tests.sql | grep -v "^1$"
echo "== per-class tests"
class_tests
echo "== class feature seed run twice (catalog checksum must not change, classes.sql and spells.sql in between)"
F1=$(psqlx -At < supabase/tests/class_feature_catalog_checksum.sql)
psqlx < supabase/seed/spells.sql >/dev/null; psqlx < supabase/seed/classes.sql >/dev/null; psqlx < supabase/seed/class_features.sql >/dev/null; psqlx < supabase/seed/creatures.sql >/dev/null
F2=$(psqlx -At < supabase/tests/class_feature_catalog_checksum.sql)
[ "$F1" = "$F2" ] && echo "PASSED  class feature seed idempotent ($F1)" || { echo "FAILED  class feature seed changed the catalog"; exit 1; }
echo "== class seed run twice (progression checksum must not change, spells.sql in between)"
K1=$(psqlx -At < supabase/tests/class_catalog_checksum.sql); psqlx < supabase/seed/spells.sql >/dev/null; psqlx < supabase/seed/classes.sql >/dev/null
K2=$(psqlx -At < supabase/tests/class_catalog_checksum.sql)
[ "$K1" = "$K2" ] && echo "PASSED  class seed idempotent ($K1)" || { echo "FAILED  class seed changed the progression data"; exit 1; }
echo "== spell seed run twice (catalog checksum must not change)"
P1=$(psqlx -At < supabase/tests/spell_catalog_checksum.sql); psqlx < supabase/seed/spells.sql >/dev/null
P2=$(psqlx -At < supabase/tests/spell_catalog_checksum.sql)
[ "$P1" = "$P2" ] && echo "PASSED  spell seed idempotent ($P1)" || { echo "FAILED  spell seed changed the catalog"; exit 1; }
echo "== lineage seed run twice (catalog checksum must not change)"
S1=$(psqlx -At < supabase/tests/lineage_catalog_checksum.sql); psqlx < supabase/seed/lineages.sql >/dev/null
S2=$(psqlx -At < supabase/tests/lineage_catalog_checksum.sql)
[ "$S1" = "$S2" ] && echo "PASSED  lineage seed idempotent ($S1)" || { echo "FAILED  lineage seed changed the catalog"; exit 1; }
echo "== background seed run twice (catalog checksum must not change)"
G1=$(psqlx -At < supabase/tests/background_catalog_checksum.sql); psqlx < supabase/seed/backgrounds.sql >/dev/null
G2=$(psqlx -At < supabase/tests/background_catalog_checksum.sql)
[ -n "$G1" ] && [ "$G1" = "$G2" ] && echo "PASSED  background seed idempotent ($G1)" || { echo "FAILED  background seed changed the catalog"; exit 1; }
echo "== feat seed run twice (catalog checksum must not change, backgrounds.sql in between)"
T1=$(psqlx -At < supabase/tests/feat_catalog_checksum.sql); psqlx < supabase/seed/feats.sql >/dev/null; psqlx < supabase/seed/backgrounds.sql >/dev/null
T2=$(psqlx -At < supabase/tests/feat_catalog_checksum.sql)
[ -n "$T1" ] && [ "$T1" = "$T2" ] && [ "$(q 'select count(*) from public.feat_versions where owner_id is null')" = 408 ] && echo "PASSED  feat seed idempotent ($T1, 408 versions)" || { echo "FAILED  feat seed changed the catalog"; exit 1; }
echo "== class feature engine tests (after the seed checks: classes.sql removes unused test subclasses; fixture loaded twice)"
psqlx < supabase/tests/fixtures/class_feature_engine_fixture.sql; psqlx < supabase/tests/fixtures/class_feature_engine_fixture.sql
psqlx < supabase/tests/class_feature_tests.sql | grep -v "^1$"
echo "== slot concurrency"
bash supabase/tests/slot_concurrency_test.sh "$NAME"
echo "== class resource concurrency"
bash supabase/tests/feature_resource_concurrency_test.sh "$NAME"
echo "== Wild Shape concurrency"
bash supabase/tests/wild_shape_concurrency_test.sh "$NAME" || exit 1
echo "== governance / change request concurrency"
bash supabase/tests/governance_concurrency_test.sh "$NAME" || exit 1
echo "== feat removal (20261107000100): authorization, governance, locks, dependent mechanics, source-granted feats, preview"
psqlx -At < supabase/tests/feat_removal_tests.sql | grep -E "^(FAILED|TOTAL)"
psqlx -At < supabase/tests/feat_removal_tests.sql | grep -q "^TOTAL .*, 0 failed" || { echo "FAILED  feat_removal_tests.sql"; exit 1; }
echo "== feat removal concurrency"
DB="$NAME" bash supabase/tests/feat_removal_concurrency_test.sh 8 || exit 1
echo "== combined follow-up (20261107000200-400): final-total Initiative, Wild Shape overflow, Herbs & Plants, icons, deletion"
psqlx < supabase/seed/combat_monsters.sql >/dev/null   # SRD monsters for the Initiative suite (idempotent seed)
for t in combat_initiative_tests wild_shape_damage_tests items_herbs_icons_tests; do
  out=$(psqlx -At < supabase/tests/$t.sql 2>&1 | grep -E "^(FAILED|TOTAL)|ERROR")
  echo "$out"
  echo "$out" | grep -q "^TOTAL .*, 0 failed" || { echo "FAILED  $t.sql"; exit 1; }
done
echo "== active features / feats / content management (20261109000100-300): feat choice state, Resilient, content usage and deletion"
out=$(psqlx -At < supabase/tests/feat_choice_state_tests.sql 2>&1 | grep -E "^(FAILED|TOTAL)|<--|ERROR")
echo "$out"
echo "$out" | grep -q "^TOTAL .*, 0 failed" || { echo "FAILED  feat_choice_state_tests.sql"; exit 1; }
DB="$NAME" bash supabase/tests/content_deletion_concurrency_test.sh 8 || exit 1
echo "== rollback of the class catalog content and the 20261017* migrations"
if psqlx < supabase/rollback/rollback_class_engine_extensions.sql >/dev/null 2>&1; then echo "FAILED  rollback_class_engine_extensions.sql ran while official content exists"; exit 1; fi
echo "PASSED  rollback_class_engine_extensions.sql refuses to run while official class content exists"
psqlx < supabase/rollback/rollback_class_catalog.sql
# the 20261017* migrations, newest first (one rollback each; same list as run_supabase_local.sh)
for rb in rollback_herb_identification rollback_character_conditions_unified rollback_content_deletion_history rollback_content_management rollback_active_feature_timing rollback_feat_choice_state rollback_class_option_activation rollback_items_herbs_icons_deletion rollback_combat_initiative_wild_shape rollback_feat_removal rollback_combat_builder_functions rollback_combat_builder_schema rollback_derived_stats_items_lookup rollback_v62_hardening rollback_feat_backfill rollback_derived_stats_performance rollback_dm_read_models rollback_hidden_dm_data rollback_dm_content rollback_feat_catalog rollback_change_requests rollback_campaign_governance rollback_wild_shape_engine rollback_backgrounds rollback_proficiency_resolver rollback_rest_report_fix rollback_infusions_and_attunement rollback_creatures_and_transformations rollback_martial_engine_extensions rollback_class_setup_flow rollback_hybrid_caster_extensions rollback_spells_ux rollback_spellcasting_class_extensions rollback_class_page_read_model rollback_class_engine_extensions; do
  psqlx < "supabase/rollback/$rb.sql"
done
[ "$(q "select count(*) from public.class_features where content_scope = 'official'")" = 0 ] \
  && [ "$(q "select count(*) from information_schema.tables where table_name = 'class_starting_equipment'")" = 0 ] \
  && echo "PASSED  official class content and the 20261017* objects removed" || { echo "FAILED  class catalog rollback"; exit 1; }
psqlx < supabase/tests/class_feature_tests.sql | grep "passed,"
echo "== rollback of the class feature engine only (supabase/rollback/rollback_class_features.sql)"
if psqlx < supabase/rollback/rollback_class_levels.sql >/dev/null 2>&1; then echo "FAILED  rollback_class_levels.sql ran while the feature engine exists"; exit 1; fi
echo "PASSED  rollback_class_levels.sql refuses to run while the feature engine exists"
psqlx < supabase/rollback/rollback_class_features.sql
[ "$(q "select count(*) from pg_tables where schemaname = 'public' and (tablename like 'class_feature%' or tablename = 'subclasses' or tablename like 'character_feature%')")" = 0 ] \
  && [ "$(q "select count(*) from public.classes")" = 13 ] && echo "PASSED  class feature tables and the test fixture removed" || { echo "FAILED  class feature rollback"; exit 1; }
psqlx < supabase/tests/class_slot_tests.sql | grep "passed,"
psqlx < supabase/tests/derived_stats_tests.sql | grep "passed,"
echo "== rollback of the class level feature only (supabase/rollback/rollback_class_levels.sql)"
psqlx < supabase/rollback/rollback_class_levels.sql
[ "$(q "select count(*) from pg_tables where schemaname = 'public' and tablename in ('character_classes', 'class_version_levels', 'character_resources')")" = 0 ] \
  && echo "PASSED  class level tables removed" || { echo "FAILED  class level rollback"; exit 1; }
psqlx < supabase/tests/spell_tests.sql | grep "passed,"
psqlx < supabase/tests/derived_stats_tests.sql | grep "passed,"
echo "== rollback of the spell feature only (supabase/rollback/rollback_spells.sql)"
psqlx < supabase/rollback/rollback_spells.sql
[ "$(q "select count(*) from pg_tables where schemaname = 'public' and tablename in ('spell_versions', 'classes', 'character_spells')")" = 0 ] && echo "PASSED  spell tables removed" || { echo "FAILED  spell rollback"; exit 1; }
psqlx < supabase/tests/lineage_tests.sql | grep "passed,"
echo "== rollback of the lineage feature only (supabase/rollback/rollback_lineages.sql)"
psqlx < supabase/rollback/rollback_lineages.sql
[ "$(q "select count(*) from pg_tables where schemaname = 'public' and tablename like '%lineage%'")" = 0 ] && echo "PASSED  lineage tables removed" || { echo "FAILED  lineage rollback"; exit 1; }
psqlx < supabase/tests/derived_stats_tests.sql | grep "passed,"
psqlx < supabase/migrations/20261015001500_character_lineages.sql >/dev/null
psqlx < supabase/migrations/20261015001600_spell_catalog.sql >/dev/null
psqlx < supabase/migrations/20261015001700_class_levels_and_slots.sql >/dev/null
psqlx < supabase/migrations/20261015001800_class_feature_engine.sql >/dev/null
for f in $(catalog_migrations); do psqlx < "$f" >/dev/null; done
psqlx < supabase/seed/spells.sql >/dev/null
psqlx < supabase/seed/classes.sql >/dev/null
psqlx < supabase/seed/class_features.sql >/dev/null
psqlx < supabase/seed/creatures.sql >/dev/null
psqlx < supabase/seed/lineages.sql >/dev/null
psqlx < supabase/seed/feats.sql >/dev/null
psqlx < supabase/seed/backgrounds.sql >/dev/null
psqlx < supabase/tests/lineage_tests.sql | grep "passed,"
psqlx < supabase/tests/spell_tests.sql | grep "passed,"
psqlx < supabase/tests/class_slot_tests.sql | grep "passed,"
class_tests
psqlx < supabase/tests/fixtures/class_feature_engine_fixture.sql >/dev/null
psqlx < supabase/tests/class_feature_tests.sql | grep "passed,"
echo "== concurrency"
bash supabase/tests/concurrency_test.sh "$NAME"
echo "== rollback (supabase/rollback/rollback_inventory.sql)"
psqlx < supabase/rollback/rollback_inventory.sql
TABLES=$(q "select count(*) from pg_tables where schemaname = 'public'")
POLICY=$(q "select string_agg(policyname, ',') from pg_policies where tablename = 'inventory_items'")
COLS=$(q "select count(*) from information_schema.columns where table_name = 'inventory_items'")
EQ=$(q "select count(*) from public.inventory_items where equipped")
if [ "$TABLES" = 11 ] && [ "$POLICY" = inventory_items_all ] && [ "$COLS" = 10 ]; then echo "PASSED  rollback restored the base schema (11 tables, original policy, 10 inventory_items columns)"; else echo "FAILED  rollback: tables=$TABLES policy=$POLICY cols=$COLS"; exit 1; fi
[ "$EQ" = 7 ] && echo "PASSED  rollback restored the 7 legacy equipped flags" || { echo "FAILED  rollback equipped flags: $EQ"; exit 1; }
echo "== re-apply after rollback"
for f in $(inventory_migrations); do psqlx < "$f" >/dev/null; done
cat supabase/seed/reference_data.sql supabase/seed/item_effects.sql supabase/seed/spells.sql supabase/seed/classes.sql supabase/seed/class_features.sql supabase/seed/creatures.sql supabase/seed/lineages.sql supabase/seed/feats.sql supabase/seed/backgrounds.sql supabase/seed/catalog_play_timing.sql | psqlx >/dev/null
cat supabase/tests/01_expected_counts.sql supabase/tests/inventory_tests.sql | psqlx | grep "passed,"
psqlx < supabase/tests/derived_stats_tests.sql | grep "passed,"
psqlx < supabase/tests/lineage_tests.sql | grep "passed,"
psqlx < supabase/tests/spell_tests.sql | grep "passed,"
psqlx < supabase/tests/class_slot_tests.sql | grep "passed,"
class_tests
psqlx < supabase/tests/fixtures/class_feature_engine_fixture.sql >/dev/null
psqlx < supabase/tests/class_feature_tests.sql | grep "passed,"
[ "${1:-}" = "--keep" ] || docker rm -f "$NAME" >/dev/null
