#!/usr/bin/env bash
# Concurrency checks for change requests (20261019000200): two sessions at the same time. Session 1 holds its
# transaction open for 3 seconds; session 2 must wait for the request / character row lock and then see the result.
#   1. two DMs approve the same request          -> applied once, the level rises once, the second DM is refused
#   2. approve and reject at once                 -> exactly one decision
#   3. approve and the player's cancel at once    -> exactly one final state
#   4. approve and a direct DM level correction   -> applied before the correction, or refused as stale after it
#   5. a lock and an approval at once             -> the lock first: apply_failed (nothing applied); never both
#   6. the same idempotency key twice at once     -> one request
# Synthetic users only; everything is removed at the end. Usage: bash supabase/tests/governance_concurrency_test.sh <db container>
set -uo pipefail
NAME=${1:-tavern-ledger-pgtest}
px() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -At -q -v ON_ERROR_STOP=1 "$@"; }
P=a9999999-9999-9999-9999-9999999999d1; D1=a9999999-9999-9999-9999-9999999999d2; D2=a9999999-9999-9999-9999-9999999999d3
CAMP=c9999999-9999-9999-9999-9999999999d1; C=aaaaaaaa-0000-0000-0000-0000000000d1
RC=0
px <<SQL >/dev/null
insert into auth.users (id, email) values ('$P', 'gov-player@test'), ('$D1', 'gov-dm1@test'), ('$D2', 'gov-dm2@test') on conflict do nothing;
insert into public.campaigns (id, name, created_by) values ('$CAMP', 'Governance Race', '$D1') on conflict do nothing;
insert into public.campaign_members (campaign_id, user_id, role) values ('$CAMP', '$P', 'player'), ('$CAMP', '$D1', 'dm'), ('$CAMP', '$D2', 'dm')
  on conflict do nothing;
insert into public.campaign_governance (campaign_id, preset) values ('$CAMP', 'standard') on conflict (campaign_id) do update set preset = 'standard';
insert into public.characters (id, owner_id, name, campaign_id, strength, constitution, hp_max, hp_current) values
  ('$C', '$P', 'Governance Racer', '$CAMP', 15, 14, 12, 12) on conflict do nothing;
SQL
as_user() { printf "begin;\nselect set_config('request.jwt.claim.sub', '%s', true);\nset local role authenticated;\n%s\nselect pg_sleep(%s);\ncommit;\n" "$1" "$2" "$3"; }
run() { as_user "$1" "$2" 0 | px; }
pair() {   # $1 user / $2 statement of session 1 (holds 3 s), $3 user / $4 statement of session 2
  O1=$(mktemp); E1=$(mktemp); O2=$(mktemp); E2=$(mktemp)
  as_user "$1" "$2" 3 | px >"$O1" 2>"$E1" & PID=$!
  sleep 1
  as_user "$3" "$4" 0 | px >"$O2" 2>"$E2"; S2=$?
  wait $PID; S1=$?
  OUT1=$(tr -d '\n' <"$O1" | tail -c 200); OUT2=$(tr -d '\n' <"$O2" | tail -c 200); ERR2=$(tr -d '\n' <"$E2" | tail -c 160)
  rm -f "$O1" "$E1" "$O2" "$E2"
}
reset() { px >/dev/null <<SQL
begin;
delete from public.change_requests where character_id = '$C';
delete from public.character_classes where character_id = '$C';
delete from public.character_governance where character_id = '$C';
insert into public.character_governance (character_id, setup_complete) values ('$C', true);
commit;
SQL
run "$D1" "select public.set_character_class('$C', 'fighter-phb', 1, null, true) is not null;" >/dev/null
}
lvl() { px -c "select coalesce(sum(level), 0) from public.character_classes where character_id = '$C'"; }
status() { px -c "select status from public.change_requests where id = '$1'"; }
request() {   # $1 = level -> request id (submitted by the player)
  run "$P" "select public.create_change_request('$C', '[{\"op\": \"set_character_class\", \"args\": {\"p_class_version\": \"fighter-phb\", \"p_level\": $1}}]'::jsonb) ->> 'id';" | sed -n 2p
}
check() { if eval "$2"; then echo "PASSED  $1"; else echo "FAILED  $1 ($3)"; RC=1; fi; }

# 1. two DMs approve at once
reset; R=$(request 2)
pair "$D1" "select public.review_change_request('$R', 'approve') ->> 'status';" "$D2" "select public.review_change_request('$R', 'approve') ->> 'status';"
L=$(lvl); ST=$(status "$R"); EV=$(px -c "select count(*) from public.change_request_events where request_id = '$R' and event = 'applied'")
check "two DMs approve the same request: applied once, level 1 -> 2 once, the second DM is refused" \
  '[ "$S1" = 0 ] && [ "$S2" != 0 ] && [ "$L" = 2 ] && [ "$ST" = applied ] && [ "$EV" = 1 ]' "s1=$S1 s2=$S2 level=$L status=$ST applied=$EV err=$ERR2"

# 2. approve and reject at once
reset; R=$(request 2)
pair "$D1" "select public.review_change_request('$R', 'approve') ->> 'status';" "$D2" "select public.review_change_request('$R', 'reject', 'No') ->> 'status';"
L=$(lvl); ST=$(status "$R")
check "approve and reject at once: one decision only (approved first: applied, the rejection is refused)" \
  '[ "$S1" = 0 ] && [ "$S2" != 0 ] && [ "$ST" = applied ] && [ "$L" = 2 ]' "s1=$S1 s2=$S2 level=$L status=$ST err=$ERR2"

# 3. the player cancels while the DM approves
reset; R=$(request 2)
pair "$P" "select public.cancel_change_request('$R') ->> 'status';" "$D1" "select public.review_change_request('$R', 'approve') ->> 'status';"
L=$(lvl); ST=$(status "$R")
check "cancel and approve at once: cancelled first, the approval is refused, nothing applied" \
  '[ "$S1" = 0 ] && [ "$S2" != 0 ] && [ "$ST" = cancelled ] && [ "$L" = 1 ]' "s1=$S1 s2=$S2 level=$L status=$ST err=$ERR2"

# 4. a direct DM correction to level 3 while another DM approves level 2
reset; R=$(request 2)
pair "$D2" "select public.set_character_class('$C', 'fighter-phb', 3) is not null;" "$D1" "select public.review_change_request('$R', 'approve') ->> 'refused';"
L=$(lvl); ST=$(status "$R"); STALE=$(px -c "select stale from public.change_requests where id = '$R'")
check "direct correction and approval at once: the approval sees the new state and refuses as stale (level stays 3)" \
  '[ "$S1" = 0 ] && [ "$L" = 3 ] && [ "$ST" = submitted ] && [ "$STALE" = t ]' "s1=$S1 s2=$S2 level=$L status=$ST stale=$STALE out=$OUT2 err=$ERR2"

# 5. a progression lock while another DM approves
reset; R=$(request 2)
pair "$D2" "select public.set_character_lock('$C', 'progression_locked', 'race') ->> 'lock_mode';" "$D1" "select public.review_change_request('$R', 'approve') ->> 'status';"
L=$(lvl); ST=$(status "$R")
check "lock and approval at once: the lock wins, the request is apply_failed and nothing is applied" \
  '[ "$S1" = 0 ] && [ "$L" = 1 ] && [ "$ST" = apply_failed ]' "s1=$S1 s2=$S2 level=$L status=$ST out=$OUT2 err=$ERR2"

# 6. the same idempotency key twice at once
reset
K=b9999999-9999-9999-9999-9999999999d9
STMT="select public.create_change_request('$C', '[{\"op\": \"set_character_class\", \"args\": {\"p_class_version\": \"fighter-phb\", \"p_level\": 2}}]'::jsonb, null, null, null, true, '$K') ->> 'id';"
pair "$P" "$STMT" "$P" "$STMT"
N=$(px -c "select count(*) from public.change_requests where character_id = '$C'")
check "the same idempotency key twice at once: exactly one request" '[ "$N" = 1 ] && [ "$S1" = 0 ]' "s1=$S1 s2=$S2 requests=$N err=$ERR2"

px >/dev/null <<SQL
delete from public.change_requests where character_id = '$C';
delete from public.campaign_audit_events where campaign_id = '$CAMP';
delete from public.characters where id = '$C';
delete from public.campaigns where id = '$CAMP';
delete from auth.users where id in ('$P', '$D1', '$D2');
SQL
[ "$RC" = 0 ] && echo "PASSED  governance concurrency (6 scenarios)"
exit "$RC"
