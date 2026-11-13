-- Party-wide identification (20261114000100): READ-ONLY preview of what the migration's catch-up would change. Run it on
-- production BEFORE the deploy (it does not need the migration; it never writes):
--   psql -v ON_ERROR_STOP=1 -At -f scripts/fluent/party_share_preview.sql
-- Output: ids and counts only, never an item name, a decoy or a description (hb- / cc- ids are opaque; an official slug is the
-- public catalog id). Same rules as the migration:
--   * holds: a DM "set" that nothing changed afterwards, or a last history event that took knowledge away -> never raised;
--   * the party level of an item = union of the NON-HELD records of the campaign's characters (items of no campaign or of that
--     campaign only); a record with nothing known does not count;
--   * a character that holds only undisguised copies of the item is skipped (it sees everything already);
--   * every other character of the campaign (with or without a copy) is raised to the party level when it knows less.
-- Section "row" lines: campaign, character, item, current -> new level, copies (disguised / undisguised) that would be renamed.
-- With no knowledge data the output is only the header and the totals (0).
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
  select ck.*, c.campaign_id, exists (select 1 from held h where h.character_id = ck.character_id and h.item_id = ck.item_id) as is_held
  from public.character_item_knowledge ck join public.characters c on c.id = ck.character_id
  join public.items it on it.id = ck.item_id
  where c.campaign_id is not null and (it.campaign_id is null or it.campaign_id = c.campaign_id)),
party as (
  select r.campaign_id, r.item_id, bool_or(r.state = 'identified') as ident,
         coalesce((select array_agg(distinct x order by x) from rec r2 cross join unnest(r2.revealed) x
                   where r2.campaign_id = r.campaign_id and r2.item_id = r.item_id and not r2.is_held), '{}') as rev
  from rec r where not r.is_held and (r.state <> 'unidentified' or cardinality(r.revealed) > 0)
  group by 1, 2),
target as (
  select p.campaign_id, c.id as character_id, p.item_id, ck.state as cur_state, ck.revealed as cur_rev,
         case when p.ident or ck.state = 'identified' then 'identified' else 'partially_identified' end as new_state,
         array(select distinct x from unnest(coalesce(ck.revealed, '{}') || p.rev) x order by 1) as new_rev,
         (select count(*) from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
          join public.inventory_item_knowledge k on k.inventory_item_id = ii.id where inv.character_id = c.id and ii.item_id = p.item_id) as n_disg,
         (select count(*) from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
          where inv.character_id = c.id and ii.item_id = p.item_id
            and not exists (select 1 from public.inventory_item_knowledge k where k.inventory_item_id = ii.id)) as n_plain,
         exists (select 1 from held h where h.character_id = c.id and h.item_id = p.item_id) as is_held
  from party p join public.characters c on c.campaign_id = p.campaign_id
  left join public.character_item_knowledge ck on ck.character_id = c.id and ck.item_id = p.item_id),
change as (
  select t.* from target t
  where not t.is_held and not (t.n_plain > 0 and t.n_disg = 0)
    and (t.cur_state is null or (t.cur_state, t.cur_rev) is distinct from (t.new_state, t.new_rev)))
select 'row ' || campaign_id || ' ' || character_id || ' ' || item_id || ' ' || coalesce(cur_state, 'none') || '[' || coalesce(array_to_string(cur_rev, ','), '') || ']'
       || ' -> ' || new_state || '[' || array_to_string(new_rev, ',') || '] copies renamed ' || n_disg
from change order by campaign_id, character_id, item_id;

-- totals (the same rules, counted)
select 'totals: records ' || (select count(*) from public.character_item_knowledge)
    || ', records with knowledge ' || (select count(*) from public.character_item_knowledge where state <> 'unidentified' or cardinality(revealed) > 0)
    || ', history events ' || (select count(*) from public.item_knowledge_events)
    || ', DM set audits ' || (select count(*) from public.campaign_audit_events where event_type = 'item_revealed' and visibility = 'dm' and after ->> 'mode' = 'set');
rollback;
