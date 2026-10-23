-- =============================================================================
-- Read views. All use security_invoker = true (PostgreSQL 15+, the Supabase default), so the RLS of the
-- underlying tables applies to whoever queries them. Nothing here bypasses RLS.
-- =============================================================================

create view public.v_item_catalog with (security_invoker = true) as
select
  i.id, i.name, i.kind_id, k.name as kind_name, i.category_id, c.name as category_name,
  i.rarity_id, i.is_magic, i.requires_attunement, i.is_consumable, i.stackable, i.stack_max,
  i.weight_lb, i.cost_value, i.cost_unit, i.cost_cp, i.base_item_id, i.data_source_id,
  i.source_book_id, sb.name as source_book_name, i.source_label, i.source_url, i.owner_id, i.campaign_id,
  ws.weapon_group, ws.damage_dice, ws.damage_type_id, ws.versatile_damage, ws.is_ranged, ws.range_type,
  ws.range_normal, ws.range_max, ws.ammo_type_id as weapon_ammo_type_id, fs.reload, fs.misfire,
  (select coalesce(array_agg(l.property_id order by l.property_id), '{}'::text[])
     from public.weapon_property_links l where l.item_id = i.id) as weapon_properties,
  a.base_ac, a.ac_bonus, a.dex_modifier_mode, a.dex_cap, a.strength_requirement, a.stealth_disadvantage, a.is_shield,
  am.ammo_type_id, am.pack_size, am.pack_cost_cp,
  cs.capacity_weight_lb, cs.capacity_volume_cuft, cs.weightless_contents, cs.extradimensional,
  coalesce(ms.speed_value, vs.speed_value) as speed_value, coalesce(ms.speed_unit, vs.speed_unit) as speed_unit,
  ms.carrying_capacity_lb, vs.cargo_lb,
  (select coalesce(array_agg(t.tag_id order by t.tag_id), '{}'::text[])
     from public.item_tag_links t where t.item_id = i.id) as tag_ids
from public.items i
join public.item_kinds k on k.id = i.kind_id
left join public.item_categories c on c.id = i.category_id
left join public.source_books sb on sb.id = i.source_book_id
left join public.weapon_stats ws on ws.item_id = i.id
left join public.firearm_stats fs on fs.item_id = i.id
left join public.armor_stats a on a.item_id = i.id
left join public.ammunition_stats am on am.item_id = i.id
left join public.container_stats cs on cs.item_id = i.id
left join public.mount_stats ms on ms.item_id = i.id
left join public.vehicle_stats vs on vs.item_id = i.id;

-- Inventory read model. `equipped` here (and the legacy column) is derived from character_equipment.
create view public.v_inventory_detail with (security_invoker = true) as
select
  ii.id, ii.inventory_id, inv.kind as inventory_kind, inv.character_id,
  ii.item_id, i.kind_id, i.category_id, i.rarity_id, i.is_magic, i.requires_attunement, i.stackable,
  ii.name, ii.custom_name, coalesce(nullif(ii.custom_name, ''), ii.name) as display_name, ii.notes, ii.description,
  ii.quantity, coalesce(i.weight_lb, ii.weight) as unit_weight_lb,
  ii.container_item_id, ii.is_quest_item, ii.is_attuned, ii.attuned_at,
  ii.charges_current, ii.charges_max, ii.charges_recharge, ii.durability, ii.state,
  ii.consumable_override, coalesce(ii.consumable_override, i.is_consumable, false) as is_consumable,
  ii.stack_key, ii.sort_order, ii.acquired_at,
  ce.slot_id as equipped_slot, (ce.slot_id is not null) as equipped,
  (select coalesce(array_agg(m.modifier_id order by m.modifier_id), '{}'::text[])
     from public.inventory_item_modifiers m where m.inventory_item_id = ii.id) as modifier_ids
from public.inventory_items ii
join public.inventories inv on inv.id = ii.inventory_id
left join public.items i on i.id = ii.item_id
left join public.character_equipment ce on ce.inventory_item_id = ii.id;

create view public.v_character_equipment with (security_invoker = true) as
select ce.slot_id, s.name as slot_name, s.sort_order as slot_order, ce.equipped_at, d.*
from public.character_equipment ce
join public.equipment_slots s on s.id = ce.slot_id
join public.v_inventory_detail d on d.id = ce.inventory_item_id;

-- Contents of every container: weight inside (a nested weightless container counts only itself),
-- capacity, and warnings. Capacity is NOT enforced (MVP: warn only).
create view public.v_container_contents with (security_invoker = true) as
with recursive tree as (
  select c.id as container_id, x.id as item_id, 1 as depth, false as hidden
  from public.inventory_items c
  join public.inventory_items x on x.container_item_id = c.id
  union all
  select t.container_id, x.id, t.depth + 1, t.hidden or coalesce(mcs.weightless_contents, false)
  from tree t
  join public.inventory_items mid on mid.id = t.item_id
  left join public.container_stats mcs on mcs.item_id = mid.item_id
  join public.inventory_items x on x.container_item_id = mid.id
  where t.depth < 8
)
select c.id as container_item_id, c.inventory_id, c.item_id,
       cs.capacity_weight_lb, cs.capacity_volume_cuft,
       coalesce(cs.weightless_contents, false) as weightless_contents,
       coalesce(cs.extradimensional, false) as extradimensional,
       count(t.item_id)::int as items_inside,
       coalesce(sum(case when t.hidden then 0 else coalesce(i.weight_lb, x.weight) * x.quantity end), 0)::numeric(12, 2) as contents_weight_lb,
       (cs.capacity_weight_lb is not null
        and coalesce(sum(case when t.hidden then 0 else coalesce(i.weight_lb, x.weight) * x.quantity end), 0) > cs.capacity_weight_lb) as over_capacity,
       (coalesce(cs.extradimensional, false) and coalesce(bool_or(xcs.extradimensional), false)) as extradimensional_nesting
from public.inventory_items c
left join public.container_stats cs on cs.item_id = c.item_id
left join tree t on t.container_id = c.id
left join public.inventory_items x on x.id = t.item_id
left join public.items i on i.id = x.item_id
left join public.container_stats xcs on xcs.item_id = x.item_id
where cs.item_id is not null or exists (select 1 from public.inventory_items k where k.container_item_id = c.id)
group by c.id, c.inventory_id, c.item_id, cs.capacity_weight_lb, cs.capacity_volume_cuft, cs.weightless_contents, cs.extradimensional;

-- Carried weight per inventory: containers count with their contents, except contents of a weightless
-- container (only the container itself counts). Mounts/vehicles never count; vehicle cargo lives in its own
-- inventory, so it is never part of a character's weight.
create view public.v_inventory_weight with (security_invoker = true) as
with recursive chain as (
  select ii.id as item_id, ii.container_item_id as ancestor, 1 as depth
  from public.inventory_items ii where ii.container_item_id is not null
  union all
  select c.item_id, p.container_item_id, c.depth + 1
  from chain c join public.inventory_items p on p.id = c.ancestor
  where p.container_item_id is not null and c.depth < 8
), hidden as (
  select distinct c.item_id
  from chain c
  join public.inventory_items a on a.id = c.ancestor
  join public.container_stats cs on cs.item_id = a.item_id and cs.weightless_contents
)
select ii.inventory_id,
       count(*)::int as stacks,
       sum(ii.quantity)::int as pieces,
       coalesce(sum(case when i.kind_id in ('mount', 'vehicle') or h.item_id is not null then 0
                         else coalesce(i.weight_lb, ii.weight) * ii.quantity end), 0)::numeric(12, 2) as total_weight_lb
from public.inventory_items ii
left join public.items i on i.id = ii.item_id
left join hidden h on h.item_id = ii.id
group by ii.inventory_id;

create view public.v_character_attunement with (security_invoker = true) as
select c.id as character_id,
       count(ii.id) filter (where ii.is_attuned)::int as attuned_count,
       3 as attunement_limit,
       3 - count(ii.id) filter (where ii.is_attuned)::int as slots_free
from public.characters c
left join public.inventories inv on inv.character_id = c.id
left join public.inventory_items ii on ii.inventory_id = inv.id
group by c.id;

create view public.v_owned_assets_detail with (security_invoker = true) as
select oa.id, oa.item_id, i.kind_id, i.name as catalog_name, coalesce(oa.custom_name, i.name) as display_name,
       oa.character_id, oa.campaign_id, oa.notes, oa.current_hp, oa.cargo_inventory_id, oa.acquired_at,
       coalesce(ms.speed_value, vs.speed_value) as speed_value, coalesce(ms.speed_unit, vs.speed_unit) as speed_unit,
       coalesce(ms.carrying_capacity_lb, vs.cargo_lb) as cargo_capacity_lb,
       w.total_weight_lb as cargo_weight_lb,
       (coalesce(ms.carrying_capacity_lb, vs.cargo_lb) is not null and coalesce(w.total_weight_lb, 0) > coalesce(ms.carrying_capacity_lb, vs.cargo_lb)) as cargo_over_capacity
from public.owned_assets oa
join public.items i on i.id = oa.item_id
left join public.mount_stats ms on ms.item_id = oa.item_id
left join public.vehicle_stats vs on vs.item_id = oa.item_id
left join public.v_inventory_weight w on w.inventory_id = oa.cargo_inventory_id;
