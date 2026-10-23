#!/usr/bin/env bash
# Concurrency check for expend_standard_spell_slot: two sessions spend the last 1st-level slot at the same time.
# Expected: the first succeeds, the second waits for the character lock and then fails; exactly one 'expend' event exists.
# Called by run_local.sh against the throwaway container (needs classes.sql).
set -uo pipefail
NAME=${1:-tavern-ledger-pgtest}
px() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -At -q -v ON_ERROR_STOP=1 "$@"; }
ALICE=a9999999-9999-9999-9999-99999999999a
CHAR=aaaaaaaa-0000-0000-0000-0000000000c2
px <<SQL >/dev/null
insert into auth.users (id, email) values ('$ALICE', 'slot-alice@test') on conflict do nothing;
insert into public.characters (id, owner_id, name) values ('$CHAR', '$ALICE', 'Slot Racer') on conflict do nothing;
begin;
select set_config('request.jwt.claim.sub', '$ALICE', true);
set local role authenticated;
select public.set_character_class('$CHAR', 'wizard-phb', 1);                              -- two 1st-level slots
select public.expend_standard_spell_slot('$CHAR', 1);                                     -- one left
commit;
SQL
run() {  # $1 = seconds to hold the transaction open after spending the slot
px <<SQL
begin;
select set_config('request.jwt.claim.sub', '$ALICE', true);
set local role authenticated;
select (public.expend_standard_spell_slot('$CHAR', 1) -> 'standard' -> 0 ->> 'remaining');
select pg_sleep($1);
commit;
SQL
}
T0=$(date +%s)
run 3 >/tmp/slot1.out 2>/tmp/slot1.err &
P1=$!
sleep 1
run 0 >/tmp/slot2.out 2>/tmp/slot2.err
S2=$?
T1=$(date +%s)
wait $P1; S1=$?
EVENTS=$(px -c "select count(*) from public.character_resource_events where character_id = '$CHAR' and event_type = 'expend'")
LEFT=$(px -c "select expended from public.character_spell_slot_state where character_id = '$CHAR' and pool = 'standard' and slot_level = 1")
ELAPSED=$((T1 - T0))
echo "session 1 exit=$S1 out=$(tr -d '\n' </tmp/slot1.out | tail -c 20)"
echo "session 2 exit=$S2 err=$(tr -d '\n' </tmp/slot2.err | tail -c 80) (waited ~${ELAPSED}s)"
echo "expend events=$EVENTS expended=$LEFT"
if [ "$S1" = 0 ] && [ "$S2" != 0 ] && [ "$EVENTS" = 2 ] && [ "$LEFT" = 2 ] && [ "$ELAPSED" -ge 2 ] && grep -q "No level 1 slot left" /tmp/slot2.err; then
  echo "PASSED  concurrent spending of the last spell slot: second request waited for the lock and was rejected"
else
  echo "FAILED  concurrent spell slot spending"; exit 1
fi
