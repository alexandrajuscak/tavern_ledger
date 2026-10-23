#!/usr/bin/env bash
# Concurrency check for expend_character_resource (class feature engine, 20261015001800): two sessions spend the last use
# of a class resource at the same time. Expected: the first succeeds, the second waits for the character lock and then
# fails; exactly one 'expend' event exists. Needs the seeds and supabase/tests/fixtures/class_feature_engine_fixture.sql.
# Usage: bash supabase/tests/feature_resource_concurrency_test.sh <db container>  (run_local.sh / run_supabase_local.sh)
set -uo pipefail
NAME=${1:-tavern-ledger-pgtest}
px() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -At -q -v ON_ERROR_STOP=1 "$@"; }
ALICE=a9999999-9999-9999-9999-99999999998a
CHAR=aaaaaaaa-0000-0000-0000-0000000000f2
OUT1=$(mktemp); ERR1=$(mktemp); OUT2=$(mktemp); ERR2=$(mktemp)
px <<SQL >/dev/null
insert into auth.users (id, email) values ('$ALICE', 'resource-alice@test') on conflict do nothing;
insert into public.characters (id, owner_id, name) values ('$CHAR', '$ALICE', 'Resource Racer') on conflict do nothing;
begin;
select set_config('request.jwt.claim.sub', '$ALICE', true);
set local role authenticated;
select public.set_character_class('$CHAR', 'engine-test-fixture', 1);                 -- Test Surge: one use
commit;
SQL
KEY="f:$(px -c "select id from public.character_classes where character_id = '$CHAR'"):et-surge-uses"
run() {  # $1 = seconds to hold the transaction open after spending
px <<SQL
begin;
select set_config('request.jwt.claim.sub', '$ALICE', true);
set local role authenticated;
select public.expend_character_resource('$CHAR', '$KEY') ->> 'remaining';
select pg_sleep($1);
commit;
SQL
}
T0=$(date +%s)
run 3 >"$OUT1" 2>"$ERR1" &
P1=$!
sleep 1
run 0 >"$OUT2" 2>"$ERR2"
S2=$?
T1=$(date +%s)
wait $P1; S1=$?
EVENTS=$(px -c "select count(*) from public.character_resource_events where character_id = '$CHAR' and event_type = 'expend' and feature_resource_id = 'et-surge-uses'")
USED=$(px -c "select expended from public.character_resources where character_id = '$CHAR' and feature_resource_id = 'et-surge-uses'")
ELAPSED=$((T1 - T0))
echo "session 1 exit=$S1 out=$(tr -d '\n' <"$OUT1" | tail -c 20)"
echo "session 2 exit=$S2 err=$(tr -d '\n' <"$ERR2" | tail -c 80) (waited ~${ELAPSED}s)"
echo "expend events=$EVENTS expended=$USED"
px -c "delete from public.characters where id = '$CHAR'; delete from auth.users where id = '$ALICE';" >/dev/null
if [ "$S1" = 0 ] && [ "$S2" != 0 ] && [ "$EVENTS" = 1 ] && [ "$USED" = 1 ] && [ "$ELAPSED" -ge 2 ] && grep -q "Not enough Test Surge left" "$ERR2"; then
  rm -f "$OUT1" "$ERR1" "$OUT2" "$ERR2"
  echo "PASSED  concurrent spending of the last class resource use: second request waited for the lock and was rejected"
else
  rm -f "$OUT1" "$ERR1" "$OUT2" "$ERR2"
  echo "FAILED  concurrent class resource spending"; exit 1
fi
