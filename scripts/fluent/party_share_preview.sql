-- Party-wide identification (20261114000100): READ-ONLY preview of what the migration's catch-up would change. Run it on
-- production BEFORE the deploy (it does not need the migration; it never writes):
--   psql -v ON_ERROR_STOP=1 -At -f scripts/fluent/party_share_preview.sql
-- Output: ids and counts only, never an item name, a decoy or a description (hb- / cc- ids are opaque; an official slug is the
-- public catalog id). Same rules as the migration:
--   * holds: a DM "set" that nothing changed afterwards, or a last history event that took knowledge away -> never raised, never a
--     source;
--   * what a character can share is only what it learned IN THIS campaign (M1b): the facts its item_knowledge_events with this
--     campaign id added (new_revealed - old_revealed), and "identified" only when such an event reached it; items of no campaign
--     or of this campaign only;
--   * the party level = union of those levels; the target's own row knowledge is part of its new level (a share never lowers);
--   * a character that holds only undisguised copies of the item is skipped;
--   * every other character of the campaign (with or without a copy) is raised when it knows less.
--   * M1c: a source's level is capped by its CURRENT record (what the DM took back is never shared);
-- "row" lines: campaign, character, item, current -> new level, copies renamed, pending examine attempts that would close as
-- "Learned from the party" (m3), and "ROW-ABOVE" when a copy already knows more than the character's record (m4: the record is
-- raised to it; nothing is lowered). Totals at the end, with two sizing counts (M1c exposure; characters without a
-- cache counter row). With no knowledge data: only the totals (0).
begin read only;
with hold_dm as (
  select distinct on (e.character_id, e.after ->> 'item_id') e.character_id, e.after ->> 'item_id' as item_id, e.after ->> 'mode' as mode, e.created_at
  from public.campaign_audit_events e
  where e.event_type = 'item_revealed' and e.visibility = 'dm' and e.character_id is not null and e.after ? 'mode' and e.after ? 'item_id'
  order by e.character_id, e.after ->> 'item_id', e.created_at desc, e.id desc),
last_ev as (
  select distinct on (ev.character_id, ev.item_id) ev.*
  from public.item_knowledge_events ev order by ev.character_id, ev.item_id, ev.created_at desc, ev.id desc),
held as (
  select h.character_id, h.item_id from hold_dm h
  where h.mode = 'set' and not exists (select 1 from public.item_knowledge_events ev where ev.character_id = h.character_id
                                       and ev.item_id = h.item_id and ev.created_at > h.created_at)
  union
  select l.character_id, l.item_id from last_ev l
  where l.old_state is not null
    and not (l.new_state = 'identified'
             or (l.old_state <> 'identified' and coalesce(l.old_revealed, '{}') <@ coalesce(l.new_revealed, '{}')))),
rec as (
  select ck.*, c.campaign_id, exists (select 1 from held h where h.character_id = ck.character_id and h.item_id = ck.item_id) as is_held,
         coalesce((select bool_or(e.new_state = 'identified' and e.old_state is distinct from 'identified') from public.item_knowledge_events e
                   where e.character_id = ck.character_id and e.item_id = ck.item_id and e.campaign_id = c.campaign_id), false) as l_ident,
         coalesce((select array_agg(distinct x order by x) from public.item_knowledge_events e cross join unnest(e.new_revealed) x
                   where e.character_id = ck.character_id and e.item_id = ck.item_id and e.campaign_id = c.campaign_id
                     and x <> 'all' and not (x = any (coalesce(e.old_revealed, '{}')))), '{}') as l_rev
  from public.character_item_knowledge ck join public.characters c on c.id = ck.character_id
  join public.items it on it.id = ck.item_id
  where c.campaign_id is not null and (it.campaign_id is null or it.campaign_id = c.campaign_id)),
-- M1c: the shareable level is capped by the source's CURRENT record (identified only while identified; otherwise only facts the
-- record still reveals)
capped as (
  select r.*, (r.l_ident and r.state = 'identified') as c_ident,
         case when r.state = 'identified' then r.l_rev else coalesce(array(select x from unnest(r.l_rev) x where x = any (r.revealed) order by x), '{}') end as c_rev
  from rec r),
party as (
  select r.campaign_id, r.item_id, bool_or(r.c_ident) as ident,
         coalesce((select array_agg(distinct x order by x) from capped r2 cross join unnest(r2.c_rev) x
                   where r2.campaign_id = r.campaign_id and r2.item_id = r.item_id and not r2.is_held), '{}') as rev
  from capped r where not r.is_held and (r.c_ident or cardinality(r.c_rev) > 0)
  group by 1, 2),
target as (
  select p.campaign_id, c.id as character_id, p.item_id, ck.state as cur_state, ck.revealed as cur_rev, p.ident, p.rev,
         rk.n_disg, rk.row_ident, rk.row_rev,
         (select count(*) from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
          where inv.character_id = c.id and ii.item_id = p.item_id
            and not exists (select 1 from public.inventory_item_knowledge k where k.inventory_item_id = ii.id)) as n_plain,
         exists (select 1 from held h where h.character_id = c.id and h.item_id = p.item_id) as is_held
  from party p join public.characters c on c.campaign_id = p.campaign_id
  left join public.character_item_knowledge ck on ck.character_id = c.id and ck.item_id = p.item_id
  cross join lateral (
    select count(distinct ii.id) as n_disg, coalesce(bool_or(k.state = 'identified'), false) as row_ident,
           coalesce(array_agg(distinct x) filter (where x is not null), '{}') as row_rev
    from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
    join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
    left join lateral unnest(k.revealed) x on true
    where inv.character_id = c.id and ii.item_id = p.item_id) rk),
planned as (
  select t.*,
         case when t.ident or t.cur_state = 'identified' or t.row_ident then 'identified' else 'partially_identified' end as new_state,
         array(select distinct x from unnest(coalesce(t.cur_rev, '{}') || t.rev || t.row_rev) x where x <> 'all' order by 1) as new_rev
  from target t),
change as (
  select p.* from planned p
  where not p.is_held and not (p.n_plain > 0 and p.n_disg = 0)
    and (p.cur_state is null or (p.cur_state, p.cur_rev) is distinct from (p.new_state, p.new_rev)))
select 'row ' || campaign_id || ' ' || character_id || ' ' || item_id || ' ' || coalesce(cur_state, 'none') || '[' || coalesce(array_to_string(cur_rev, ','), '') || ']'
       || ' -> ' || new_state || '[' || array_to_string(new_rev, ',') || '] copies renamed ' || n_disg
       || ' pending examines closed ' || (select count(*) from public.item_identify_attempts a where a.character_id = change.character_id
                                          and a.item_id = change.item_id and a.status = 'pending' and change.new_state = 'identified')
       || case when row_ident and coalesce(cur_state, '') <> 'identified' or not (row_rev <@ coalesce(cur_rev, '{}')) then ' ROW-ABOVE' else '' end
from change order by campaign_id, character_id, item_id;

-- totals
select 'totals: records ' || (select count(*) from public.character_item_knowledge)
    || ', records with knowledge ' || (select count(*) from public.character_item_knowledge where state <> 'unidentified' or cardinality(revealed) > 0)
    || ', learned without a campaign-tagged event (never a source) '
    || (select count(*) from public.character_item_knowledge ck join public.characters c on c.id = ck.character_id
        where (ck.state <> 'unidentified' or cardinality(ck.revealed) > 0) and c.campaign_id is not null
          and not exists (select 1 from public.item_knowledge_events e where e.character_id = ck.character_id and e.item_id = ck.item_id
                          and e.campaign_id = c.campaign_id and (e.new_state <> 'unidentified' or cardinality(e.new_revealed) > 0)))
    || ', history events ' || (select count(*) from public.item_knowledge_events)
    || ', DM set audits ' || (select count(*) from public.campaign_audit_events where event_type = 'item_revealed' and visibility = 'dm' and after ->> 'mode' = 'set')
    || ', pending examine attempts ' || (select count(*) from public.item_identify_attempts where status = 'pending')
    -- M1c exposure: records whose current-campaign events once reached more than the record knows now (capped by the fix)
    || ', M1c exposure (records knowing less now than their campaign events once reached) '
    || (select count(*) from public.character_item_knowledge ck join public.characters c on c.id = ck.character_id
        where c.campaign_id is not null and exists (
          select 1 from public.item_knowledge_events e where e.character_id = ck.character_id and e.item_id = ck.item_id
            and e.campaign_id = c.campaign_id
            and ((e.new_state = 'identified' and ck.state <> 'identified')
                 or (ck.state <> 'identified' and not (coalesce(e.new_revealed, '{}') <@ ck.revealed)))))
    || ', characters without a tl_cache.character_rev row '
    || (select count(*) from public.characters c where not exists (select 1 from tl_cache.character_rev r where r.character_id = c.id));
rollback;
