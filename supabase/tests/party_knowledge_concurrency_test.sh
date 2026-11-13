#!/usr/bin/env bash
# Concurrency checks for party-wide identification (20261114000100, B1): a share never waits on or deadlocks with another
# character's transaction. Two sessions at the same time (each holds its own character row first, as the existing RPCs do):
#   1. player 1's apply_character_condition holds C1 (3 s) while player 2's successful examine shares to C1
#      -> player 2 does not wait, a pending row is left for C1, C1's own sync_party_knowledge applies it
#   2. two members examine DIFFERENT items at the same moment -> both succeed, both items end known by both (after the sync)
#   3. two members examine the SAME item at the same moment -> both succeed, both know it
#   4. the DM's dm_reveal_item(item, every character) while player 1 holds C1 -> C1 reported busy and NOT changed; the others
#      are revealed and their single party share reaches C1 later as a pending share (C1's sync)
#   5. review round 2, N1: the DM reveals to C1 while C1 is busy -> busy, unchanged, nothing queued; the DM then hides it from
#      C1; C1's sync -> still hidden and held; nothing spread to C2
#   6. a pending share for C1 exists; the DM then hides the item from C1 -> the pending share is gone, C1's sync leaves it hidden
# Every case: no 40P01 in either session and pg_stat_database.deadlocks unchanged. Synthetic objects only, removed at the end.
# Usage: bash supabase/tests/party_knowledge_concurrency_test.sh <db container>
set -uo pipefail
NAME=${1:-supabase_db_tavern_ledger}
px() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -At -q -v ON_ERROR_STOP=1 "$@"; }
P1=a8888888-8888-8888-8888-8888888888e1; P2=a8888888-8888-8888-8888-8888888888e2; DM=a8888888-8888-8888-8888-8888888888e3
CAMP=c8888888-8888-8888-8888-8888888888e1; C1=a8888888-0000-0000-0000-0000000000e1; C2=a8888888-0000-0000-0000-0000000000e2
RC=0
px <<SQL >/dev/null
insert into auth.users (id, email) values ('$P1', 'pk-race-p1@test'), ('$P2', 'pk-race-p2@test'), ('$DM', 'pk-race-dm@test') on conflict do nothing;
insert into public.campaigns (id, name, created_by) values ('$CAMP', 'Party Race', '$DM') on conflict do nothing;
insert into public.campaign_members (campaign_id, user_id, role) values ('$CAMP', '$P1', 'player'), ('$CAMP', '$P2', 'player'), ('$CAMP', '$DM', 'dm')
  on conflict do nothing;
insert into public.characters (id, owner_id, name, campaign_id, strength, constitution, hp_max, hp_current) values
  ('$C1', '$P1', 'Race One', '$CAMP', 10, 10, 10, 10), ('$C2', '$P2', 'Race Two', '$CAMP', 10, 10, 10, 10) on conflict do nothing;
insert into public.items (id, name, kind_id, owner_id, campaign_id, stackable, secret)
select 'hb-pk-race-' || k, 'Race Herb ' || k, 'herbs_plants', '$DM', '$CAMP', true, true from unnest(array['a', 'b', 'c', 'd', 'e', 'f', 'g']) k on conflict do nothing;
insert into public.item_secrets (item_id, unidentified_name, identify_dc, identify_auto)
select 'hb-pk-race-' || k, 'Race decoy', 10, true from unnest(array['a', 'b', 'c', 'd', 'e', 'f', 'g']) k on conflict do nothing;
SQL
as_user() { printf "begin;\nselect set_config('request.jwt.claim.sub', '%s', true);\nset local role authenticated;\n%s\nselect pg_sleep(%s);\ncommit;\n" "$1" "$2" "$3"; }
run() { as_user "$1" "$2" 0 | px; }
give() { run "$DM" "select public.dm_give_item('hb-pk-race-$1', array['$C1', '$C2']::uuid[], 1, false);" >/dev/null; }
row() { px -c "select ii.id from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id where inv.character_id = '$1' and ii.item_id = 'hb-pk-race-$2' limit 1"; }
state() { px -c "select coalesce((select state from public.character_item_knowledge where character_id = '$1' and item_id = 'hb-pk-race-$2'), 'none')"; }
held() { px -c "select coalesce((select held_by_dm::text from public.character_item_knowledge where character_id = '$1' and item_id = 'hb-pk-race-$2'), 'none')"; }
pending() { px -c "select count(*) from public.party_share_pending where target_character_id = '$1'"; }
deadlocks() { sleep 1; px -c "select deadlocks from pg_stat_database where datname = current_database()"; }
lockme() { echo "select 1 from public.characters where id = '$1' for update;"; }
examine() { echo "select public.examine_inventory_item('$(row "$1" "$2")', 'nature', 15) ->> 'status';"; }
pair() {   # $1 user / $2 statements of session 1 (holds $5 s at the end), $3 user / $4 statements of session 2 (starts $6 s later)
  O1=$(mktemp); E1=$(mktemp); O2=$(mktemp); E2=$(mktemp)
  as_user "$1" "$2" "$5" | px >"$O1" 2>"$E1" & PID=$!
  sleep "$6"
  T0=$(date +%s%N); as_user "$3" "$4" 0 | px >"$O2" 2>"$E2"; S2=$?; T2=$(( ($(date +%s%N) - T0) / 1000000 ))
  wait $PID; S1=$?
  OUT1=$(tr '\n' ' ' <"$O1"); OUT2=$(tr '\n' ' ' <"$O2"); ERR=$(cat "$E1" "$E2" | tr '\n' ' ' | tail -c 300)
  rm -f "$O1" "$E1" "$O2" "$E2"
}
check() { if eval "$2"; then echo "PASSED  $1"; else echo "FAILED  $1 ($3)"; RC=1; fi; }
D0=$(deadlocks)

# 1. a player's condition click holds C1; the other player's successful examine shares to C1 without waiting
give a
pair "$P1" "$(lockme "$C1") select public.apply_character_condition('$C1', null, 'Race Dazed', false, null, null) is not null;" \
     "$P2" "$(examine "$C2" a)" 3 1
PEND=$(pending "$C1"); A1=$(state "$C1" a)
SYNC=$(run "$P1" "select public.sync_party_knowledge('$C1')::text;" | sed -n 2p); A1B=$(state "$C1" a)
check "1 condition on C1 vs the other player's examine: the examine succeeds without waiting (${T2} ms), C1 gets a pending row, C1's own sync applies it" \
  '[ "$S1" = 0 ] && [ "$S2" = 0 ] && echo "$OUT2" | grep -q succeeded && [ "$T2" -lt 1500 ] && [ "$PEND" = 1 ] && [ "$A1" = unidentified ] && [ "$A1B" = identified ] && ! echo "$ERR" | grep -q "40P01\|deadlock"' \
  "s1=$S1 s2=$S2 out2=$OUT2 ms=$T2 pending=$PEND before=$A1 after=$A1B sync=$SYNC err=$ERR"

# 2. two members examine different items at the same moment (each holds its own character first)
give b; give c
pair "$P1" "$(lockme "$C1") select pg_sleep(2); $(examine "$C1" b)" "$P2" "$(lockme "$C2") select pg_sleep(2); $(examine "$C2" c)" 0 0.5
run "$P1" "select public.sync_party_knowledge('$C1');" >/dev/null; run "$P2" "select public.sync_party_knowledge('$C2');" >/dev/null
K="$(state "$C1" b) $(state "$C1" c) $(state "$C2" b) $(state "$C2" c)"
check "2 different items examined at once: both succeed, after the syncs both characters know both items" \
  '[ "$S1" = 0 ] && [ "$S2" = 0 ] && echo "$OUT1" | grep -q succeeded && echo "$OUT2" | grep -q succeeded && [ "$K" = "identified identified identified identified" ] && ! echo "$ERR" | grep -q "40P01\|deadlock"' \
  "s1=$S1 s2=$S2 out1=$OUT1 out2=$OUT2 knowledge=$K err=$ERR"

# 3. the same item examined at once by both
give d
pair "$P1" "$(lockme "$C1") select pg_sleep(2); $(examine "$C1" d)" "$P2" "$(lockme "$C2") select pg_sleep(2); $(examine "$C2" d)" 0 0.5
run "$P1" "select public.sync_party_knowledge('$C1');" >/dev/null; run "$P2" "select public.sync_party_knowledge('$C2');" >/dev/null
K="$(state "$C1" d) $(state "$C2" d)"
check "3 the same item examined at once: no deadlock, both sessions end without error, both know it" \
  '[ "$S1" = 0 ] && [ "$S2" = 0 ] && [ "$K" = "identified identified" ] && ! echo "$ERR" | grep -q "40P01\|deadlock"' \
  "s1=$S1 s2=$S2 out1=$OUT1 out2=$OUT2 knowledge=$K err=$ERR"

# 4. the DM reveals to every character while player 1 holds C1 (this loop deadlocked at 0a05e81)
give e
pair "$P1" "$(lockme "$C1") select public.apply_character_condition('$C1', null, 'Race Dazed Two', false, null, null) is not null;" \
     "$DM" "select public.dm_reveal_item('hb-pk-race-e', null, null, '$CAMP')::text;" 3 1
PEND=$(pending "$C1"); run "$P1" "select public.sync_party_knowledge('$C1');" >/dev/null
K="$(state "$C1" e) $(state "$C2" e)"
check "4 dm_reveal_item for every character while C1 is busy: no wait (${T2} ms), C1 reported busy and NOT changed; the party share reaches C1 through its sync" \
  '[ "$S1" = 0 ] && [ "$S2" = 0 ] && echo "$OUT2" | grep -q "\"busy\": 1" && [ "$T2" -lt 1500 ] && [ "$PEND" -ge 1 ] && [ "$K" = "identified identified" ] && ! echo "$ERR" | grep -q "40P01\|deadlock"' \
  "s2=$S2 out2=$OUT2 ms=$T2 pending=$PEND knowledge=$K err=$ERR"

# 5. the reviewer's sequence: a reveal for a busy C1 is not queued, a later hide wins
give f
pair "$P1" "$(lockme "$C1") select public.apply_character_condition('$C1', null, 'Race Dazed Three', false, null, null) is not null;" \
     "$DM" "select public.dm_set_item_knowledge('hb-pk-race-f', array['$C1']::uuid[], '{all}', 'raise', '$CAMP')::text;" 3 1
R5=$OUT2; P5=$(pending "$C1"); S5=$(state "$C1" f)
run "$DM" "select public.dm_set_item_knowledge('hb-pk-race-f', array['$C1']::uuid[], '{}', 'set', '$CAMP');" >/dev/null
run "$P1" "select public.sync_party_knowledge('$C1');" >/dev/null
K="$(state "$C1" f) $(held "$C1" f) $(state "$C2" f)"
check "5 N1: the DM's reveal to busy C1 -> busy, unchanged, nothing queued; the DM's hide afterwards wins: C1's sync leaves it hidden and held, C2 learns nothing" \
  '[ "$S2" = 0 ] && echo "$R5" | grep -q "\"busy\": 1" && [ "$P5" = 0 ] && [ "$S5" = unidentified ] && [ "$K" = "unidentified true unidentified" ] && ! echo "$ERR" | grep -q "40P01\|deadlock"' \
  "out2=$R5 pending=$P5 before=$S5 after=$K err=$ERR"

# 6. a pending share, then the DM holds the target: the share is gone
give g
pair "$P1" "$(lockme "$C1") select public.apply_character_condition('$C1', null, 'Race Dazed Four', false, null, null) is not null;" \
     "$P2" "$(examine "$C2" g)" 3 1
P6=$(pending "$C1")
run "$DM" "select public.dm_set_item_knowledge('hb-pk-race-g', array['$C1']::uuid[], '{}', 'set', '$CAMP');" >/dev/null
P6B=$(px -c "select count(*) from public.party_share_pending where target_character_id = '$C1' and item_id = 'hb-pk-race-g'")
run "$P1" "select public.sync_party_knowledge('$C1');" >/dev/null
K="$(state "$C1" g) $(held "$C1" g)"
check "6 a pending share for C1, then the DM hides the item from C1: the pending share is deleted, C1's sync leaves it hidden and held" \
  '[ "$S2" = 0 ] && echo "$OUT2" | grep -q succeeded && [ "$P6" -ge 1 ] && [ "$P6B" = 0 ] && [ "$K" = "unidentified true" ]' \
  "out2=$OUT2 pending=$P6 after_hide=$P6B knowledge=$K err=$ERR"

D1=$(deadlocks)
check "pg_stat_database.deadlocks did not move ($D0 -> $D1)" '[ "$D0" = "$D1" ]' "$D0 -> $D1"

# cleanup (synthetic objects only)
px >/dev/null <<SQL
delete from public.party_share_pending where target_character_id in ('$C1', '$C2');
delete from public.characters where id in ('$C1', '$C2');
delete from public.items where id like 'hb-pk-race-%';
delete from public.campaigns where id = '$CAMP';
delete from auth.users where id in ('$P1', '$P2', '$DM');
SQL
[ "$RC" = 0 ] && echo "PASSED  party knowledge concurrency (7 / 7)" || echo "FAILED  party knowledge concurrency"
exit "$RC"
