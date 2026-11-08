#!/usr/bin/env bash
# Lock order / deadlock follow-up (docs/COMBAT_BUILDER_FOLLOWUP.md "Deadlocks and spell slots"). LOCAL Supabase only; synthetic
# users (loc-*@example.test), campaign and characters, removed at the end.
# Parallel sessions on ONE Wizard who is in a running encounter, all at once:
#   two sessions spending and restoring a spell slot (timed), Combat Builder damage, sheet damage, coins, equip / unequip,
#   feat assign / remove (cache invalidation), cold cache reads of the same character; plus a Druid in Wild Shape damaged from
#   the sheet's form button and from the Combat Builder at the same time.
# Expected: no deadlock (pg_stat_database.deadlocks unchanged), no unexpected error, exact arithmetic (HP, form HP, coins,
# slots), and no slot spend slower than 1 s under this local workload (timeouts are NOT raised to hide anything).
# Usage: bash supabase/tests/lock_order_concurrency_test.sh [iterations]
set -uo pipefail
DB=supabase_db_tavern_ledger
N="${1:-30}"
q() { docker exec -i "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 -c "$1"; }
as() { echo "set role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\"}', false);"; }
TAG=$(date +%s)
DM=$(q "select gen_random_uuid()"); PL=$(q "select gen_random_uuid()"); CAMP=$(q "select gen_random_uuid()")
q "insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
     ('$DM', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'loc-dm-$TAG@example.test', now(), now()),
     ('$PL', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'loc-pl-$TAG@example.test', now(), now());
   insert into public.campaigns (id, name, created_by) values ('$CAMP', 'LOC concurrency $TAG', '$DM');
   insert into public.campaign_members (campaign_id, user_id, role) values ('$CAMP', '$DM', 'dm'), ('$CAMP', '$PL', 'player');" >/dev/null
WZ=$(q "insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current, intelligence) values ('$PL', 'LOC Wizard', '$CAMP', 9, 5000, 5000, 16) returning id" | head -1)
DR=$(q "insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current) values ('$PL', 'LOC Druid', '$CAMP', 5, 40, 40) returning id" | head -1)
{ as "$PL"; echo "select public.set_character_class('$WZ', 'wizard-phb', 9, null);"; echo "select public.set_character_class('$DR', 'druid-phb', 5, null);"; } | docker exec -i "$DB" psql -U postgres -qAt >/dev/null 2>&1
CC=$(q "select id from public.character_classes where character_id = '$DR' limit 1")
q "insert into public.character_transformations (character_id, character_class_id, resource_key, creature_id, cost, hp_max, hp_current, normal_hp_current, normal_hp_temp)
   values ('$DR', '$CC', 'wild-shape', 'wolf', 1, 4000, 4000, 40, 0)" >/dev/null
INV=$(q "select id from public.inventories where character_id = '$WZ' and kind = 'character' limit 1")
DAG=$( { as "$PL"; echo "select public.add_inventory_item('$INV', 'dagger', 1, null, null, '{}');"; } | docker exec -i "$DB" psql -U postgres -qAt | tail -1)
ENC=$( { as "$DM"; echo "select public.combat_create_encounter('$CAMP', 'LOC fight', '2024') -> 'encounter' ->> 'id';"; } | docker exec -i "$DB" psql -U postgres -qAt | tail -1)
{ as "$DM"
  echo "select public.combat_add_characters('$ENC', array['$WZ', '$DR']::uuid[]);"
  echo "select public.combat_set_initiative('$ENC', (select jsonb_agg(jsonb_build_object('id', id, 'initiative', 10)) from public.combat_participants where encounter_id = '$ENC'));"
  echo "select public.combat_start('$ENC', true);"
} | docker exec -i "$DB" psql -U postgres -qAt >/dev/null 2>&1
P_WZ=$(q "select id from public.combat_participants where encounter_id = '$ENC' and linked_character_id = '$WZ'")
P_DR=$(q "select id from public.combat_participants where encounter_id = '$ENC' and linked_character_id = '$DR'")

COINS0=$(q "select coalesce((select gp from public.characters where id = '$WZ'), 0)" 2>/dev/null || echo 0)
deadlocks() { q "select deadlocks from pg_stat_database where datname = current_database()"; }
loop() {   # $1 label, $2 user, $3 statement (run N times)
  { as "$2"; for i in $(seq 1 "$N"); do echo "$3"; done; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1 >/dev/null | sed "s/^/[$1] /"
}
timed() {  # like loop, but prints "[label] <ms>" per statement
  { as "$2"; echo '\timing on'; for i in $(seq 1 "$N"); do echo "$3"; done; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1 | grep -E "^Time:|ERROR" | sed -E "s/^Time: ([0-9.]+) ms.*/\1/; s/^/[$1] /"
}
before=$(deadlocks)
t0=$(date +%s%N)
out=$( timed slot-a "$PL" "select public.expend_standard_spell_slot('$WZ', 1, null); select public.restore_standard_spell_slot('$WZ', 1, null);" &
       timed slot-b "$PL" "select public.expend_standard_spell_slot('$WZ', 2, null); select public.restore_standard_spell_slot('$WZ', 2, null);" &
       loop combat-hp "$DM" "select public.combat_apply_hp('$P_WZ', 'damage', 1);" &
       loop sheet-hp "$PL" "select public.apply_character_hp('$WZ', 'damage', 1);" &
       loop coins "$PL" "select public.adjust_character_coins('$WZ', 'gain', '{\"gp\": 1}', null);" &
       loop equip "$PL" "select public.equip_item('$DAG', 'main_hand', true); select public.unequip_item('$DAG');" &
       loop feat "$PL" "select public.assign_character_feat('$WZ', 'alert-2014', '{}', 'direct', null, null, null); select public.remove_character_feat((select id from public.character_feats where character_id = '$WZ' and feat_version_id = 'alert-2014' limit 1), null);" &
       loop reads "$PL" "select public.get_character_reads('$WZ', array['get_character_class_features', 'get_character_derived_stats', 'get_character_spell_slots']);" &
       loop form-sheet "$PL" "select public.damage_active_transformation('$DR', 1, null);" &
       loop form-combat "$DM" "select public.combat_apply_hp('$P_DR', 'damage', 1);" &
       wait )
t1=$(date +%s%N)
after=$(deadlocks)

fail=0; pass=0
ok() { if [ "$2" = "1" ]; then echo "PASSED  $1"; pass=$((pass + 1)); else echo "FAILED  $1   <-- $3"; fail=$((fail + 1)); fi; }
ok "fixture: encounter running, Wizard 9 with slots, Druid in a form" "$([ "$(q "select status from public.combat_encounters where id = '$ENC'")" = "active" ] && [ -n "$DAG" ] && echo 1)" "$DAG"
ok "no deadlock ($before -> $after)" "$([ "$after" = "$before" ] && echo 1)" "$before -> $after"
# expected friendly refusals: none expected in this workload except an empty slot level between two spends (friendly 22023)
unexpected=$(echo "$out" | grep -E "ERROR" | grep -vE "no .*slot|No .*slot|slot.*left|already|is not|Feat not found|feat_absent|nothing to restore|all .* slots" || true)
ok "no unexpected error" "$([ -z "$unexpected" ] && echo 1)" "$(echo "$unexpected" | sort | uniq -c | head -5)"
times=$(echo "$out" | grep -E "^\[slot-[ab]\] [0-9.]+$" | awk '{print $2}')
cnt=$(echo "$times" | grep -c . || true)
max=$(echo "$times" | sort -n | tail -1)
avg=$(echo "$times" | awk '{s+=$1} END {if (NR) printf "%.1f", s/NR}')
ok "slot spend/restore timings recorded ($cnt statements)" "$([ "$cnt" -ge $((N * 2)) ] && echo 1)" "$cnt"
ok "slowest slot spend/restore under concurrency < 1000 ms (max ${max} ms, avg ${avg} ms)" "$(awk -v m="${max:-99999}" 'BEGIN {print (m < 1000) ? 1 : 0}')" "$max"
ok "Wizard HP: $((2 * N)) damages from the combat and the sheet path, each once" "$([ "$(q "select hp_current from public.characters where id = '$WZ'")" = "$((5000 - 2 * N))" ] && echo 1)" "$(q "select hp_current from public.characters where id = '$WZ'")"
COINS1=$(q "select coalesce((select gp from public.characters where id = '$WZ'), 0)" 2>/dev/null || echo 0)
ok "coins: +$N gp exactly" "$([ "$((COINS1 - COINS0))" = "$N" ] && echo 1)" "$COINS0 -> $COINS1"
ok "slots: every spend restored (no slot lost or doubled)" "$([ "$(q "select count(*) from public.character_spell_slot_state s where s.character_id = '$WZ' and s.expended <> 0" 2>/dev/null || echo 0)" = "0" ] && echo 1)" "$(q "select string_agg(slot_level || ':' || expended, ',') from public.character_spell_slot_state where character_id = '$WZ'" 2>/dev/null)"
ok "dagger unequipped at the end, one inventory entry" "$([ "$(q "select count(*) from public.inventory_items where inventory_id = '$INV' and item_id = 'dagger'")" = "1" ] && echo 1)"
ok "feat: none left over" "$([ "$(q "select count(*) from public.character_feats where character_id = '$WZ'")" = "0" ] && echo 1)" "$(q "select count(*) from public.character_feats where character_id = '$WZ'")"
ok "Wild Shape form HP: $((2 * N)) damages from the sheet and the Combat Builder" "$([ "$(q "select hp_current from public.character_transformations where character_id = '$DR'")" = "$((4000 - 2 * N))" ] && echo 1)" "$(q "select hp_current from public.character_transformations where character_id = '$DR'")"
ok "normal HP of the Druid untouched" "$([ "$(q "select hp_current from public.characters where id = '$DR'")" = "40" ] && echo 1)"
ms=$(( (t1 - t0) / 1000000 ))
echo "info: $((12 * N)) concurrent statements in ${ms} ms (10 sessions); slot max ${max} ms avg ${avg} ms"
q "set tavern.managed_modifier = '1'; delete from public.combat_encounters where campaign_id = '$CAMP';
   delete from public.characters where campaign_id = '$CAMP';
   delete from public.campaigns where id = '$CAMP';
   delete from auth.users where email like 'loc-%-$TAG@example.test';" >/dev/null
left=$(q "select count(*) from auth.users where email like 'loc-%@example.test'")
ok "cleanup: no synthetic rows left" "$([ "$left" = "0" ] && echo 1)" "$left"
echo "$pass passed, $fail failed"
exit $fail
