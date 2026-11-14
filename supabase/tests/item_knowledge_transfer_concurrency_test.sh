#!/usr/bin/env bash
# Targeted two-session deadlock check (review v34 m3): the DM moves one copy of an item between two characters (A -> B -> A ...)
# while the DM toggles the knowledge (unidentified / identified) of a SIBLING copy of the same item held by A. Before
# 20261114000700 set_item_knowledge locked the sibling rows only inside _identify_sync_rows, after its own writes had already
# taken A's cache counter (tl_cache.character_rev), while the transfer held the moving row and waited for the same counter.
# The item is a DM content weapon with a limited Weapon action (so the deferred grant / counter sync runs as well).
# Gates per run: pg_stat_database.deadlocks unchanged, no ERROR in either session, the moving copy ends where it started.
# Synthetic users ikt-*@example.test with their campaign, characters and item; removed at the end (local database only).
# Mode examine (review v35 F2): the sibling copy is instead identified by its player's examine attempt (auto success, after the
# DM resets it to unidentified); mode resolve: the player examines (no auto result) and the DM answers the attempt with a success.
# Both rewrite the sibling rows through _identify_apply -> _identify_sync_rows; since 20261114000800 they take the 4242 lock first.
# Usage: bash supabase/tests/item_knowledge_transfer_concurrency_test.sh [round trips per run, default 20] [runs, default 1]
#        [mode: knowledge (default) | examine | resolve | craft | craft_dm]
# Modes craft / craft_dm (crafting v2, 20261114000900): the sibling copy is reset to unidentified by the DM, then the player crafts
# a recipe whose RESULT is the same item (one herb used up per craft): _craft_produce learns the item for the character
# (_identify_apply -> _identify_sync_rows on every copy, including the moving one). craft = the auto path (no DC, no approval),
# craft_dm = a pending attempt approved by the DM. Since 20261114000900 both take the 4242 lock of every involved item first.
set -uo pipefail
DB=supabase_db_tavern_ledger; N=${1:-20}; RUNS=${2:-1}; MODE=${3:-knowledge}
case "$MODE" in knowledge) HID='';; examine) HID=',"identify_dc":5,"identify_checks":["arcana"],"identify_auto":true,"identify_retry":"unlimited"';;
  resolve) HID=',"identify_dc":5,"identify_checks":["arcana"],"identify_auto":false,"identify_retry":"unlimited"';;
  craft|craft_dm) HID='';;
  *) echo "unknown mode $MODE"; exit 2;; esac
q() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 -c "$1"; }
as() { echo "set role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\"}', false);"; }
OUT=$(mktemp -d); RC=0; FAILS=0
for run in $(seq 1 "$RUNS"); do
DM=$(q "select gen_random_uuid()"); P1=$(q "select gen_random_uuid()"); CAMP=$(q "select gen_random_uuid()")
q "insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
 ('$DM','00000000-0000-0000-0000-000000000000','authenticated','authenticated','ikt-dm-$DM@example.test',now(),now()),
 ('$P1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','ikt-p1-$P1@example.test',now(),now());
 insert into public.campaigns (id,name,created_by) values ('$CAMP','IKT knowledge','$DM');
 insert into public.campaign_members (campaign_id,user_id,role) values ('$CAMP','$DM','dm'),('$CAMP','$P1','player');" >/dev/null
A=$(q "insert into public.characters (owner_id,name,campaign_id,level,hp_max,hp_current,strength) values ('$P1','IKT A','$CAMP',5,30,30,16) returning id"|head -1)
B=$(q "insert into public.characters (owner_id,name,campaign_id,level,hp_max,hp_current,strength) values ('$P1','IKT B','$CAMP',5,30,30,16) returning id"|head -1)
IA=$(q "select id from public.inventories where character_id='$A' and kind='character'"); IB=$(q "select id from public.inventories where character_id='$B' and kind='character'")
W=$( { as "$DM"
  echo "select (public.create_dm_content('item','$CAMP','{\"name\":\"IKT Blade\",\"definition\":{\"item\":{\"kind_id\":\"weapon\",\"category_id\":\"martial-melee\",\"is_magic\":true,\"rarity_id\":\"rare\",\"weapon_actions\":[{\"name\":\"Lunge\",\"cost\":\"action\",\"roll\":\"attack\",\"damage\":\"1d6\",\"damage_type\":\"piercing\",\"uses\":1,\"recharge\":\"short_rest\"}]},\"stats\":{\"weapon\":{\"weapon_group\":\"martial\",\"damage_dice\":\"1d8\",\"damage_type_id\":\"slashing\"}},\"hidden\":{\"unidentified_name\":\"Old blade\"$HID}}}'::jsonb)->>'id') as id \gset"
  echo "select public.publish_dm_content(:'id');"
  echo "select v.catalog_ref from public.dm_content c join public.dm_content_versions v on v.id=c.published_version_id where c.id=:'id';"
} | docker exec -i "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 | tail -1)
add() { { as "$DM"; echo "select public.add_inventory_item('$IA','$W',1);"; } | docker exec -i "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 | tail -1; }
K1=$(add); K2=$(add)    # K1: the copy whose knowledge is toggled; K2: the sibling copy that moves
{ as "$DM"; echo "select public.set_item_knowledge('$K1','identified');"; echo "select public.set_item_knowledge('$K2','identified');"; } | docker exec -i "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 >/dev/null
if [ "$MODE" = craft ] || [ "$MODE" = craft_dm ]; then
  APPROVAL=$([ "$MODE" = craft ] && echo false || echo true)
  H=$( { as "$DM"; echo "select public.set_campaign_governance('$CAMP', '{\"overrides\": {\"inventory.craft\": \"player_managed\"}}');"
    echo "select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name','IKT Herb','kind_id','herbs_plants','category_id','plant-flower','campaign_id','$CAMP','stackable',true)) ->> 'id';"
  } | docker exec -i "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 | tail -1)
  HR=$( { as "$DM"; echo "select public.add_inventory_item('$IA','$H',$((N*2)));"; } | docker exec -i "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 | tail -1)
  R=$( { as "$DM"; echo "select public.dm_save_recipe('$CAMP', jsonb_build_object('name','IKT Forge','requires_dm_approval',$APPROVAL,'output_item_id','$W','ingredients',jsonb_build_array(jsonb_build_object('item_id','$H','quantity',1)))) ->> 'id' as rid \gset"
    echo "select public.dm_set_recipe_status(:'rid','published') ->> 'id';"; } | docker exec -i "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 | tail -1)
fi
sleep 1; DL0=$(q "select deadlocks from pg_stat_database where datname=current_database()")
S1() { { as "$DM"; for i in $(seq 1 "$N"); do echo "select public.transfer_inventory_item('$K2','$IB',1);"; echo "select public.transfer_inventory_item('$K2','$IA',1);"; done; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1; }
S2() { { for i in $(seq 1 "$N"); do as "$DM"; echo "select public.set_item_knowledge('$K1','unidentified');"
    case "$MODE" in
      knowledge) echo "select public.set_item_knowledge('$K1','identified');";;
      examine) as "$P1"; echo "select public.examine_inventory_item('$K1','arcana',20) ->> 'status';";;
      resolve) as "$P1"; echo "select public.examine_inventory_item('$K1','arcana',20) ->> 'attempt_id' as aid \gset"
               as "$DM"; echo "select public.resolve_identify_attempt(:'aid', true) ->> 'status';";;
      craft) as "$P1"; echo "select case when public.start_craft_attempt('$A','$R',jsonb_build_array(jsonb_build_object('seq',1,'inventory_item_id','$HR','quantity',1)),null,gen_random_uuid()) ->> 'status' = 'applied' then 'succeeded' end;";;
      craft_dm) as "$P1"; echo "select public.start_craft_attempt('$A','$R',jsonb_build_array(jsonb_build_object('seq',1,'inventory_item_id','$HR','quantity',1)),null,gen_random_uuid()) ->> 'attempt_id' as aid \gset"
               as "$DM"; echo "select case when public.dm_resolve_craft_attempt(:'aid','approve') ->> 'status' = 'applied' then 'succeeded' end;";;
    esac; done; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1; }
T0=$(date +%s%N); S1 > "$OUT/1" & S2 > "$OUT/2" & wait; T1=$(date +%s%N)
sleep 1; DL1=$(q "select deadlocks from pg_stat_database where datname=current_database()")
ERRS=$(cat "$OUT"/1 "$OUT"/2 | grep -c ERROR)
HOME_OK=$(q "select inventory_id = '$IA' from public.inventory_items where id = '$K2'")
OKS=$(grep -cx succeeded "$OUT/2"); [ "$MODE" = knowledge ] && OKS=$N
if [ "$DL0" = "$DL1" ] && [ "$ERRS" = 0 ] && [ "$HOME_OK" = t ] && [ "$OKS" = "$N" ]; then echo "PASSED  run $run ($MODE): $((N*4)) statements in 2 sessions ($(( (T1-T0)/1000000 )) ms), deadlocks $DL0 -> $DL1, errors 0"
else echo "FAILED  run $run ($MODE): deadlocks $DL0 -> $DL1, errors $ERRS, copy back home $HOME_OK, successes $OKS/$N   $(cat "$OUT"/* | grep ERROR | sort | uniq -c | head -3)"; RC=1; FAILS=$((FAILS+1)); fi
q "delete from public.item_identify_attempts where character_id in ('$A','$B');" >/dev/null 2>&1
q "delete from public.characters where id in ('$A','$B'); delete from public.crafting_recipes where campaign_id='$CAMP'; delete from public.dm_content where campaign_id='$CAMP';
   delete from public.item_weapon_blocks where item_id='$W'; delete from public.item_effects where item_id='$W';" >/dev/null 2>&1 || echo "note: character / content cleanup incomplete"
q "delete from public.items where id in ('$W','${H:-none}'); delete from public.campaigns where id='$CAMP';" >/dev/null 2>&1 || echo "note: item / campaign kept (custom content rules)"
q "delete from auth.users where id in ('$DM','$P1')" >/dev/null 2>&1 || echo "note: users kept"
done
rm -rf "$OUT"
[ "$RC" = 0 ] && echo "PASSED  sibling-copy $MODE vs transfer ($RUNS run(s))" || echo "FAILED  sibling-copy $MODE vs transfer ($FAILS of $RUNS run(s))"
exit "$RC"
