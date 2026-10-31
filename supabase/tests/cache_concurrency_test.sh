#!/usr/bin/env bash
# Regression test of 20261031000200 (read cache write without waiting): concurrent COLD reads of one character by one viewer,
# with overlapping read lists in different orders, must neither deadlock nor return a failed read. Before the fix this produced
# "deadlock detected" (40P01) per-read errors within a few runs. LOCAL Supabase only; reads only (and the cache).
# Usage: bash supabase/tests/cache_concurrency_test.sh [rounds]
set -uo pipefail
DB=supabase_db_tavern_ledger
ROUNDS="${1:-3}"; N=40
q() { docker exec -i "$DB" psql -U postgres -At -c "$1"; }
C=$(q "select c.id from public.characters c where c.owner_id is not null and not exists (select 1 from public.character_transformations t where t.character_id = c.id) order by c.id limit 1")
OW=$(q "select owner_id from public.characters where id = '$C'")
deadlocks() { q "select deadlocks from pg_stat_database where datname = current_database()"; }
reader() {   # $1 label, $2 read list
  { echo "set role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"$OW\",\"role\":\"authenticated\"}', false);"
    for i in $(seq 1 $N); do echo "select public.get_character_reads('$C', $2) -> 'errors';"; done
  } | docker exec -i "$DB" psql -U postgres -qAt 2>&1 | grep -vE '^\{\}$|"sub"|^SET$|^$' | sed "s/^/[$1] /"
}
bumper() {   # invalidates every cached value again and again (cold reads)
  for i in $(seq 1 $N); do echo "update tl_cache.global_rev set rev = rev + 1 where id = 1; select pg_sleep(0.05);"; done \
    | docker exec -i "$DB" psql -U postgres -qAt >/dev/null 2>&1
}
before=$(deadlocks); errors=""
for r in $(seq 1 "$ROUNDS"); do
  out=$( reader A "array['get_character_proficiencies','get_character_lineage','get_character_background','get_character_feats','get_character_class_summary','get_character_spell_slots']" &
         reader B "array['get_character_spell_slots','get_character_class_summary','get_character_feats','get_character_background','get_character_lineage','get_character_proficiencies']" &
         reader C "array['get_character_feats','get_character_spell_slots','get_character_proficiencies']" &
         bumper & wait )
  errors="$errors$out"
done
after=$(deadlocks)
fail=0
[ "$after" = "$before" ] && echo "PASSED  no deadlock in $ROUNDS rounds of concurrent cold reads ($before -> $after)" || { echo "FAILED  deadlocks $before -> $after"; fail=1; }
[ -z "$errors" ] && echo "PASSED  no read returned an error" || { echo "FAILED  read errors:"; echo "$errors" | sort | uniq -c | head; fail=1; }
echo "$((2 - fail)) passed, $fail failed"
exit $fail
