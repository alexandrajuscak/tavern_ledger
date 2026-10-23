#!/usr/bin/env bash
# Concurrency check for use_inventory_item: two sessions use the last piece of the same stack at the same time.
# Expected: the first succeeds, the second waits for the row lock and then fails; exactly one 'use' event exists.
# Called by run_local.sh against the throwaway container.
set -uo pipefail
NAME=${1:-tavern-ledger-pgtest}
px() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -At -q -v ON_ERROR_STOP=1 "$@"; }
ALICE=a9999999-9999-9999-9999-999999999999
px -v ON_ERROR_STOP=1 <<SQL >/dev/null
insert into auth.users (id, email) values ('$ALICE', 'conc-alice@test') on conflict do nothing;
insert into public.characters (id, owner_id, name) values ('aaaaaaaa-0000-0000-0000-0000000000c1', '$ALICE', 'Concurrent') on conflict do nothing;
SQL
INV=$(px -c "select id from public.inventories where character_id = 'aaaaaaaa-0000-0000-0000-0000000000c1'")
ITEM=$(px <<SQL | tail -1
begin;
select set_config('request.jwt.claim.sub', '$ALICE', true);
set local role authenticated;
select public.add_inventory_item('$INV', 'potion-of-healing-common', 1);
commit;
SQL
)
run() {  # $1 = seconds to hold the transaction open after using the potion
px <<SQL
begin;
select set_config('request.jwt.claim.sub', '$ALICE', true);
set local role authenticated;
select (public.use_inventory_item('$ITEM', 1) ->> 'consumed');
select pg_sleep($1);
commit;
SQL
}
T0=$(date +%s)
run 3 >/tmp/conc1.out 2>/tmp/conc1.err &
P1=$!
sleep 1
run 0 >/tmp/conc2.out 2>/tmp/conc2.err
S2=$?
T1=$(date +%s)
wait $P1; S1=$?
EVENTS=$(px -c "select count(*) from public.inventory_events where inventory_id = '$INV' and action = 'use'")
LEFT=$(px -c "select count(*) from public.inventory_items where id = '$ITEM'")
ELAPSED=$((T1 - T0))
echo "session 1 exit=$S1 out=$(tr -d '\n' </tmp/conc1.out | tail -c 20)"
echo "session 2 exit=$S2 err=$(tr -d '\n' </tmp/conc2.err | tail -c 80) (waited ~${ELAPSED}s)"
echo "use events=$EVENTS rows left=$LEFT"
if [ "$S1" = 0 ] && [ "$S2" != 0 ] && [ "$EVENTS" = 1 ] && [ "$LEFT" = 0 ] && [ "$ELAPSED" -ge 2 ] && grep -q "not found" /tmp/conc2.err; then
  echo "PASSED  concurrent double use of the last piece: second request waited for the lock and was rejected"
else
  echo "FAILED  concurrent double use"; exit 1
fi
