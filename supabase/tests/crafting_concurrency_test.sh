#!/usr/bin/env bash
# Concurrency checks for crafting (20261113000100): two sessions at the same time. Session 1 holds its transaction open for
# 3 seconds; session 2 must wait for the attempt row lock and then see the result.
#   1. two DMs approve the same attempt      -> applied once, the ingredients consumed once, the second DM is refused (55000)
#   2. approve and the player's cancel at once -> exactly one final state
# Synthetic users only; everything is removed at the end. Usage: bash supabase/tests/crafting_concurrency_test.sh <db container>
set -uo pipefail
NAME=${1:-supabase_db_tavern_ledger}
px() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -At -q -v ON_ERROR_STOP=1 "$@"; }
P=a9999999-9999-9999-9999-9999999999e1; D1=a9999999-9999-9999-9999-9999999999e2; D2=a9999999-9999-9999-9999-9999999999e3
CAMP=c9999999-9999-9999-9999-9999999999e1; C=aaaaaaaa-0000-0000-0000-0000000000e1
RC=0
px <<SQL >/dev/null
insert into auth.users (id, email) values ('$P', 'craft-player@test'), ('$D1', 'craft-dm1@test'), ('$D2', 'craft-dm2@test') on conflict do nothing;
insert into public.campaigns (id, name, created_by) values ('$CAMP', 'Crafting Race', '$D1') on conflict do nothing;
insert into public.campaign_members (campaign_id, user_id, role) values ('$CAMP', '$P', 'player'), ('$CAMP', '$D1', 'dm'), ('$CAMP', '$D2', 'dm')
  on conflict do nothing;
insert into public.campaign_policy_overrides (campaign_id, action_key, decision) values ('$CAMP', 'inventory.craft', 'player_managed') on conflict do nothing;
insert into public.characters (id, owner_id, name, campaign_id, strength, constitution, hp_max, hp_current) values
  ('$C', '$P', 'Crafting Racer', '$CAMP', 10, 10, 10, 10) on conflict do nothing;
insert into public.items (id, name, kind_id, owner_id, campaign_id, stackable) values
  ('hb-craft-race-leaf', 'Race Leaf', 'herbs_plants', '$D1', '$CAMP', true), ('hb-craft-race-out', 'Race Draught', 'gear', '$D1', '$CAMP', true)
  on conflict do nothing;
SQL
as_user() { printf "begin;\nselect set_config('request.jwt.claim.sub', '%s', true);\nset local role authenticated;\n%s\nselect pg_sleep(%s);\ncommit;\n" "$1" "$2" "$3"; }
run() { as_user "$1" "$2" 0 | px; }
pair() {   # $1 user / $2 statement of session 1 (holds 3 s), $3 user / $4 statement of session 2
  O1=$(mktemp); E1=$(mktemp); O2=$(mktemp); E2=$(mktemp)
  as_user "$1" "$2" 3 | px >"$O1" 2>"$E1" & PID=$!
  sleep 1
  as_user "$3" "$4" 0 | px >"$O2" 2>"$E2"; S2=$?
  wait $PID; S1=$?
  ERR2=$(tr -d '\n' <"$E2" | tail -c 160)
  rm -f "$O1" "$E1" "$O2" "$E2"
}
check() { if eval "$2"; then echo "PASSED  $1"; else echo "FAILED  $1 ($3)"; RC=1; fi; }
INV=$(px -c "select id from public.inventories where character_id = '$C' and kind = 'character' limit 1")
REC=$(run "$D1" "select public.dm_save_recipe('$CAMP', '{\"name\": \"Race Brew\", \"check_key\": \"nature\", \"check_dc\": 10, \"output_item_id\": \"hb-craft-race-out\", \"ingredients\": [{\"item_id\": \"hb-craft-race-leaf\", \"quantity\": 2}]}') ->> 'id';" | sed -n 2p)
run "$D1" "select public.dm_set_recipe_status('$REC', 'published') ->> 'status';" >/dev/null
attempt() {   # a fresh stack of 5 leaves and one pending attempt using 2 of them -> attempt id
  px -c "delete from public.inventory_items where inventory_id = '$INV'" >/dev/null
  ROW=$(px -c "insert into public.inventory_items (inventory_id, item_id, quantity) values ('$INV', 'hb-craft-race-leaf', 5) returning id" | head -1)
  run "$P" "select public.start_craft_attempt('$C', '$REC', '[{\"seq\": 1, \"inventory_item_id\": \"$ROW\", \"quantity\": 2}]', 15, gen_random_uuid()) ->> 'attempt_id';" | sed -n 2p
}
qty() { px -c "select coalesce(sum(quantity), 0) from public.inventory_items where inventory_id = '$INV' and item_id = '$1'"; }

# 1. two DMs approve at once
A=$(attempt)
pair "$D1" "select public.dm_resolve_craft_attempt('$A', 'approve') ->> 'status';" "$D2" "select public.dm_resolve_craft_attempt('$A', 'approve') ->> 'status';"
L=$(qty hb-craft-race-leaf); O=$(qty hb-craft-race-out); ST=$(px -c "select status from public.crafting_attempts where id = '$A'")
EV=$(px -c "select count(*) from public.inventory_events where metadata ->> 'craft_attempt' = '$A' and action = 'remove'")
check "two DMs approve the same attempt: applied once (5 -> 3 leaves, 1 draught, one remove event), the second DM is refused" \
  '[ "$S1" = 0 ] && [ "$S2" != 0 ] && [ "$L" = 3 ] && [ "$O" = 1 ] && [ "$ST" = applied ] && [ "$EV" = 1 ] && echo "$ERR2" | grep -q "already answered"' \
  "s1=$S1 s2=$S2 leaves=$L out=$O status=$ST events=$EV err=$ERR2"

# 2. approve and the player's cancel at once
A=$(attempt)
pair "$D1" "select public.dm_resolve_craft_attempt('$A', 'approve') ->> 'status';" "$P" "select public.cancel_craft_attempt('$A') ->> 'status';"
L=$(qty hb-craft-race-leaf); ST=$(px -c "select status from public.crafting_attempts where id = '$A'")
check "approve and cancel at once: exactly one final state (applied, consumed once; the cancel is refused)" \
  '[ "$S1" = 0 ] && [ "$S2" != 0 ] && [ "$ST" = applied ] && [ "$L" = 3 ]' "s1=$S1 s2=$S2 leaves=$L status=$ST err=$ERR2"

# cleanup (synthetic objects only)
px >/dev/null <<SQL
delete from public.characters where id = '$C';
delete from public.campaigns where id = '$CAMP';
delete from public.items where id in ('hb-craft-race-leaf', 'hb-craft-race-out');
delete from auth.users where id in ('$P', '$D1', '$D2');
SQL
[ "$RC" = 0 ] && echo "PASSED  crafting concurrency (2 / 2)" || echo "FAILED  crafting concurrency"
exit "$RC"
