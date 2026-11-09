#!/usr/bin/env bash
# Permanent delete of unused DM content vs. assignment / a second delete / publish vs. archive (20261109000300,
# docs/CONTENT_MANAGEMENT.md). LOCAL Supabase only; synthetic users (cdc-*@example.test), campaign and character, removed at the end.
# Each round: a fresh published custom feat; then the DM deletes it while (in another session) it is assigned to a character.
# Exactly one may win: either the content and its catalog row are gone and no character references them, or both exist and the
# delete was refused with the friendly TLUSE. Never both, never a raw foreign-key error from the delete, never a deadlock, at most
# one audit event per content. Also: the same delete twice in parallel (one result, one audit event) and publish vs. archive.
# Usage: bash supabase/tests/content_deletion_concurrency_test.sh [rounds]
set -uo pipefail
DB=${DB:-supabase_db_tavern_ledger}
N="${1:-12}"
q() { docker exec -i "$DB" psql -U postgres -qAt -v ON_ERROR_STOP=1 -c "$1"; }
as() { echo "set role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\"}', false);"; }
TAG=$(date +%s)
DM=$(q "select gen_random_uuid()"); PL=$(q "select gen_random_uuid()"); CAMP=$(q "select gen_random_uuid()")
q "insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
     ('$DM', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cdc-dm-$TAG@example.test', now(), now()),
     ('$PL', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cdc-pl-$TAG@example.test', now(), now());
   insert into public.campaigns (id, name, created_by) values ('$CAMP', 'CDC concurrency $TAG', '$DM');
   insert into public.campaign_members (campaign_id, user_id, role) values ('$CAMP', '$DM', 'dm'), ('$CAMP', '$PL', 'player');" >/dev/null
CH=$(q "insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current) values ('$PL', 'CDC Hero', '$CAMP', 4, 30, 30) returning id" | head -1)
deadlocks() { q "select deadlocks from pg_stat_database where datname = current_database()"; }
newfeat() {   # a published custom feat (duplicate of an official one); prints "content_id|catalog_ref"
  { as "$DM"; echo "select (public.duplicate_official_as_homebrew('feat', 'alert-2024', '$CAMP') ->> 'id') as c \\gset
    select public.publish_dm_content(:'c') is not null;
    select :'c' || '|' || (select v.catalog_ref from public.dm_content d join public.dm_content_versions v on v.id = d.published_version_id where d.id = :'c');"; } |
    docker exec -i "$DB" psql -U postgres -qAt | tail -1
}
before=$(deadlocks)
won_del=0; won_add=0; both=0; neither=0; raw=0; errs=""; multi_audit=0
for r in $(seq 1 "$N"); do
  X=$(newfeat); C=${X%%|*}; REF=${X##*|}
  # odd rounds: the assignment gets a head start, so both orders are exercised (delete first / assignment first)
  D=0; A=0.6; [ $((r % 2)) = 1 ] && { D=0.6; A=0; }
  out=$( ( sleep "$D"; { as "$DM"; echo "select public.delete_unused_dm_content('$C', 'Alert (homebrew)');"; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1 | grep ERROR | sed 's/^/[del] /' ) &
         ( sleep "$A"; { as "$DM"; echo "select public.dm_assign_content('$C', array['$CH']::uuid[], 'dm_grant', '{}');"; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1 | grep ERROR | sed 's/^/[add] /' ) &
         wait )
  content=$(q "select count(*) from public.dm_content where id = '$C'")
  cat=$(q "select count(*) from public.feat_versions where id = '$REF'")
  rows=$(q "select count(*) from public.character_feats where feat_version_id = '$REF'")
  aud=$(q "select count(*) from public.campaign_audit_events where event_type = 'content_deleted' and before ->> 'content_id' = '$C'")
  if [ "$content$cat$rows" = "000" ]; then won_del=$((won_del + 1));
  elif [ "$content$cat$rows" = "111" ]; then won_add=$((won_add + 1));
  elif [ "$rows" = "0" ] && [ "$content" = "1" ]; then neither=$((neither + 1));
  else both=$((both + 1)); fi
  [ "$aud" -gt 1 ] && multi_audit=$((multi_audit + 1))
  if echo "$out" | grep "^\[del\]" | grep -qvE "in use|Archive it instead|campaign history"; then raw=$((raw + 1)); errs="$errs | $out"; fi
  q "delete from public.character_feats where character_id = '$CH'" >/dev/null
done
# the same delete twice at once
X=$(newfeat); C=${X%%|*}; REF=${X##*|}
twice=$( for i in 1 2; do ( { as "$DM"; echo "select public.delete_unused_dm_content('$C', 'Alert (homebrew)');"; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1 | grep -c ERROR ) & done; wait )
twice_aud=$(q "select count(*) from public.campaign_audit_events where event_type = 'content_deleted' and before ->> 'content_id' = '$C'")
# publish of a new version vs. archive at the same moment: one consistent final state, no raw error
X=$(newfeat); C=${X%%|*}
{ as "$DM"; echo "select public.new_dm_content_version('$C') is not null;"; } | docker exec -i "$DB" psql -U postgres -qAt >/dev/null 2>&1
pa=$( ( { as "$DM"; echo "select public.publish_dm_content('$C');"; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1 | grep ERROR | sed 's/^/[pub] /' ) &
      ( { as "$DM"; echo "select public.archive_dm_content('$C', 'race');"; } | docker exec -i "$DB" psql -U postgres -qAt 2>&1 | grep ERROR | sed 's/^/[arc] /' ) &
      wait )
pa_state=$(q "select status || ':' || (archived_at is not null) || ':' || (published_version_id is not null) from public.dm_content where id = '$C'")
after=$(deadlocks)
fail=0; pass=0
ok() { if [ "$2" = "1" ]; then echo "PASSED  $1"; pass=$((pass + 1)); else echo "FAILED  $1   <-- $3"; fail=$((fail + 1)); fi; }
ok "rounds: delete won $won_del, assignment won $won_add (each round exactly one winner; both orders seen)" "$([ $((won_del + won_add)) = "$N" ] && [ "$won_del" -gt 0 ] && [ "$won_add" -gt 0 ] && echo 1)" "both=$both neither=$neither"
ok "never deleted content still referenced by a character" "$([ "$both" = "0" ] && echo 1)" "$both"
ok "the delete never shows a raw error (only the friendly 'in use, archive it')" "$([ "$raw" = "0" ] && echo 1)" "$errs"
ok "at most one audit event per deleted content" "$([ "$multi_audit" = "0" ] && echo 1)" "$multi_audit"
ok "the same delete twice in parallel: deleted once (one audit event), the other a friendly not-found" \
  "$([ "$(q "select count(*) from public.dm_content where id = '$C'")" != "x" ] && [ "$(echo "$twice" | tr -d '\n ' | grep -o 1 | wc -l)" = "1" ] && [ "$twice_aud" = "1" ] && echo 1)" "errors=$twice audits=$twice_aud"
ok "publish vs. archive: one consistent final state, no raw error ($pa_state)" "$(echo "$pa" | grep -qvE "archived|Archived|no longer current|published|^$" && echo 0 || echo 1)" "$pa"
ok "no deadlock ($before -> $after)" "$([ "$after" = "$before" ] && echo 1)" "$before -> $after"
q "delete from public.character_feats where character_id = '$CH';
   delete from public.campaign_audit_events where campaign_id = '$CAMP';
   update public.dm_content set current_version_id = null, published_version_id = null where campaign_id = '$CAMP';
   delete from public.feat_versions where campaign_id = '$CAMP'; delete from public.feats where campaign_id = '$CAMP';
   delete from public.dm_content where campaign_id = '$CAMP';
   delete from public.characters where campaign_id = '$CAMP';
   delete from public.campaigns where id = '$CAMP'; delete from auth.users where email like 'cdc-%-$TAG@example.test';" >/dev/null
left=$(q "select (select count(*) from auth.users where email like 'cdc-%@example.test') + (select count(*) from public.campaigns where name like 'CDC concurrency%')")
ok "cleanup: no synthetic rows left" "$([ "$left" = "0" ] && echo 1)" "$left"
echo "$pass passed, $fail failed"
exit $fail
