#!/usr/bin/env bash
# Concurrency check of the item spell-grant sync (20261114000500, review v33 M1; from the reviewer's probe). Items WITH granted
# spells, 6 sessions at once: the DM transfers rows A->B and B->A (opposite directions), player 1 attunes / unattunes an amulet,
# the DM unidentifies / identifies it, dm_reveal_item on both characters, player 2 equips / unequips a circlet.
# Gates: pg_stat_database.deadlocks unchanged, no ERROR in any session (no 40P01, no FK error), and the end state is consistent
# (one item source per held granting row, one active counter per held 'per rest' row, no orphan source).
# Synthetic users igc-*@example.test and their campaign, characters and items; removed at the end.
# Usage: bash supabase/tests/item_grants_concurrency_test.sh [rows per character, default 12] [runs, default 1]
set -uo pipefail
DB=supabase_db_tavern_ledger; N=${1:-12}; RUNS=${2:-1}
q() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 -c "$1"; }
as() { echo "set role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\"}', false);"; }
OUT=$(mktemp -d); RC=0
check() { if eval "$2"; then echo "PASSED  $1"; else echo "FAILED  $1 ($3)"; RC=1; fi; }

for run in $(seq 1 "$RUNS"); do
DM=$(q "select gen_random_uuid()"); P1=$(q "select gen_random_uuid()"); P2=$(q "select gen_random_uuid()"); CAMP=$(q "select gen_random_uuid()")
q "insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
 ('$DM','00000000-0000-0000-0000-000000000000','authenticated','authenticated','igc-dm-$DM@example.test',now(),now()),
 ('$P1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','igc-p1-$P1@example.test',now(),now()),
 ('$P2','00000000-0000-0000-0000-000000000000','authenticated','authenticated','igc-p2-$P2@example.test',now(),now());
 insert into public.campaigns (id,name,created_by) values ('$CAMP','IGC grants','$DM');
 insert into public.campaign_members (campaign_id,user_id,role) values ('$CAMP','$DM','dm'),('$CAMP','$P1','player'),('$CAMP','$P2','player');" >/dev/null
A=$(q "insert into public.characters (owner_id,name,campaign_id,level,hp_max,hp_current,wisdom) values ('$P1','IGC A','$CAMP',5,30,30,14) returning id"|head -1)
B=$(q "insert into public.characters (owner_id,name,campaign_id,level,hp_max,hp_current,wisdom) values ('$P2','IGC B','$CAMP',5,30,30,14) returning id"|head -1)
IA=$(q "select id from public.inventories where character_id='$A' and kind='character'"); IB=$(q "select id from public.inventories where character_id='$B' and kind='character'")
pub() {
  { as "$DM"
    echo "select (public.create_dm_content('item','$CAMP','$1'::jsonb)->>'id') as id \\gset"
    echo "select public.publish_dm_content(:'id');"
    echo "select v.catalog_ref from public.dm_content c join public.dm_content_versions v on v.id=c.published_version_id where c.id=:'id';"
  } | docker exec -i "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 | tail -1
}
G1=$(pub '{"name":"IGC Stone","definition":{"item":{"kind_id":"magic_item","category_id":"wondrous-item","is_magic":true,"rarity_id":"common","effects":[{"type":"ac_bonus","value":1,"activation":"owned"}],"spells":[{"spell":"light-phb","casting":"per_rest","uses":2,"recharge":"long_rest","activation":"owned"}]}}}')
G2=$(pub '{"name":"IGC Amulet","definition":{"item":{"kind_id":"magic_item","category_id":"wondrous-item","is_magic":true,"rarity_id":"uncommon","requires_attunement":true,"spells":[{"spell":"speak-with-dead-phb","casting":"per_rest","uses":1,"recharge":"long_rest","activation":"attuned"}]}}}')
G3=$(pub '{"name":"IGC Circlet","definition":{"item":{"kind_id":"magic_item","category_id":"wondrous-item","is_magic":true,"rarity_id":"common","spells":[{"spell":"shield-phb","casting":"spell_slots","activation":"equipped"}]}}}')
add() { { as "$DM"; echo "select public.add_inventory_item('$1','$2',1);"; } | docker exec -i "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 | tail -1; }
for i in $(seq 1 "$N"); do add "$IA" "$G1" >/dev/null; add "$IB" "$G1" >/dev/null; done
AMU=$(add "$IA" "$G2"); CIR=$(add "$IB" "$G3")
RA=$(q "select string_agg(ii.id::text,' ') from public.inventory_items ii where ii.inventory_id='$IA' and ii.item_id='$G1'")
RB=$(q "select string_agg(ii.id::text,' ') from public.inventory_items ii where ii.inventory_id='$IB' and ii.item_id='$G1'")
SA0=$(q "select count(*) from public.character_spellcasting_sources where character_id='$A' and item_grant_key is not null")
sleep 1; DL0=$(q "select deadlocks from pg_stat_database where datname=current_database()")
S1() { { as "$DM"; for r in $RA; do echo "select public.transfer_inventory_item('$r','$IB',1);"; done; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1; }
S2() { { as "$DM"; for r in $RB; do echo "select public.transfer_inventory_item('$r','$IA',1);"; done; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1; }
S3() { { as "$P1"; for i in $(seq 1 "$N"); do echo "select public.attune_item('$AMU');"; echo "select public.unattune_item('$AMU');"; done; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1; }
S4() { { as "$DM"; for i in $(seq 1 "$N"); do echo "select public.set_item_knowledge('$AMU','unidentified');"; echo "select public.set_item_knowledge('$AMU','identified');"; done; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1; }
S5() { { as "$DM"; for i in $(seq 1 "$N"); do echo "select public.dm_reveal_item('$G1', array['$A','$B']::uuid[]);"; done; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1; }
S6() { { as "$P2"; for i in $(seq 1 "$N"); do echo "select public.equip_item('$CIR','head',false);"; echo "select public.unequip_item('$CIR');"; done; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1; }
T0=$(date +%s%N)
S1 > "$OUT/1" & S2 > "$OUT/2" & S3 > "$OUT/3" & S4 > "$OUT/4" & S5 > "$OUT/5" & S6 > "$OUT/6" & wait
T1=$(date +%s%N)
sleep 1; DL1=$(q "select deadlocks from pg_stat_database where datname=current_database()")
ERRS=$(cat "$OUT"/1 "$OUT"/2 "$OUT"/3 "$OUT"/4 "$OUT"/5 "$OUT"/6 | grep -c ERROR)
STATE=$(q "select (select count(*) from public.inventory_items where inventory_id='$IA' and item_id='$G1')
  = (select count(*) from public.character_spellcasting_sources s where s.character_id='$A' and s.item_grant_key like 'ii:%')
  and (select count(*) from public.inventory_items where inventory_id='$IB' and item_id='$G1')
  = (select count(*) from public.character_spellcasting_sources s where s.character_id='$B' and s.item_grant_key like 'ii:%')
  and (select count(*) from public.inventory_items where inventory_id='$IA' and item_id='$G1')
  = (select count(*) from public.character_resources where character_id='$A' and source_type='item' and active)
  and not exists (select 1 from public.character_spellcasting_sources s where s.item_grant_key like 'ii:%' and s.character_id in ('$A','$B')
       and not exists (select 1 from public.inventory_items ii join public.inventories i on i.id=ii.inventory_id
                       where ii.id=substr(s.item_grant_key,4)::uuid and i.character_id=s.character_id))
  and not exists (select 1 from public.item_grant_sync_queue)")
check "run $run: $((N*2*5+N)) statements in 6 sessions ($(( (T1-T0)/1000000 )) ms): deadlocks unchanged ($DL0 -> $DL1), no errors ($ERRS), consistent grants ($STATE), set-up sources $SA0 = $N" \
  '[ "$DL0" = "$DL1" ] && [ "$ERRS" = 0 ] && [ "$STATE" = t ] && [ "$SA0" = "$N" ]' "$(cat "$OUT"/* | grep ERROR | sort | uniq -c | head -4)"
# cleanup (synthetic objects only)
q "delete from public.characters where id in ('$A','$B');
   delete from public.dm_content where campaign_id='$CAMP';
   delete from public.item_spell_grants where item_id in ('$G1','$G2','$G3');
   delete from public.item_effects where item_id in ('$G1','$G2','$G3');" >/dev/null 2>&1 || echo "note: character / content cleanup incomplete"
q "delete from public.items where id in ('$G1','$G2','$G3'); delete from public.campaigns where id='$CAMP';" >/dev/null 2>&1 || echo "note: items / campaign kept (custom content rules)"
q "delete from auth.users where id in ('$DM','$P1','$P2')" >/dev/null 2>&1 || echo "note: users kept"
done
rm -rf "$OUT"
[ "$RC" = 0 ] && echo "PASSED  item grant concurrency ($RUNS run(s))" || echo "FAILED  item grant concurrency"
exit "$RC"
