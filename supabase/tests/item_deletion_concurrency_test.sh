#!/usr/bin/env bash
# Permanent item deletion vs. "add to inventory" at the same moment (docs/CUSTOM_ITEM_DELETION.md). LOCAL Supabase only;
# synthetic users (idc-*@example.test), campaign and character, removed at the end.
# For each round a fresh, unused campaign herb is created; then the DM deletes it while the player adds it to an inventory,
# in parallel. Exactly one may win: either the item is gone and no inventory row references it, or the item exists, the
# inventory row exists and the delete was refused with the friendly TLUSE. Never both, never a raw foreign-key error from
# the delete, never a deadlock. Also: the same delete twice in parallel deletes once. Odd rounds: the herb has inventory history
# (added and removed before), which no longer blocks (20261112000100); a winning delete keeps that history with the name stamped.
# Usage: bash supabase/tests/item_deletion_concurrency_test.sh [rounds]
set -uo pipefail
DB=supabase_db_tavern_ledger
N="${1:-15}"
q() { docker exec -i "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 -c "$1"; }
as() { echo "set role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\"}', false);"; }
TAG=$(date +%s)
DM=$(q "select gen_random_uuid()"); PL=$(q "select gen_random_uuid()"); CAMP=$(q "select gen_random_uuid()")
q "insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
     ('$DM', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'idc-dm-$TAG@example.test', now(), now()),
     ('$PL', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'idc-pl-$TAG@example.test', now(), now());
   insert into public.campaigns (id, name, created_by) values ('$CAMP', 'IDC concurrency $TAG', '$DM');
   insert into public.campaign_members (campaign_id, user_id, role) values ('$CAMP', '$DM', 'dm'), ('$CAMP', '$PL', 'player');" >/dev/null
CH=$(q "insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current) values ('$PL', 'IDC Gatherer', '$CAMP', 1, 10, 10) returning id" | head -1)
INV=$(q "select id from public.inventories where character_id = '$CH' and kind = 'character' limit 1")
deadlocks() { q "select deadlocks from pg_stat_database where datname = current_database()"; }
before=$(deadlocks)
won_del=0; won_add=0; both=0; neither=0; raw=0; errs=""; stamped=0; unstamped=0
for r in $(seq 1 "$N"); do
  NAME="IDC Herb $TAG $r"
  ID=$( { as "$DM"; echo "select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', '$NAME', 'kind_id', 'herbs_plants', 'campaign_id', '$CAMP')) ->> 'id';"; } | docker exec -i "$DB" psql -U postgres -qAt | tail -1)
  # odd rounds (20261112000100): the herb was in an inventory before (history only), so the delete also stamps its history
  if [ $((r % 2)) = 1 ]; then
    IIX=$( { as "$PL"; echo "select public.add_inventory_item('$INV', '$ID', 1, null, null, '{}');"; } | docker exec -i "$DB" psql -U postgres -qAt | tail -1)
    q "delete from public.inventory_items where id = '$IIX'" >/dev/null
  fi
  out=$( ( { as "$DM"; echo "select public.delete_custom_item('$ID', '$NAME');"; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1 | grep ERROR | sed 's/^/[del] /' ) &
         ( { as "$PL"; echo "select public.add_inventory_item('$INV', '$ID', 1, null, null, '{}');"; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1 | grep ERROR | sed 's/^/[add] /' ) &
         wait )
  item=$(q "select count(*) from public.items where id = '$ID'")
  rows=$(q "select count(*) from public.inventory_items where item_id = '$ID'")
  if [ "$item" = "0" ] && [ "$rows" = "0" ] && [ $((r % 2)) = 1 ]; then
    [ "$(q "select count(*) from public.inventory_events where item_id is null and metadata -> 'deleted_item' ->> 'id' = '$ID' and metadata -> 'deleted_item' ->> 'name' = '$NAME'")" -ge 2 ] \
      && stamped=$((stamped + 1)) || unstamped=$((unstamped + 1))
  fi
  if [ "$item" = "0" ] && [ "$rows" = "0" ]; then won_del=$((won_del + 1));
  elif [ "$item" = "1" ] && [ "$rows" = "1" ]; then won_add=$((won_add + 1));
  elif [ "$item" = "1" ] && [ "$rows" = "0" ]; then neither=$((neither + 1));
  else both=$((both + 1)); fi
  if echo "$out" | grep "^\[del\]" | grep -qvE "in use|Archive it instead"; then raw=$((raw + 1)); errs="$errs | $out"; fi
done
# the same delete twice at once
NAME="IDC Twice $TAG"
ID=$( { as "$DM"; echo "select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', '$NAME', 'kind_id', 'herbs_plants', 'campaign_id', '$CAMP')) ->> 'id';"; } | docker exec -i "$DB" psql -U postgres -qAt | tail -1)
twice=$( for i in 1 2; do ( { as "$DM"; echo "select public.delete_custom_item('$ID', '$NAME');"; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1 | grep -c ERROR ) & done; wait )
after=$(deadlocks)
fail=0; pass=0
ok() { if [ "$2" = "1" ]; then echo "PASSED  $1"; pass=$((pass + 1)); else echo "FAILED  $1   <-- $3"; fail=$((fail + 1)); fi; }
ok "rounds: delete won $won_del, add won $won_add (each round exactly one winner)" "$([ $((won_del + won_add)) = "$N" ] && echo 1)" "both=$both neither=$neither"
ok "never a deleted item still referenced by an inventory row" "$([ "$both" = "0" ] && echo 1)" "$both"
ok "the delete never shows a raw error (only the friendly 'in use, archive it')" "$([ "$raw" = "0" ] && echo 1)" "$errs"
ok "an item deleted with history keeps it (events unlinked, name stamped): $stamped stamped" "$([ "$unstamped" = "0" ] && echo 1)" "$unstamped without the stamp"
ok "the same delete twice in parallel: deleted once, the other a friendly not-found" "$([ "$(q "select count(*) from public.items where id = '$ID'")" = "0" ] && [ "$(echo "$twice" | tr -d '\n ')" != "00" ] && echo 1)" "$twice"
ok "no deadlock ($before -> $after)" "$([ "$after" = "$before" ] && echo 1)" "$before -> $after"
q "delete from public.characters where campaign_id = '$CAMP'; delete from public.items where campaign_id = '$CAMP';
   delete from public.campaigns where id = '$CAMP'; delete from auth.users where email like 'idc-%-$TAG@example.test';" >/dev/null
left=$(q "select count(*) from auth.users where email like 'idc-%@example.test'")
ok "cleanup: no synthetic rows left" "$([ "$left" = "0" ] && echo 1)" "$left"
echo "$pass passed, $fail failed"
exit $fail
