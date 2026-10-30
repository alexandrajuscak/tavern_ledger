#!/usr/bin/env bash
# Controlled production concurrency check of the progressive open (docs/FLUENCY_PRODUCTION_DEPLOYMENT.md, "Progressive release").
# Level N = N sessions at the same moment, each opening ONE real character as its owner exactly as the app does:
# get_character_shell, then get_character_reads(the sheet's domain reads). The API's real limit is applied
# (statement_timeout 8 s), so a timeout shows up as 57014 here instead of being hidden by a longer limit.
# The only write is the server-side read cache (tl_cache.character_reads). No player data is read out: output is timings,
# cache hit counts and error codes only, with characters numbered by id order.
# Usage: DB_URL_FILE=<access file> bash scripts/fluent/controlled_concurrency.sh "1 2 3 5"
# Stops at the first level with an error, a timeout or a request over 6 s.
set -uo pipefail
LEVELS="${1:-1 2 3 5}"
DBURL="$(tr -d '\r\n' < "${DB_URL_FILE:?set DB_URL_FILE}")"; export DBURL
DOMAIN="array['get_character_proficiencies','get_character_lineage','get_character_background','get_character_feats','get_character_class_summary','get_character_spell_slots','get_character_class_features','get_character_resources','get_character_states','get_character_transformation','companions','get_character_infusions','starting_equipment_applied','primary_class_starting_equipment']"
mask() { sed -E 's/[a-z0-9-]+\.pooler\.supabase\.com/<pooler-host>/g; s/postgres\.[a-z0-9]{20}/postgres.<ref>/g; s/[0-9a-f]{8}-[0-9a-f-]{27}/<uuid>/g'; }
session() {   # $1 = character index (1-based, by id order, synthetic smoke characters excluded)
  MSYS_NO_PATHCONV=1 docker run --rm -i -e DBURL postgres:17 sh -c 'psql "$DBURL" -X -q -A -t -v ON_ERROR_STOP=1' 2>&1 <<SQL | mask
set statement_timeout = '8s';
do \$\$ declare r record; t0 timestamptz; s jsonb; d jsonb; ts int; td int; begin
  select c.id, c.owner_id into r from public.characters c where c.name not like 'Smoke FL %' order by c.id offset $(( $1 - 1 )) limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', r.owner_id, 'role', 'authenticated')::text, true);
  set local role authenticated;
  t0 := clock_timestamp(); s := public.get_character_shell(r.id); ts := round(extract(epoch from clock_timestamp() - t0) * 1000);
  t0 := clock_timestamp(); d := public.get_character_reads(r.id, $DOMAIN); td := round(extract(epoch from clock_timestamp() - t0) * 1000);
  raise notice 'char $1 shell_ms % shell_kb % shell_hits % domain_ms % domain_kb % domain_hits % errors %', ts, round(length(s::text) / 1024.0),
    s -> 'cache' ->> 'hits', td, round(length(d::text) / 1024.0), d -> 'cache' ->> 'hits',
    coalesce((select string_agg(k || ':' || (s -> 'errors' -> k ->> 'code'), ',') from jsonb_object_keys(s -> 'errors') k), '')
    || coalesce((select string_agg(k || ':' || (d -> 'errors' -> k ->> 'code'), ',') from jsonb_object_keys(d -> 'errors') k), '');
end \$\$;
SQL
}
health() {
  MSYS_NO_PATHCONV=1 docker run --rm -i -e DBURL postgres:17 sh -c 'psql "$DBURL" -X -q -A -t' 2>&1 <<'SQL' | mask
select 'health|' || now()::text || '|active=' || count(*) filter (where state = 'active' and pid <> pg_backend_pid())
  || '|connections=' || count(*) || '|realtime_subs=' || (select count(*) from realtime.subscription)
from pg_stat_activity where datname = current_database();
SQL
}
for L in $LEVELS; do
  echo "== level $L"; health
  out=$(for i in $(seq 1 "$L"); do session "$i" & done; wait)
  echo "$out" | sed 's/^NOTICE:  //'
  if echo "$out" | grep -qE "^(psql:.*)?ERROR|57014|canceling|errors [a-z_]"; then echo "STOP: error at level $L"; exit 1; fi
  slow=$(echo "$out" | grep -oE "(shell|domain)_ms [0-9]+" | awk '$2 > 6000' | wc -l)
  if [ "$slow" -gt 0 ]; then echo "STOP: a request over 6 s at level $L"; exit 1; fi
  sleep 5
done
health
echo "ALL LEVELS PASSED"
