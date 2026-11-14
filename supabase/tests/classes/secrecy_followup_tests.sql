-- =============================================================================
-- R-D4 secrecy follow-up (20261114000800, review v35): F1 (no true name / item id of a disguised copy in copy-level modifier
-- effects, infusion lists and the Wild Shape sheet), F3 (a masked proficiency object carries no proficiency_id / matched_by).
-- The numbers stay the same; the DM still sees the truth. F2 (locks) is covered by item_knowledge_transfer_concurrency_test.sh.
-- Runs inside the per-class harness (alice = player, dm = DM of :camp).
-- =============================================================================
\set s1 f5e10000-0000-0000-0000-000000000001
\set s2 f5e10000-0000-0000-0000-000000000002
\set s3 f5e10000-0000-0000-0000-000000000003
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'s1', :'alice', 'Secret Druid', :'camp', 2, 16, 12, 14, 10, 16, 10, 20, 20, 30),
  (:'s2', :'alice', 'Secret Knower', :'camp', 5, 16, 12, 14, 10, 10, 10, 40, 40, 30),
  (:'s3', :'alice', 'Secret Artificer', :'camp', 2, 10, 14, 14, 16, 10, 8, 20, 20, 30);
set constraints all immediate;                    -- the grant sync flushes at commit; this file is ONE transaction
create function tl_test.ref(p_content uuid) returns text language sql security definer as $$
  select v.catalog_ref from public.dm_content c join public.dm_content_versions v on v.id = c.published_version_id where c.id = p_content $$;
create function tl_test.pub(p_def jsonb) returns text language plpgsql as $$
declare c uuid;
begin
  c := (public.create_dm_content('item', 'c1c00000-0000-0000-0000-000000000001', p_def) ->> 'id')::uuid;
  perform public.publish_dm_content(c);
  return c::text;
end $$;
create function tl_test.unident_row(p_char uuid, p_item text) returns uuid language sql security definer as $$
  select ii.id from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id
  join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
  where i.character_id = p_char and ii.item_id = p_item and k.state <> 'identified' order by ii.created_at limit 1 $$;
create function tl_test.wrow(p_d jsonb, p_row uuid) returns jsonb language sql as $$
  select w from jsonb_array_elements(p_d -> 'equipped_weapon_attacks') w where w ->> 'inventory_item_id' = p_row::text $$;
-- the numbers of a derived payload: AC, the weapon's attack / damage, every effect's value and applied flag (labels left out)
create function tl_test.nums(p_d jsonb, p_row uuid) returns text language sql as $$
  select concat_ws('|', p_d -> 'armor_class' ->> 'value', tl_test.wrow(p_d, p_row) ->> 'attack_bonus', tl_test.wrow(p_d, p_row) ->> 'damage',
    (select string_agg(concat_ws(':', e ->> 'effect_type', e ->> 'value', e ->> 'applied', e ->> 'source_id'), ',' order by e ->> 'source_id', e ->> 'effect_type', e ->> 'value')
       from jsonb_array_elements(coalesce(p_d -> 'effects', '[]'::jsonb) || coalesce(p_d -> 'inactive_effects', '[]'::jsonb)) e)) $$;
grant all on all functions in schema tl_test to public;

-- ---- authored items: a magic weapon and armor (disguised), a mundane weapon (disguised, can take an infusion) -----------------
select tl_test.as_user(:'dm');
select tl_test.ref(tl_test.pub('{"name": "Veritas Blade", "definition": {"item": {"kind_id": "weapon", "category_id": "martial-melee", "is_magic": true, "rarity_id": "rare"},
  "stats": {"weapon": {"weapon_group": "martial", "damage_dice": "1d8", "damage_type_id": "slashing"}},
  "hidden": {"unidentified_name": "Plain sword", "unidentified_description": "A plain sword."}}}')::uuid) as wpn \gset
select tl_test.ref(tl_test.pub('{"name": "Veritas Mail", "definition": {"item": {"kind_id": "armor", "category_id": "medium-armor", "is_magic": true, "rarity_id": "rare"},
  "stats": {"armor": {"base_ac": 14, "dex_modifier_mode": "capped", "dex_cap": 2}},
  "hidden": {"unidentified_name": "Dull mail", "unidentified_description": "Scratched mail."}}}')::uuid) as arm \gset
select tl_test.ref(tl_test.pub('{"name": "Veritas Club", "definition": {"item": {"kind_id": "weapon", "category_id": "simple-melee", "is_magic": false, "rarity_id": "common"},
  "stats": {"weapon": {"weapon_group": "simple", "damage_dice": "1d4", "damage_type_id": "bludgeoning"}},
  "hidden": {"unidentified_name": "Bent stick", "unidentified_description": "A stick."}}}')::uuid) as club \gset
-- the player's other character knows all three (the catalog rows are readable for alice); s1 / s3 get disguised copies
select public.dm_give_item(:'wpn', array[:'s2']::uuid[], 1, true);
select public.dm_give_item(:'arm', array[:'s2']::uuid[], 1, true);
select public.dm_give_item(:'club', array[:'s2']::uuid[], 1, true);
select public.dm_give_item(:'wpn', array[:'s1']::uuid[], 1, false);
select public.dm_give_item(:'arm', array[:'s1']::uuid[], 1, false);
select public.dm_give_item(:'club', array[:'s3']::uuid[], 1, false);
select tl_test.unident_row(:'s1', :'wpn') as uw, tl_test.unident_row(:'s1', :'arm') as ua, tl_test.unident_row(:'s3', :'club') as uc \gset
-- a copy-level modifier on the disguised weapon (the DM made it +1)
select tl_test.as_root();
insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (:'uw', 'weapon-plus-1');
select tl_test.as_user(:'alice');
select tl_test.setc(:'s1', 'druid-phb', 2);       -- light / medium armor proficiency (class), no martial weapons
select public.equip_item(:'uw', 'main_hand', true);
select public.equip_item(:'ua', 'armor', true);
select (select count(*) from public.items where id in (:'wpn', :'arm', :'club')) as visible_rows \gset
select tl_test.rec('S1 setup: the catalog rows are readable for the player, the copies are disguised, the modifier is on the weapon copy',
  :'visible_rows'::int = 3 and :'uw' <> '' and :'ua' <> '' and :'uc' <> ''
  and exists (select 1 from public.inventory_item_modifiers where inventory_item_id = :'uw'));

-- ---- F1 _character_effects / F3 ----------------------------------------------------------------------------------------------
select public.get_character_derived_stats(:'s1')::text as pd \gset
select tl_test.as_user(:'dm');
select public.get_character_derived_stats(:'s1')::text as dd \gset
select tl_test.as_user(:'alice');
select tl_test.rec('S2 F1 player derived: the modifier effect is labelled with the disguise and has no item id',
  exists (select 1 from jsonb_array_elements(:'pd'::jsonb -> 'effects') e
          where e ->> 'source_id' = :'uw' and e ->> 'source_name' = 'Plain sword (Weapon +1)' and e ->> 'item_id' is null
            and e ->> 'effect_type' = 'attack_bonus'),
  left(:'pd', 300));
select tl_test.rec('S3 F1 player derived: no true name and no catalog id anywhere (effects, breakdowns, weapons, armor)',
  position('Veritas' in :'pd') = 0 and position(:'wpn' in :'pd') = 0 and position(:'arm' in :'pd') = 0);
select tl_test.rec('S4 F1 DM derived: the true label and item id of the modifier effect',
  exists (select 1 from jsonb_array_elements(:'dd'::jsonb -> 'effects') e
          where e ->> 'source_id' = :'uw' and e ->> 'source_name' = 'Veritas Blade (Weapon +1)' and e ->> 'item_id' = :'wpn'));
select tl_test.rec('S5 F1 the numbers are the same for the player and the DM (AC, attack, damage, every effect value / applied flag)',
  tl_test.nums(:'pd'::jsonb, :'uw') = tl_test.nums(:'dd'::jsonb, :'uw') and (tl_test.wrow(:'pd'::jsonb, :'uw') ->> 'attack_bonus') is not null,
  tl_test.nums(:'pd'::jsonb, :'uw') || ' / ' || tl_test.nums(:'dd'::jsonb, :'uw'));
select tl_test.rec('S6 F3 masked proficiency objects (weapon, armor) carry no item_id, proficiency_id or matched_by; the DM''s armor proficiency keeps matched_by',
  not (tl_test.wrow(:'pd'::jsonb, :'uw') -> 'proficiency' ?| array['item_id', 'proficiency_id', 'matched_by'])
  and (tl_test.wrow(:'pd'::jsonb, :'uw') -> 'proficiency' ? 'proficient')
  and not (:'pd'::jsonb -> 'armor' -> 'proficiency' ?| array['item_id', 'proficiency_id', 'matched_by'])
  and (:'pd'::jsonb -> 'armor' -> 'proficiency' ->> 'proficient')::boolean
  and (:'dd'::jsonb -> 'armor' -> 'proficiency' ? 'matched_by'),
  coalesce((tl_test.wrow(:'pd'::jsonb, :'uw') -> 'proficiency')::text, 'null'));

-- ---- F1 get_character_infusions ------------------------------------------------------------------------------------------------
select tl_test.setc(:'s3', 'artificer-tce', 2);
select tl_test.choose(:'s3', 'artificer', 'artificer-tce-u2-infuse-item', 'artificer-infuse-item-tce-infusions',
                      '{enhanced-weapon,enhanced-arcane-focus,replicate-magic-item,homunculus-servant}');
select public.get_character_infusions(:'s3')::text as pi0 \gset
select public.apply_infusion(:'s3', 'enhanced-weapon', :'uc');
select public.get_character_infusions(:'s3')::text as pi1 \gset
select public.get_character_derived_stats(:'s3')::text as pd3 \gset
select tl_test.as_user(:'dm');
select public.get_character_infusions(:'s3')::text as di1 \gset
select public.get_character_derived_stats(:'s3')::text as dd3 \gset
select tl_test.as_user(:'alice');
select tl_test.rec('S7 F1 infusion candidates: the disguised copy is offered under its disguise',
  exists (select 1 from jsonb_array_elements(:'pi0'::jsonb -> 'choices' -> 0 -> 'known') k, jsonb_array_elements(k -> 'candidates') c
          where c ->> 'inventory_item_id' = :'uc' and c ->> 'name' = 'Bent stick')
  and position('Veritas' in :'pi0') = 0, left(:'pi0', 300));
select tl_test.rec('S8 F1 active infusion on the disguised copy: item_name is the disguise; no true name in the infusions or the derived read',
  exists (select 1 from jsonb_array_elements(:'pi1'::jsonb -> 'active') a where a ->> 'inventory_item_id' = :'uc' and a ->> 'item_name' = 'Bent stick')
  and position('Veritas' in :'pi1') = 0 and position('Veritas' in :'pd3') = 0 and position(:'club' in :'pd3') = 0
  and exists (select 1 from jsonb_array_elements(:'pd3'::jsonb -> 'effects' || coalesce(:'pd3'::jsonb -> 'inactive_effects', '[]'::jsonb)) e
              where e ->> 'source_id' = :'uc' and e ->> 'source_name' like 'Bent stick (%' and e ->> 'item_id' is null));
select tl_test.rec('S9 F1 the DM sees the true item name of the infused copy (infusions and derived)',
  exists (select 1 from jsonb_array_elements(:'di1'::jsonb -> 'active') a where a ->> 'inventory_item_id' = :'uc' and a ->> 'item_name' = 'Veritas Club')
  and exists (select 1 from jsonb_array_elements(:'dd3'::jsonb -> 'effects' || coalesce(:'dd3'::jsonb -> 'inactive_effects', '[]'::jsonb)) e
              where e ->> 'source_id' = :'uc' and e ->> 'source_name' like 'Veritas Club (%' and e ->> 'item_id' = :'club'));

-- ---- F1 _wild_shape_sheet ------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.set_wild_shape_settings(:'s1', 'warn');
select tl_test.as_user(:'alice');
select public.start_transformation(:'s1', 'wolf',
  jsonb_build_object('equipment', jsonb_build_object('mode', 'merge', 'items', jsonb_build_object(:'ua', 'wear', :'uw', 'drop'))));
select public.get_character_derived_stats(:'s1') ->> 'wild_shape' as pws \gset
select public.get_character_transformation(:'s1')::text as ptr \gset
select tl_test.as_user(:'dm');
select public.get_character_derived_stats(:'s1') ->> 'wild_shape' as dws \gset
select tl_test.as_user(:'alice');
select tl_test.rec('S10 F1 player Wild Shape sheet: worn armor label, equipment and dropped item carry the disguise; no true name anywhere',
  :'pws' is not null and position('Dull mail worn by the form' in :'pws') > 0
  and exists (select 1 from jsonb_array_elements(:'pws'::jsonb -> 'equipment') e where e ->> 'inventory_item_id' = :'ua' and e ->> 'name' = 'Dull mail')
  and exists (select 1 from jsonb_array_elements(:'pws'::jsonb -> 'equipment') e where e ->> 'inventory_item_id' = :'uw' and e ->> 'name' = 'Plain sword')
  and position('Veritas' in :'pws') = 0 and position('Veritas' in :'ptr') = 0,
  left(coalesce(:'pws', 'null'), 300));
select tl_test.rec('S11 F1 DM Wild Shape sheet: the true names; same AC as the player''s',
  position('Veritas Mail worn by the form' in :'dws') > 0 and position('Veritas Blade' in :'dws') > 0
  and :'dws'::jsonb -> 'armor_class' ->> 'value' = :'pws'::jsonb -> 'armor_class' ->> 'value');
