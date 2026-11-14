-- =============================================================================
-- R-D2 weapon blocks (20261114000600, docs/ITEM_EFFECTS.md "Weapon blocks"): authoring and validation (DM content weapons only),
-- published versions, availability (equip / unequip / attunement / Wild Shape), counters (use, rest recharge, kept when the
-- weapon stops), and the secrecy of an unidentified copy on every channel (derived, direct helper, cached reads, tl_cache,
-- resources rows = Realtime, REST, party log).
-- Runs inside the per-class harness (alice = player, bob = outsider, dm = DM of :camp).
-- =============================================================================
\set w1 f4e00000-0000-0000-0000-000000000001
\set w2 f4e00000-0000-0000-0000-000000000002
\set w3 f4e00000-0000-0000-0000-000000000003
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'w1', :'alice', 'Blade Hero', :'camp', 5, 16, 12, 14, 10, 10, 10, 40, 40, 30),
  (:'w2', :'alice', 'Blade Friend', :'camp', 5, 14, 12, 12, 12, 12, 12, 30, 30, 30),
  (:'w3', :'alice', 'Blade Druid', :'camp', 2, 10, 12, 12, 10, 16, 10, 20, 20, 30);
set constraints all immediate;                    -- the grant sync flushes at commit; this file is ONE transaction
create function tl_test.code(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
create function tl_test.msg(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create function tl_test.ref(p_content uuid) returns text language sql security definer as $$
  select v.catalog_ref from public.dm_content c join public.dm_content_versions v on v.id = c.published_version_id where c.id = p_content $$;
create function tl_test.row_of(p_char uuid, p_item text) returns uuid language sql security definer as $$
  select ii.id from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id
  where i.character_id = p_char and ii.item_id = p_item order by ii.created_at limit 1 $$;
create function tl_test.wres(p_char uuid) returns public.character_resources language sql security definer as $$
  select * from public.character_resources where character_id = p_char and resource_key like 'itemw-%' order by created_at limit 1 $$;
create function tl_test.wres_all(p_char uuid) returns text language sql security definer as $$
  select coalesce(string_agg(name || '|' || coalesce(notes, '') || '|' || resource_key || '|' || coalesce(source_id, ''), ';'), '')
  from public.character_resources where character_id = p_char and source_type = 'item' $$;
create function tl_test.wpn(p_char uuid, p_row uuid) returns jsonb language sql as $$
  select w from jsonb_array_elements(public.get_character_derived_stats(p_char) -> 'equipped_weapon_attacks') w
  where w ->> 'inventory_item_id' = p_row::text $$;
create function tl_test.pub(p_def jsonb) returns text language plpgsql as $$
declare c uuid;
begin
  c := (public.create_dm_content('item', 'c1c00000-0000-0000-0000-000000000001', p_def) ->> 'id')::uuid;
  perform public.publish_dm_content(c);
  return c::text;
end $$;
create function tl_test.cache_text(p_char uuid, p_viewer uuid) returns text language sql security definer as $$
  select coalesce(string_agg(payload::text, '|'), '') from tl_cache.character_reads where character_id = p_char and viewer = p_viewer $$;
create function tl_test.audit_text(p_camp uuid) returns text language sql security definer as $$
  select coalesce(string_agg(to_jsonb(a)::text, '|'), '') from public.campaign_audit_events a where a.campaign_id = p_camp $$;
create function tl_test.val(p_def jsonb) returns text language plpgsql as $$
declare c uuid; v jsonb;
begin
  c := (public.create_dm_content('item', 'c1c00000-0000-0000-0000-000000000001', p_def) ->> 'id')::uuid;
  v := public.validate_dm_content(c) -> 'validation';
  return case when (v ->> 'ok')::boolean then 'ok' else coalesce(v -> 'errors' ->> 0, 'error') end;
end $$;
grant all on all functions in schema tl_test to public;

-- ---- 1. authoring -------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select tl_test.pub('{"name": "Gravecutter", "definition": {"item": {"kind_id": "weapon", "category_id": "martial-melee", "is_magic": true, "rarity_id": "rare",
  "effects": [{"type": "attack_bonus", "value": 1, "activation": "equipped"}],
  "weapon_actions": [{"name": "Lacerate", "description": "A cut that makes the target bleed.", "cost": "action", "roll": "save", "save_ability": "con",
                      "damage": "1d6", "damage_type": "slashing", "uses": 1, "recharge": "short_rest"},
                     {"name": "Pommel Strike", "description": "A blow with the pommel.", "cost": "bonus_action", "roll": "attack", "damage": "1d4", "damage_type": "bludgeoning"}],
  "weapon_special": [{"name": "Keen Edge", "text": "The blade never dulls.", "effect": 1}],
  "weapon_conditions": [{"condition": "Bleeding", "applies_on": "action", "save_ability": "con", "duration": "2 turns", "text": "2 slashing damage each turn"},
                        {"condition": "prone", "applies_on": "hit", "save_ability": "str", "dc": 13}]},
  "stats": {"weapon": {"weapon_group": "martial", "damage_dice": "1d8", "damage_type_id": "slashing"}},
  "hidden": {"unidentified_name": "Notched blade", "unidentified_description": "An old notched sword."}}}') as gc \gset
select tl_test.ref(:'gc') as gcr \gset
select tl_test.as_root();
select tl_test.rec('WB1 publishing writes the blocks: 2 actions (1/short rest; unlimited), a special pointing at effect 1, a custom and a catalog condition',
  (select count(*) from public.item_weapon_blocks where item_id = :'gcr') = 5
  and (select uses || recharge || roll || save_ability || dc_ability from public.item_weapon_blocks where item_id = :'gcr' and block_type = 'action' and seq = 1) = '1short_restsaveconweapon'
  and (select uses is null and roll = 'attack' and action_cost = 'bonus_action' from public.item_weapon_blocks where item_id = :'gcr' and block_type = 'action' and seq = 2)
  and (select effect_seq from public.item_weapon_blocks where item_id = :'gcr' and block_type = 'special') = 1
  and (select condition_key is null and name = 'Bleeding' and dc_ability = 'weapon' from public.item_weapon_blocks where item_id = :'gcr' and block_type = 'condition' and seq = 1)
  and (select condition_key = 'prone' and name = 'Prone' and dc = 13 and dc_ability is null from public.item_weapon_blocks where item_id = :'gcr' and block_type = 'condition' and seq = 2)
  and (select effect_type from public.item_effects where item_id = :'gcr') = 'attack_bonus');

-- ---- 2. validation ---------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select tl_test.rec('WB2 validation: blocks on a non-weapon, a save without its ability, a missing effect, an attack bonus on a ring, bad dice',
  tl_test.val('{"name": "V1", "definition": {"item": {"kind_id": "gear", "weapon_actions": [{"name": "Swing"}]}}}') like '%only apply to weapons%'
  and tl_test.val('{"name": "V2", "definition": {"item": {"kind_id": "weapon", "weapon_actions": [{"name": "Swing", "roll": "save"}]}, "stats": {"weapon": {"damage_dice": "1d6"}}}}') like '%saving throw%'
  and tl_test.val('{"name": "V3", "definition": {"item": {"kind_id": "weapon", "weapon_special": [{"name": "X", "text": "Y", "effect": 2}]}, "stats": {"weapon": {"damage_dice": "1d6"}}}}') like '%does not exist%'
  and tl_test.val('{"name": "V4", "definition": {"item": {"kind_id": "gear", "effects": [{"type": "attack_bonus", "value": 1}]}}}') like '%weapons only%'
  and tl_test.val('{"name": "V5", "definition": {"item": {"kind_id": "weapon", "weapon_actions": [{"name": "Swing", "damage": "lots"}]}, "stats": {"weapon": {"damage_dice": "1d6"}}}}') like '%1d6%'
  and tl_test.val('{"name": "V6", "definition": {"item": {"kind_id": "weapon", "weapon_actions": [{"name": "Swing", "uses": 2}], "weapon_conditions": [{"condition": "Dazed", "dc": 12}]}, "stats": {"weapon": {"damage_dice": "1d6"}}}}') like '%saving throw ability%'
  and tl_test.val('{"name": "V7", "definition": {"item": {"kind_id": "weapon", "weapon_actions": [{"name": "Swing", "uses": 2}]}, "stats": {"weapon": {"damage_dice": "1d6"}}}}') = 'ok');
select tl_test.rec('WB3 only DM content weapons: personal homebrew (hb-) with weapon actions is refused even for a DM (42501)',
  tl_test.msg(format('select public.create_homebrew_item(gen_random_uuid(), %L, %L)', '{"name": "My Blade", "kind_id": "weapon", "weapon_actions": [{"name": "Lacerate"}]}',
    '{"weapon": {"damage_dice": "1d6"}}')) like '%made in DM Space%'
  and tl_test.code(format('select public.create_homebrew_item(gen_random_uuid(), %L, %L)', '{"name": "My Blade", "kind_id": "weapon", "weapon_actions": [{"name": "Lacerate"}]}',
    '{"weapon": {"damage_dice": "1d6"}}')) = '42501');
select tl_test.as_user(:'dm');
select tl_test.rec('WB4 a published version never changes its blocks in place (update_homebrew_item)',
  tl_test.msg(format('select public.update_homebrew_item(%L, %L, %L)', :'gcr', '{"name": "Gravecutter", "kind_id": "weapon", "weapon_actions": [{"name": "Other"}]}',
    '{"weapon": {"damage_dice": "1d8"}}')) like '%make a new version%');
select tl_test.rec('WB6 no REST / Realtime: no privilege for anon / authenticated, not in the publication',
  not has_table_privilege('authenticated', 'public.item_weapon_blocks', 'select') and not has_table_privilege('anon', 'public.item_weapon_blocks', 'select')
  and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'item_weapon_blocks'));

-- ---- 3. equip / use / rest / unequip -----------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_give_item(:'gcr', array[:'w1']::uuid[], 1, true);
select tl_test.row_of(:'w1', :'gcr') as r1 \gset
select tl_test.as_user(:'alice');
select tl_test.rec('WB7 carried, not equipped: no card, no counter', tl_test.wpn(:'w1', :'r1') is null and tl_test.wres(:'w1') is null);
select public.equip_item(:'r1', 'main_hand', true);
select tl_test.wpn(:'w1', :'r1') as wp \gset
select tl_test.rec('WB8 equipped: the card carries the blocks (DC 8 + 3 prof + 3 STR = 14, Pommel Strike to hit = weapon attack), the counter is active',
  jsonb_array_length(:'wp'::jsonb -> 'weapon_blocks' -> 'actions') = 2
  and (:'wp'::jsonb -> 'weapon_blocks' -> 'actions' -> 0 ->> 'save_dc')::int = 14
  and (:'wp'::jsonb -> 'weapon_blocks' -> 'actions' -> 1 ->> 'attack_bonus')::int = (:'wp'::jsonb ->> 'attack_bonus')::int
  and (:'wp'::jsonb -> 'weapon_blocks' -> 'conditions' -> 1 ->> 'save_dc')::int = 13
  and (:'wp'::jsonb -> 'weapon_blocks' -> 'special' -> 0 -> 'effect' ->> 'type') = 'attack_bonus'
  and (tl_test.wres(:'w1')).active and (tl_test.wres(:'w1')).recharge = 'short_rest'
  and (:'wp'::jsonb -> 'weapon_blocks' -> 'actions' -> 0 ->> 'resource_key') = 'r:' || (tl_test.wres(:'w1')).id
  and (:'wp'::jsonb -> 'weapon_blocks' -> 'actions' -> 1 ->> 'resource_key') is null
  and exists (select 1 from jsonb_array_elements(public.get_character_resources(:'w1') -> 'resources') x
              where x ->> 'key' = 'r:' || (tl_test.wres(:'w1')).id and (x ->> 'remaining')::int = 1));
select public.expend_character_resource(:'w1', 'r:' || (tl_test.wres(:'w1')).id, 1) ->> 'remaining' as left1 \gset
select tl_test.rec('WB9 Use spends the one use; a second use is refused', :'left1'::int = 0
  and tl_test.code(format('select public.expend_character_resource(%L, %L, 1)', :'w1', 'r:' || (tl_test.wres(:'w1')).id)) <> 'ok');
select public.unequip_item(:'r1');
select tl_test.rec('WB10 unequipped: the card is gone, the counter inactive and still spent',
  tl_test.wpn(:'w1', :'r1') is null and not (tl_test.wres(:'w1')).active and (tl_test.wres(:'w1')).expended = 1);
select public.equip_item(:'r1', 'main_hand', true);
select tl_test.rec('WB11 equipped again: the same counter, still spent (no refill)', (tl_test.wres(:'w1')).active and (tl_test.wres(:'w1')).expended = 1);
select public.short_rest_character(:'w1', gen_random_uuid());
select tl_test.rec('WB12 a short rest recharges it', (tl_test.wres(:'w1')).expended = 0);

-- ---- 4. Wild Shape and attunement ----------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_give_item(:'gcr', array[:'w3']::uuid[], 1, true);
select tl_test.as_user(:'alice');
select public.set_character_class(:'w3', 'druid-phb', 2, null, true);
select tl_test.row_of(:'w3', :'gcr') as r3 \gset
select public.equip_item(:'r3', 'main_hand', true);
select (tl_test.wres(:'w3')).active as ws_before \gset
select public.start_transformation(:'w3', 'wolf', '{"equipment": {"mode": "merge"}}');
select tl_test.wpn(:'w3', :'r3') is null as ws_card_gone, not (tl_test.wres(:'w3')).active as ws_res_off \gset
select public.end_transformation(:'w3');
select tl_test.rec('WB13 Wild Shape: the merged weapon has no card and its counter is inactive in the form; both are back after it',
  :'ws_before'::boolean and :'ws_card_gone'::boolean and :'ws_res_off'::boolean
  and tl_test.wpn(:'w3', :'r3') ? 'weapon_blocks' and (tl_test.wres(:'w3')).active);
select tl_test.as_user(:'dm');
select tl_test.pub('{"name": "Oathblade", "definition": {"item": {"kind_id": "weapon", "category_id": "martial-melee", "is_magic": true, "rarity_id": "rare", "requires_attunement": true,
  "weapon_actions": [{"name": "Oath Strike", "cost": "action", "uses": 1, "recharge": "long_rest"}]},
  "stats": {"weapon": {"weapon_group": "martial", "damage_dice": "1d8", "damage_type_id": "slashing"}}}}') as ob \gset
select public.dm_give_item(tl_test.ref(:'ob'), array[:'w3']::uuid[], 1, true);
select tl_test.as_user(:'alice');
select tl_test.row_of(:'w3', tl_test.ref(:'ob')) as ro \gset
select public.equip_item(:'ro', 'off_hand', true);
select not exists (select 1 from public.character_resources where character_id = :'w3' and resource_key like 'itemw-' || replace(:'ro', '-', '') || '-%' and active) as att_none,
       (tl_test.wpn(:'w3', :'ro') -> 'weapon_blocks' -> 'actions' -> 0 ->> 'available')::boolean as att_avail \gset
select public.attune_item(:'ro');
select tl_test.rec('WB14 an attunement weapon: equipped but not attuned = no counter (shown as not available); attuned = counter',
  :'att_none'::boolean and not :'att_avail'::boolean
  and exists (select 1 from public.character_resources where character_id = :'w3' and resource_key like 'itemw-' || replace(:'ro', '-', '') || '-%' and active)
  and (tl_test.wpn(:'w3', :'ro') -> 'weapon_blocks' -> 'actions' -> 0 ->> 'available')::boolean);

-- ---- 5. secrecy: an unidentified copy next to an identified one (the catalog row is readable, the copy is not known) ----------------
select tl_test.as_user(:'dm');
select public.dm_give_item(:'gcr', array[:'w2']::uuid[], 1, true);
select tl_test.row_of(:'w2', :'gcr') as rk \gset
select public.dm_give_item(:'gcr', array[:'w2']::uuid[], 1, false);
select ii.id as ru from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id
  join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
  where i.character_id = :'w2' and k.state <> 'identified' limit 1 \gset
select tl_test.as_user(:'alice');
select public.equip_item(:'rk', 'main_hand', true);
select public.equip_item(:'ru', 'off_hand', true);
select tl_test.as_user(:'dm');
select tl_test.wpn(:'w2', :'ru') ? 'weapon_blocks' as dm_sees \gset
select tl_test.as_user(:'alice');
select tl_test.wpn(:'w2', :'ru')::text as pu, tl_test.wpn(:'w2', :'rk')::text as pk,
       public._character_weapon_blocks(:'w2', array[:'ru']::uuid[])::text as helper_u,
       public.get_character_resources(:'w2')::text as pres \gset
select public.get_character_reads(:'w2', array['get_character_derived_stats', 'get_character_resources']) ->> 'reads' as rd1 \gset
select public.get_character_reads(:'w2', array['get_character_derived_stats', 'get_character_resources']) ->> 'reads' as rd2 \gset
select tl_test.rec('WB15 player: the known copy shows its blocks, the unidentified copy none (derived, direct helper call); the DM sees both',
  :'pk'::jsonb ? 'weapon_blocks' and (:'pu' = '' or not (:'pu'::jsonb ? 'weapon_blocks')) and :'helper_u' = '{}' and :'dm_sees'::boolean);
select tl_test.rec('WB16 cached reads (miss and hit), tl_cache rows and resources carry exactly one Lacerate (the known copy), no counter of the unknown copy',
  (length(:'rd1') - length(replace(:'rd1', 'A cut that makes', ''))) / length('A cut that makes') = 1
  and (length(:'rd2') - length(replace(:'rd2', 'A cut that makes', ''))) / length('A cut that makes') = 1
  and position(replace(:'ru', '-', '') in tl_test.wres_all(:'w2')) = 0
  and (length(:'pres') - length(replace(:'pres', 'Lacerate', ''))) / length('Lacerate') = 1
  and (length(tl_test.cache_text(:'w2', :'alice')) - length(replace(tl_test.cache_text(:'w2', :'alice'), 'A cut that makes', ''))) / length('A cut that makes') <= 2);
select tl_test.as_user(:'bob');
select tl_test.rec('WB17 an outsider gets nothing from the helper', public._character_weapon_blocks(:'w2', array[:'rk', :'ru']::uuid[]) = '{}'::jsonb);
select tl_test.as_user(:'alice');
select tl_test.rec('WB18 REST as the player: the table is not readable (42501)', tl_test.code('select * from public.item_weapon_blocks') = '42501');

-- identification shows the blocks and creates the counter; lowering it again hides them and renames the counter to the disguise
select tl_test.as_user(:'dm');
select public.set_item_knowledge(:'ru', 'identified');
select tl_test.as_user(:'alice');
select tl_test.wpn(:'w2', :'ru') ? 'weapon_blocks' as idf_card,
       exists (select 1 from public.character_resources where character_id = :'w2' and resource_key like 'itemw-' || replace(:'ru', '-', '') || '-%' and active and name like 'Lacerate%') as idf_res \gset
select tl_test.as_user(:'dm');
select public.set_item_knowledge(:'ru', 'unidentified');
select tl_test.as_user(:'alice');
select tl_test.rec('WB19 identified: blocks and counter appear; unidentified again: blocks gone, the counter inactive and named only by the disguise',
  :'idf_card'::boolean and :'idf_res'::boolean
  and (tl_test.wpn(:'w2', :'ru') is null or not (tl_test.wpn(:'w2', :'ru') ? 'weapon_blocks'))
  and exists (select 1 from public.character_resources where character_id = :'w2' and resource_key like 'itemw-' || replace(:'ru', '-', '') || '-%' and not active)
  and not exists (select 1 from public.character_resources where character_id = :'w2' and resource_key like 'itemw-' || replace(:'ru', '-', '') || '-%'
                  and ((name || coalesce(notes, '')) like '%Lacerate%' or (name || coalesce(notes, '')) like '%Gravecutter%')));
select tl_test.rec('WB20 party log: no line names an action or the weapon''s blocks', position('Lacerate' in tl_test.audit_text(:'camp')) = 0
  and position('Pommel' in tl_test.audit_text(:'camp')) = 0);

-- ---- 6. versions (last: publishing a new version archives the old one for new assignments) ----------------------------------
select tl_test.as_user(:'dm');
select public.new_dm_content_version(:'gc');
select public.save_dm_content(:'gc', '{"definition": {"item": {"kind_id": "weapon", "category_id": "martial-melee", "is_magic": true, "rarity_id": "rare",
  "weapon_actions": [{"name": "Lacerate", "cost": "action", "uses": 2, "recharge": "long_rest"}]}, "stats": {"weapon": {"weapon_group": "martial", "damage_dice": "1d8", "damage_type_id": "slashing"}}}}');
select public.publish_dm_content(:'gc');
select tl_test.as_root();
select tl_test.rec('WB5 a new version has its own blocks; the old version keeps its five',
  tl_test.ref(:'gc') <> :'gcr' and (select count(*) from public.item_weapon_blocks where item_id = tl_test.ref(:'gc')) = 1
  and (select count(*) from public.item_weapon_blocks where item_id = :'gcr') = 5);
