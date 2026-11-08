#!/usr/bin/env bash
# Combat Builder concurrency and deadlock regression (docs/COMBAT_REALTIME.md "Concurrency"). LOCAL Supabase only; synthetic
# users (cbc-*@example.test), campaign and characters, removed at the end.
# Parallel sessions on ONE encounter: the DM's combat HP RPC and the player's sheet RPC on the same character, the same on a
# character in Wild Shape, monster damage, Next / Previous turn and effect add / end, all at once. Expected:
#   * no deadlock (pg_stat_database.deadlocks unchanged), no unexpected error (turn conflicts are the friendly TLCMB);
#   * exact arithmetic: every accepted damage is applied once (character, form and monster HP);
#   * one request id sent 20 times in parallel is applied once.
# Usage: bash supabase/tests/combat_concurrency_test.sh [iterations]
set -uo pipefail
DB=supabase_db_tavern_ledger
N="${1:-40}"
q() { docker exec -i "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 -c "$1"; }
as() { echo "set role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\"}', false);"; }
TAG=$(date +%s)
DM=$(q "select gen_random_uuid()"); PL=$(q "select gen_random_uuid()"); CAMP=$(q "select gen_random_uuid()")
q "insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
     ('$DM', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cbc-dm-$TAG@example.test', now(), now()),
     ('$PL', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cbc-pl-$TAG@example.test', now(), now());
   insert into public.campaigns (id, name, created_by) values ('$CAMP', 'CBC concurrency $TAG', '$DM');
   insert into public.campaign_members (campaign_id, user_id, role) values ('$CAMP', '$DM', 'dm'), ('$CAMP', '$PL', 'player');" >/dev/null
CH=$(q "insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current) values ('$PL', 'CBC Hero', '$CAMP', 5, 2000, 2000) returning id" | head -1)
WS=$(q "insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current) values ('$PL', 'CBC Druid', '$CAMP', 5, 40, 40) returning id" | head -1)
CC=$(q "insert into public.character_classes (character_id, class_id, class_version_id, level, is_primary) values ('$WS', 'druid', 'druid-phb', 5, true) returning id" | head -1)
q "insert into public.character_transformations (character_id, character_class_id, resource_key, creature_id, cost, hp_max, hp_current, normal_hp_current, normal_hp_temp)
   values ('$WS', '$CC', 'wild-shape', 'wolf', 1, 2000, 2000, 40, 0)" >/dev/null
setup=$( { as "$DM"
  echo "select public.combat_create_encounter('$CAMP', 'CBC fight', '2024') -> 'encounter' ->> 'id';"; } | docker exec -i "$DB" psql -U postgres -qAt | tail -1)
ENC="$setup"
{ as "$DM"
  echo "select public.combat_add_characters('$ENC', array['$CH', '$WS']::uuid[]);"
  echo "select public.combat_add_custom('$ENC', '{\"name\": \"CBC Golem\", \"hp\": 5000, \"ac\": 15}');"
  echo "select public.combat_add_monsters('$ENC', 'srd2024', 'srd52-goblin-warrior', '{\"quantity\": 3}');"
  echo "select public.combat_roll_initiative('$ENC', null, '{\"include_characters\": false}');"
  echo "select public.combat_set_initiative('$ENC', (select jsonb_agg(jsonb_build_object('id', x.id, 'initiative', x.v)) from (select id, 30 - (row_number() over (order by id))::int as v from public.combat_participants where encounter_id = '$ENC' and kind = 'character') x));"
  echo "select public.combat_start('$ENC', true);"
} | docker exec -i "$DB" psql -U postgres -qAt >/dev/null 2>&1
P_CH=$(q "select id from public.combat_participants where encounter_id = '$ENC' and linked_character_id = '$CH'")
P_WS=$(q "select id from public.combat_participants where encounter_id = '$ENC' and linked_character_id = '$WS'")
P_GO=$(q "select id from public.combat_participants where encounter_id = '$ENC' and display_name = 'CBC Golem'")
STATUS=$(q "select status from public.combat_encounters where id = '$ENC'")
deadlocks() { q "select deadlocks from pg_stat_database where datname = current_database()"; }
loop() {   # $1 label, $2 user, $3 statement (run N times)
  { as "$2"; for i in $(seq 1 "$N"); do echo "$3"; done; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1 >/dev/null | sed "s/^/[$1] /"
}
before=$(deadlocks)
t0=$(date +%s%N)
out=$( loop combat-hp "$DM" "select public.combat_apply_hp('$P_CH', 'damage', 1);" &
       loop sheet-hp "$PL" "select public.apply_character_hp('$CH', 'damage', 1);" &
       loop form-combat "$DM" "select public.combat_apply_hp('$P_WS', 'damage', 1);" &
       loop form-sheet "$PL" "select public.apply_character_hp('$WS', 'damage', 1);" &
       loop monster "$DM" "select public.combat_apply_hp('$P_GO', 'damage', 1);" &
       loop next "$DM" "select public.combat_next_turn('$ENC', null);" &
       loop prev "$DM" "select public.combat_previous_turn('$ENC', null, true);" &
       loop effect "$DM" "select public.combat_end_effect((public.combat_add_effect('$ENC', jsonb_build_object('effect_type', 'condition', 'condition_key', 'poisoned', 'target', '$P_CH', 'duration_type', 'rounds', 'duration_rounds', 1)) -> 'effects' -> 0 ->> 'id')::uuid);" &
       wait )
t1=$(date +%s%N)
after=$(deadlocks)
# the same request 20 times at once (a double click, a retry storm): applied once
REQ=$(q "select gen_random_uuid()")
GO_BEFORE=$(q "select hp_current from public.combat_participants where id = '$P_GO'")
dup=$( for i in $(seq 1 20); do ( { as "$DM"; echo "select public.combat_apply_hp('$P_GO', 'damage', 5, null, '$REQ');"; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1 >/dev/null ) & done; wait )
GO_AFTER=$(q "select hp_current from public.combat_participants where id = '$P_GO'")

fail=0; pass=0
ok() { if [ "$2" = "1" ]; then echo "PASSED  $1"; pass=$((pass + 1)); else echo "FAILED  $1   <-- $3"; fail=$((fail + 1)); fi; }
ok "fixture: the encounter is running" "$([ "$STATUS" = "active" ] && echo 1)" "$STATUS"
ok "no deadlock ($before -> $after)" "$([ "$after" = "$before" ] && echo 1)" "$before -> $after"
unexpected=$(echo "$out" | grep -E "ERROR" | grep -vE "TLCMB|first turn of the combat|already undone" || true)
ok "no unexpected error (turn conflicts are friendly)" "$([ -z "$unexpected" ] && echo 1)" "$(echo "$unexpected" | sort | uniq -c | head -5)"
ok "character HP: $((2 * N)) damages from two paths applied exactly once each" "$([ "$(q "select hp_current from public.characters where id = '$CH'")" = "$((2000 - 2 * N))" ] && echo 1)" "$(q "select hp_current from public.characters where id = '$CH'")"
ok "Wild Shape form HP: $((2 * N)) damages from two paths" "$([ "$(q "select hp_current from public.character_transformations where character_id = '$WS'")" = "$((2000 - 2 * N))" ] && echo 1)" "$(q "select hp_current from public.character_transformations where character_id = '$WS'")"
ok "normal HP of the Druid untouched while in form" "$([ "$(q "select hp_current from public.characters where id = '$WS'")" = "40" ] && echo 1)"
ok "monster HP: $N damages" "$([ "$GO_BEFORE" = "$((5000 - N))" ] && echo 1)" "$GO_BEFORE"
ok "one request id x20 in parallel -> applied once" "$([ "$GO_AFTER" = "$((GO_BEFORE - 5))" ] && echo 1)" "$GO_BEFORE -> $GO_AFTER ($dup)"
ok "history: one event per accepted HP change" "$([ "$(q "select count(*) from public.combat_events where encounter_id = '$ENC' and kind = 'damage'")" = "$((3 * N + 1))" ] && echo 1)" "$(q "select count(*) from public.combat_events where encounter_id = '$ENC' and kind = 'damage'")"
ok "no effect left behind by the add/end loop" "$([ "$(q "select count(*) from public.combat_effects where encounter_id = '$ENC' and active")" = "0" ] && echo 1)" "$(q "select count(*) from public.combat_effects where encounter_id = '$ENC' and active")"
ms=$(( (t1 - t0) / 1000000 ))
echo "info: $((8 * N)) concurrent operations in ${ms} ms (8 sessions)"
# cleanup (synthetic only)
q "delete from public.combat_encounters where campaign_id = '$CAMP';
   delete from public.characters where campaign_id = '$CAMP';
   delete from public.campaigns where id = '$CAMP';
   delete from auth.users where email like 'cbc-%-$TAG@example.test';" >/dev/null
left=$(q "select count(*) from auth.users where email like 'cbc-%@example.test'")
ok "cleanup: no synthetic rows left" "$([ "$left" = "0" ] && echo 1)" "$left"
echo "$pass passed, $fail failed"
exit $fail
