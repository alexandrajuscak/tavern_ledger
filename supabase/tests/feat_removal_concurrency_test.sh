#!/usr/bin/env bash
# Feat removal under concurrency (20261107000100; docs/FEAT_REMOVAL.md "Concurrency"). LOCAL Supabase only; synthetic users
# (frc-*@example.test), campaign and character, removed at the end.
#   1. the owner (two devices) and the campaign DM remove the SAME feat at once, 3 sessions x N rounds:
#      exactly one removal per round, the others get the friendly 'feat_absent' answer, one audit event per round;
#   2. removal while the owner changes the feat's choices / another session reads the sheet: no deadlock, no raw error;
#   3. no deadlock at all (pg_stat_database.deadlocks unchanged).
# Usage: bash supabase/tests/feat_removal_concurrency_test.sh [rounds]
set -uo pipefail
DB=${DB:-supabase_db_tavern_ledger}
N="${1:-15}"
q() { docker exec -i "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 -c "$1"; }
as() { echo "set role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\"}', false);"; }
sess() { { as "$1"; echo "$2"; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1 | grep -vE "^(CONTEXT|LINE|HINT|DETAIL|SQL statement|PL/pgSQL)" | tail -2; }
TAG=$(date +%s)
pass=0; fail=0
ok() { if [ -n "$2" ]; then echo "PASSED  $1"; pass=$((pass + 1)); else echo "FAILED  $1   <-- $3"; fail=$((fail + 1)); fi; }

PL=$(q "insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'frc-pl-$TAG@example.test', now(), now()) returning id")
DM=$(q "insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'frc-dm-$TAG@example.test', now(), now()) returning id")
CAMP=$(q "insert into public.campaigns (name, created_by) values ('FRC $TAG', '$DM') returning id")
q "insert into public.campaign_members (campaign_id, user_id, role) values ('$CAMP', '$DM', 'dm'), ('$CAMP', '$PL', 'player');
   insert into public.campaign_governance (campaign_id, preset) values ('$CAMP', 'relaxed');" >/dev/null
CH=$(q "insert into public.characters (owner_id, name, level, hp_max, hp_current, strength, dexterity, constitution, intelligence, wisdom, charisma, campaign_id)
        values ('$PL', 'FRC Racer', 1, 40, 40, 15, 14, 14, 10, 12, 10, '$CAMP') returning id")
q "insert into public.character_governance (character_id, setup_complete) values ('$CH', true)" >/dev/null
sess "$PL" "select public.set_character_class('$CH', 'fighter-phb', 4, null) is not null;" >/dev/null
DL0=$(q "select deadlocks from pg_stat_database where datname = current_database()")

assign() { sess "$PL" "select (public.assign_character_feat('$CH', '$1', '$2'::jsonb, 'direct', null, null, null) is not null);" >/dev/null
           q "select id from public.character_feats where character_id = '$CH' and feat_version_id = '$1'"; }

# ---- 1. three sessions remove the same feat at once
removed=0; absent=0; other=0
for i in $(seq 1 "$N"); do
  F=$(assign tough-2014 '{}')
  T=$(mktemp -d)
  sess "$PL" "select 'REMOVED' from public.remove_character_feat('$F', 'device A') limit 1;" >"$T/a" &
  sess "$PL" "select 'REMOVED' from public.remove_character_feat('$F', 'device B') limit 1;" >"$T/b" &
  sess "$DM" "select 'REMOVED' from public.remove_character_feat('$F', 'dm') limit 1;" >"$T/c" &
  wait
  for f in a b c; do
    if grep -q '^REMOVED' "$T/$f"; then removed=$((removed + 1));
    elif grep -q 'no longer on the character' "$T/$f"; then absent=$((absent + 1));
    else other=$((other + 1)); echo "  unexpected: $(cat "$T/$f")"; fi
  done
  rm -rf "$T"
done
AUD=$(q "select count(*) from public.campaign_audit_events where character_id = '$CH' and event_type = 'feat_removed'")
ok "same feat removed by 3 sessions at once: exactly one removal per round ($N rounds)" "$([ "$removed" = "$N" ] && echo 1)" "removed=$removed"
ok "... the other sessions get the friendly 'no longer on the character' answer" "$([ "$absent" = "$((2 * N))" ] && [ "$other" = 0 ] && echo 1)" "absent=$absent other=$other"
ok "... one audit event per round (no duplicate)" "$([ "$AUD" = "$N" ] && echo 1)" "audit=$AUD"
HP=$(q "select (public._feat_hp_bonus('$CH') ->> 'max')::int")
ok "... maximum HP back to 40 (no double subtraction)" "$([ "$HP" = 40 ] && echo 1)" "$HP"

# ---- 2. removal racing a choice change and sheet reads
bad=0
for i in $(seq 1 "$N"); do
  F=$(assign resilient-2014 '{"ability": ["con"]}')
  T=$(mktemp -d)
  sess "$PL" "select 'OK' from public.remove_character_feat('$F', null) limit 1;" >"$T/a" &
  sess "$PL" "select 'OK' from public.set_character_feat_choices('$CH', 'cf:$F', '{\"ability\": [\"str\"]}'::jsonb) limit 1;" >"$T/b" &
  sess "$DM" "select 'OK' from public.get_character_reads('$CH', array['get_character_derived_stats', 'get_character_feats']) limit 1;" >"$T/c" &
  wait
  for f in a b c; do
    if ! grep -qE '^OK|no longer on the character|is not granted to this character' "$T/$f"; then bad=$((bad + 1)); echo "  unexpected: $(cat "$T/$f")"; fi
  done
  rm -rf "$T"
done
LEFT=$(q "select count(*) from public.character_feats where character_id = '$CH'")
CHO=$(q "select count(*) from public.character_feat_choices c where character_id = '$CH' and not exists (select 1 from public.character_feats f where 'cf:' || f.id = c.grant_key)")
ok "removal racing a choice change and a sheet read: only friendly outcomes" "$([ "$bad" = 0 ] && echo 1)" "bad=$bad"
ok "... no feat and no orphan choice row left" "$([ "$LEFT" = 0 ] && [ "$CHO" = 0 ] && echo 1)" "feats=$LEFT orphan_choices=$CHO"
RES=$(q "select count(*) from public.character_resources r where character_id = '$CH' and source_type = 'feat' and source_id like 'cf:%'")
ok "... no orphan feat resource" "$([ "$RES" = 0 ] && echo 1)" "$RES"

DL1=$(q "select deadlocks from pg_stat_database where datname = current_database()")
ok "no deadlock" "$([ "$DL0" = "$DL1" ] && echo 1)" "$DL0 -> $DL1"

# cleanup (synthetic only)
q "delete from public.characters where id = '$CH'; delete from public.campaign_audit_events where campaign_id = '$CAMP';
   delete from public.campaigns where id = '$CAMP'; delete from auth.users where email like 'frc-%-$TAG@example.test';" >/dev/null
left=$(q "select count(*) from auth.users where email like 'frc-%@example.test'")
ok "cleanup: no synthetic rows left" "$([ "$left" = "0" ] && echo 1)" "$left"
echo "$pass passed, $fail failed"
exit $fail
