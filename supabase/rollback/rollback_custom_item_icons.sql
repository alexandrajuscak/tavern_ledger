-- =============================================================================
-- Rollback of 20261114000200_custom_item_icons.sql. Run as postgres in ONE transaction:
--   psql -v ON_ERROR_STOP=1 -1 -f supabase/rollback/rollback_custom_item_icons.sql
-- Restores v_inventory_detail and v_character_equipment exactly as at 20261113000100 (pg_get_viewdef captured from the local
-- database before the migration; drop and recreate because the migration appended a column; grants as before), and drops the
-- trigger, the functions, the table campaign_item_icons and the two storage policies the migration added.
-- KEPT on purpose (hard rule: custom content is never deleted): the bucket `item-icons` and EVERY uploaded object in it. They
-- are harmless: nothing references them any more, the bucket has no listing policy left (no API user can list or upload),
-- and an object is only reachable by someone who already knows its random URL. Remove them by hand later only if wanted.
-- LOST (export first if it matters): the links item -> icon per campaign:
--   select * from public.campaign_item_icons;
-- Deploy order for a rollback: the previous frontend (?v=29) first, then this file.
-- =============================================================================
set local lock_timeout = '5s';

drop trigger if exists dm_content_versions_item_icon on public.dm_content_versions;
drop function if exists public._item_icon_follow_version();
drop function if exists public.dm_set_item_icon(uuid, text, text);
drop function if exists public.get_campaign_item_icons(uuid);
drop function if exists public._item_icon_in_scope(text, uuid);

-- ---- the inventory read model of 20261112000300 (drop and recreate: the migration appended a column) ----------------------
drop view public.v_character_equipment;
drop view public.v_inventory_detail;
create view public.v_inventory_detail with (security_invoker = true) as  SELECT ii.id,
    ii.inventory_id,
    inv.kind AS inventory_kind,
    inv.character_id,
        CASE
            WHEN mk.masked THEN NULL::text
            ELSE ii.item_id
        END AS item_id,
        CASE
            WHEN mk.masked THEN fc.kind_id
            ELSE i.kind_id
        END AS kind_id,
        CASE
            WHEN mk.masked THEN NULL::text
            ELSE i.category_id
        END AS category_id,
        CASE
            WHEN mk.masked THEN NULL::text
            ELSE i.rarity_id
        END AS rarity_id,
        CASE
            WHEN mk.masked THEN NULL::boolean
            ELSE i.is_magic
        END AS is_magic,
        CASE
            WHEN mk.masked THEN NULL::boolean
            ELSE i.requires_attunement
        END AS requires_attunement,
        CASE
            WHEN mk.masked THEN fc.stackable
            ELSE i.stackable
        END AS stackable,
    ii.name,
    ii.custom_name,
    COALESCE(NULLIF(ii.custom_name, ''::text), ii.name) AS display_name,
    ii.notes,
    ii.description,
    ii.quantity,
    COALESCE(i.weight_lb, ii.weight) AS unit_weight_lb,
    ii.container_item_id,
    ii.is_quest_item,
    ii.is_attuned,
    ii.attuned_at,
    ii.charges_current,
    ii.charges_max,
    ii.charges_recharge,
    ii.durability,
    ii.state,
    ii.consumable_override,
    COALESCE(ii.consumable_override,
        CASE
            WHEN mk.masked THEN fc.is_consumable
            ELSE i.is_consumable
        END, false) AS is_consumable,
    ii.stack_key,
    ii.sort_order,
    ii.acquired_at,
    ce.slot_id AS equipped_slot,
    (ce.slot_id IS NOT NULL) AS equipped,
    ( SELECT COALESCE(array_agg(m.modifier_id ORDER BY m.modifier_id), '{}'::text[]) AS "coalesce"
           FROM inventory_item_modifiers m
          WHERE (m.inventory_item_id = ii.id)) AS modifier_ids,
    kk.state AS knowledge_state
   FROM ((((((inventory_items ii
     JOIN inventories inv ON ((inv.id = ii.inventory_id)))
     LEFT JOIN items i ON ((i.id = ii.item_id)))
     LEFT JOIN character_equipment ce ON ((ce.inventory_item_id = ii.id)))
     LEFT JOIN inventory_item_knowledge kk ON ((kk.inventory_item_id = ii.id)))
     CROSS JOIN LATERAL ( SELECT ((kk.state IS NOT NULL) AND (kk.state <> 'identified'::text) AND (auth.uid() IS NOT NULL) AND (NOT _inventory_knows_all(ii.inventory_id))) AS masked) mk)
     LEFT JOIN LATERAL ( SELECT f.kind_id,
            f.stackable,
            f.is_consumable
           FROM _inventory_face(ii.id) f(kind_id, stackable, is_consumable)
          WHERE mk.masked) fc ON (true));
create view public.v_character_equipment with (security_invoker = true) as  SELECT ce.slot_id,
    s.name AS slot_name,
    s.sort_order AS slot_order,
    ce.equipped_at,
    d.id,
    d.inventory_id,
    d.inventory_kind,
    d.character_id,
    d.item_id,
    d.kind_id,
    d.category_id,
    d.rarity_id,
    d.is_magic,
    d.requires_attunement,
    d.stackable,
    d.name,
    d.custom_name,
    d.display_name,
    d.notes,
    d.description,
    d.quantity,
    d.unit_weight_lb,
    d.container_item_id,
    d.is_quest_item,
    d.is_attuned,
    d.attuned_at,
    d.charges_current,
    d.charges_max,
    d.charges_recharge,
    d.durability,
    d.state,
    d.consumable_override,
    d.is_consumable,
    d.stack_key,
    d.sort_order,
    d.acquired_at,
    d.equipped_slot,
    d.equipped,
    d.modifier_ids
   FROM ((character_equipment ce
     JOIN equipment_slots s ON ((s.id = ce.slot_id)))
     JOIN v_inventory_detail d ON ((d.id = ce.inventory_item_id)));
revoke all on public.v_inventory_detail, public.v_character_equipment from anon, authenticated;
grant select on public.v_inventory_detail, public.v_character_equipment to authenticated;
grant all on public.v_inventory_detail, public.v_character_equipment to service_role;

drop table if exists public.campaign_item_icons;
drop policy if exists "item_icons_insert" on storage.objects;
drop policy if exists "item_icons_select" on storage.objects;
drop function if exists public._item_icon_path_ok(text);

notify pgrst, 'reload schema';
