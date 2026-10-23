#!/usr/bin/env bash
# Concurrency checks for the Wild Shape engine (20261017001300): two sessions at the same time. Session 1 holds the character
# lock for 3 seconds; session 2 must wait for it and then see the result of session 1.
#   1. the last Wild Shape use: two transformations at once -> one form, one use spent
#   2. lethal damage twice at once -> the form ends once, the excess is applied once
#   3. manual revert and lethal damage at once -> one ending only
#   4. Combat Wild Shape healing and damage at once -> both applied in order, one slot spent
# Needs the seeds. Usage: bash supabase/tests/wild_shape_concurrency_test.sh <db container>
set -uo pipefail
NAME=${1:-tavern-ledger-pgtest}
px() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -At -q -v ON_ERROR_STOP=1 "$@"; }
U=a9999999-9999-9999-9999-9999999999c1
C=aaaaaaaa-0000-0000-0000-0000000000c1
RC=0
px <<SQL >/dev/null
insert into auth.users (id, email) values ('$U', 'wildshape-racer@test') on conflict do nothing;
insert into public.characters (id, owner_id, name, wisdom, hp_max, hp_current) values ('$C', '$U', 'Wild Shape Racer', 16, 40, 40) on conflict do nothing;
begin;
select set_config('request.jwt.claim.sub', '$U', true);
set local role authenticated;
select public.set_character_class('$C', 'druid-phb', 6, 'druid-moon-phb');
commit;
SQL
KEY="f:$(px -c "select id from public.character_classes where character_id = '$C'"):druid-wild-shape-phb-uses"
as_user() { printf "begin;\nselect set_config('request.jwt.claim.sub', '%s', true);\nset local role authenticated;\n%s\nselect pg_sleep(%s);\ncommit;\n" "$U" "$1" "$2"; }
pair() {   # $1 = statement of session 1 (holds the lock 3 s), $2 = statement of session 2
  O1=$(mktemp); E1=$(mktemp); O2=$(mktemp); E2=$(mktemp)
  as_user "$1" 3 | px >"$O1" 2>"$E1" & P1=$!
  sleep 1
  as_user "$2" 0 | px >"$O2" 2>"$E2"; S2=$?
  wait $P1; S1=$?
  ERR2=$(tr -d '\n' <"$E2" | tail -c 120)
  rm -f "$O1" "$E1" "$O2" "$E2"
}
reset() { px >/dev/null <<SQL
begin;
select set_config('tavern.resource_engine', 'on', true);   -- the resource trigger allows engine writes only
delete from public.character_transformations where character_id = '$C';
delete from public.character_transformation_events where character_id = '$C';
update public.characters set hp_current = 40, hp_temp = 0 where id = '$C';
update public.character_resources set expended = $1 where character_id = '$C' and feature_resource_id = 'druid-wild-shape-phb-uses';
update public.character_spell_slot_state set expended = 0 where character_id = '$C';
commit;
SQL
}
check() { if eval "$2"; then echo "PASSED  $1"; else echo "FAILED  $1 ($3)"; RC=1; fi; }

# 1. one use left, two transformations (the resource row exists after the first spend)
reset 0
px -c "begin; select set_config('request.jwt.claim.sub', '$U', true); set local role authenticated; select public.expend_character_resource('$C', '$KEY') is not null; commit;" >/dev/null
pair "select public.start_transformation('$C', 'brown-bear') is not null;" "select public.start_transformation('$C', 'wolf') is not null;"
N=$(px -c "select count(*) from public.character_transformations where character_id = '$C'")
USED=$(px -c "select expended from public.character_resources where character_id = '$C' and feature_resource_id = 'druid-wild-shape-phb-uses'")
check "the final Wild Shape use is spent once: one form (brown bear), the second request waited and was refused" \
  '[ "$S1" = 0 ] && [ "$S2" != 0 ] && [ "$N" = 1 ] && [ "$USED" = 2 ]' "s1=$S1 s2=$S2 forms=$N used=$USED err=$ERR2"

# 2. lethal damage twice at once (bear 34 HP): one ending, one carry-over
reset 0
px -c "begin; select set_config('request.jwt.claim.sub', '$U', true); set local role authenticated; select public.start_transformation('$C', 'brown-bear') is not null; commit;" >/dev/null
pair "select public.damage_active_transformation('$C', 40) -> 'result' ->> 'carryover';" "select public.damage_active_transformation('$C', 40) -> 'result' ->> 'carryover';"
HP=$(px -c "select hp_current from public.characters where id = '$C'")
EX=$(px -c "select count(*) from public.character_transformation_events where character_id = '$C' and event_type = 'excess_damage'")
check "concurrent lethal damage ends the form once and carries 6 over once (40 -> 34); the second is refused" \
  '[ "$S1" = 0 ] && [ "$S2" != 0 ] && [ "$HP" = 34 ] && [ "$EX" = 1 ]' "s1=$S1 s2=$S2 hp=$HP excess=$EX err=$ERR2"

# 3. revert and lethal damage at once
reset 0
px -c "begin; select set_config('request.jwt.claim.sub', '$U', true); set local role authenticated; select public.start_transformation('$C', 'brown-bear') is not null; commit;" >/dev/null
pair "select public.end_transformation('$C') is not null;" "select public.damage_active_transformation('$C', 40) is not null;"
HP=$(px -c "select hp_current from public.characters where id = '$C'")
ENDS=$(px -c "select count(*) from public.character_transformation_events where character_id = '$C' and event_type in ('reverted_manual', 'reverted_zero_hp')")
check "revert and lethal damage at once: one ending only, no carry-over after the revert (HP stays 40)" \
  '[ "$S1" = 0 ] && [ "$S2" != 0 ] && [ "$HP" = 40 ] && [ "$ENDS" = 1 ]' "s1=$S1 s2=$S2 hp=$HP ends=$ENDS err=$ERR2"

# 4. Combat Wild Shape healing (player roll 8 on 1d8) and 10 damage at once, starting at 20 / 34
reset 0
px -c "begin; select set_config('request.jwt.claim.sub', '$U', true); set local role authenticated; select public.start_transformation('$C', 'brown-bear') is not null; select public.set_transformation_hp('$C', 20, null, 'test') is not null; commit;" >/dev/null
pair "select public.combat_wild_shape_heal('$C', 1, 'standard', 8) -> 'result' ->> 'form_hp_after';" "select public.damage_active_transformation('$C', 10) -> 'result' ->> 'form_hp_after';"
FHP=$(px -c "select hp_current from public.character_transformations where character_id = '$C'")
SLOT=$(px -c "select coalesce(sum(expended), 0) from public.character_spell_slot_state where character_id = '$C' and pool = 'standard'")
check "healing and damage at once are applied in order (20 + 8 - 10 = 18) and spend exactly one slot" \
  '[ "$S1" = 0 ] && [ "$S2" = 0 ] && [ "$FHP" = 18 ] && [ "$SLOT" = 1 ]' "s1=$S1 s2=$S2 form_hp=$FHP slots=$SLOT err=$ERR2"

px -c "delete from public.characters where id = '$C'; delete from auth.users where id = '$U';" >/dev/null
exit $RC
