-- =============================================================================
-- R-D1 item effects (20261114000500, docs/ITEM_EFFECTS.md): effect kinds and activations, stacking, permanent effects of a used
-- consumable (once per request, caps, revert), spell grants (equip / attune / transfer sync, counters, rests), DM-only authoring and
-- validation, versions, and the secrecy of an unidentified item (labels on every read channel).
-- Runs inside the per-class harness (alice = player, bob = outsider, dm = DM of :camp).
-- =============================================================================
\set e1 f3e00000-0000-0000-0000-000000000001
\set e2 f3e00000-0000-0000-0000-000000000002
\set e3 f3e00000-0000-0000-0000-000000000003
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'e1', :'alice', 'Effect Hero', :'camp', 5, 14, 14, 14, 10, 19, 10, 40, 40, 30),
  (:'e2', :'alice', 'Effect Friend', :'camp', 5, 12, 12, 12, 12, 12, 12, 30, 30, 30),
  (:'e3', :'alice', 'Effect Sage', :'camp', 5, 10, 10, 10, 10, 20, 10, 30, 30, 30);
create function tl_test.code(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
create function tl_test.msg(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create function tl_test.ref(p_content uuid) returns text language sql security definer as $$
  select v.catalog_ref from public.dm_content c join public.dm_content_versions v on v.id = c.published_version_id where c.id = p_content $$;
create function tl_test.row_of(p_char uuid, p_item text) returns uuid language sql security definer as $$
  select ii.id from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id
  where i.character_id = p_char and ii.item_id = p_item order by ii.created_at limit 1 $$;
create function tl_test.src(p_char uuid) returns int language sql security definer as $$
  select count(*)::int from public.character_spellcasting_sources where character_id = p_char and item_grant_key is not null $$;
create function tl_test.ires(p_char uuid) returns public.character_resources language sql security definer as $$
  select * from public.character_resources where character_id = p_char and source_type = 'item' order by created_at limit 1 $$;
create function tl_test.grant_of(p_char uuid, p_spell text) returns jsonb language sql as $$
  select g from jsonb_array_elements(public.get_character_spellbook(p_char) -> 'spells') s, jsonb_array_elements(s -> 'grants') g
  where s ->> 'id' = p_spell and g ->> 'source_type' = 'item' limit 1 $$;
create function tl_test.pub(p_def jsonb) returns text language plpgsql as $$
declare c uuid;
begin
  c := (public.create_dm_content('item', 'c1c00000-0000-0000-0000-000000000001', p_def) ->> 'id')::uuid;
  perform public.publish_dm_content(c);
  return c::text;
end $$;
create function tl_test.pe(p_char uuid) returns setof public.character_permanent_effects language sql security definer as $$
  select * from public.character_permanent_effects where character_id = p_char $$;
create function tl_test.cache_text(p_char uuid, p_viewer uuid) returns text language sql security definer as $$
  select coalesce(string_agg(payload::text, '|'), '') from tl_cache.character_reads where character_id = p_char and viewer = p_viewer $$;
grant all on all functions in schema tl_test to public;

-- ---- 1. effect kinds -------------------------------------------------------------------------------------------------------------
select tl_test.rec('IE1 item_effects takes initiative_bonus, a numeric skill_bonus and the permanent activation; bad rows are refused',
  tl_test.code($$insert into public.item_effects (item_id, seq, effect_type, value, target, activation) values ('longsword', 21, 'initiative_bonus', 1, null, 'equipped')$$) = 'ok'
  and tl_test.code($$insert into public.item_effects (item_id, seq, effect_type, value, target, activation) values ('longsword', 22, 'skill_bonus', 2, 'perception', 'equipped')$$) = 'ok'
  and tl_test.code($$insert into public.item_effects (item_id, seq, effect_type, value, target, activation) values ('longsword', 23, 'initiative_bonus', 1, 'dex', 'equipped')$$) = '22023'
  and tl_test.code($$insert into public.item_effects (item_id, seq, effect_type, value, target, activation) values ('longsword', 24, 'skill_bonus', 2, 'cooking', 'equipped')$$) = '22023'
  and tl_test.code($$insert into public.item_effects (item_id, seq, effect_type, value, target, activation, max_score) values ('longsword', 25, 'ability_bonus', 1, 'str', 'equipped', 22)$$) = '22023'
  and tl_test.code($$insert into public.item_effects (item_id, seq, effect_type, value, target, activation, stacking) values ('longsword', 26, 'ability_override', 19, 'str', 'permanent', 'override')$$) = '22023');
delete from public.item_effects where item_id = 'longsword' and seq in (21, 22);

-- ---- 2. the DM authors items in DM Space (validation, publish, versions) ----------------------------------------------------------
select tl_test.as_user(:'dm');
select tl_test.pub('{"name": "Amulet of the Grave", "definition": {"item": {"kind_id": "magic_item", "is_magic": true, "rarity_id": "uncommon",
  "requires_attunement": true,
  "effects": [{"type": "save_bonus", "value": 1, "activation": "attuned"}, {"type": "initiative_bonus", "value": 2, "activation": "attuned"},
              {"type": "skill_bonus", "target": "religion", "value": 3, "activation": "attuned"}],
  "spells": [{"spell": "speak-with-dead-phb", "casting": "per_rest", "uses": 1, "recharge": "long_rest", "activation": "attuned", "ability": "wis"}]}}}') as amulet \gset
select tl_test.pub('{"name": "Hag''s Hair", "definition": {"item": {"kind_id": "gear", "is_consumable": true, "stackable": true,
  "effects": [{"type": "ability_bonus", "target": "wis", "value": 1, "activation": "permanent"}],
  "spells": [{"spell": "light-phb", "casting": "at_will", "activation": "permanent"}]}}}') as hair \gset
select tl_test.pub('{"name": "Tome of Deep Thought", "definition": {"item": {"kind_id": "gear", "is_consumable": true,
  "effects": [{"type": "ability_bonus", "target": "wis", "value": 2, "activation": "permanent", "max": 22}]}}}') as tome \gset
select tl_test.pub('{"name": "Lucky Boots", "definition": {"item": {"kind_id": "magic_item", "category_id": "wondrous-item", "is_magic": true, "rarity_id": "common",
  "effects": [{"type": "speed_bonus", "value": 10, "activation": "equipped"}, {"type": "skill_bonus", "target": "acrobatics", "value": 1, "activation": "equipped"}],
  "spells": [{"spell": "shield-phb", "casting": "spell_slots", "activation": "owned"}]}}}') as boots \gset
select tl_test.ref(:'amulet') as amu, tl_test.ref(:'hair') as hh, tl_test.ref(:'tome') as tom, tl_test.ref(:'boots') as bts \gset
select tl_test.rec('IE2 publishing writes the effects and granted spells to the catalog rows of the version',
  (select count(*) from public.item_effects where item_id = :'amu') = 3
  and (select count(*) from public.item_spell_grants where item_id = :'amu' and casting = 'per_rest' and uses = 1 and recharge = 'long_rest') = 1
  and (select activation from public.item_effects where item_id = :'hh') = 'permanent'
  and (select max_score from public.item_effects where item_id = :'tom') = 22
  and (select count(*) from public.item_spell_grants where item_id = :'bts' and casting = 'spell_slots' and activation = 'owned') = 1);
select (public.create_dm_content('item', :'camp', '{"name": "Bad Thing", "definition": {"item": {"kind_id": "gear",
  "effects": [{"type": "ability_bonus", "target": "str", "value": 1, "activation": "permanent"}]}}}') ->> 'id') as bad \gset
select public.validate_dm_content(:'bad') -> 'validation' as bv \gset
select (public.create_dm_content('item', :'camp', '{"name": "Bad Ring", "definition": {"item": {"kind_id": "gear", "requires_attunement": true, "is_magic": true, "rarity_id": "rare",
  "effects": [{"type": "ac_bonus", "value": 1, "activation": "equipped"}], "spells": [{"spell": "no-such-spell"}]}}}') ->> 'id') as bad2 \gset
select public.validate_dm_content(:'bad2') -> 'validation' as bv2 \gset
select tl_test.rec('IE3 validation explains a permanent effect on a non-consumable, attunement items and unknown spells',
  not (:'bv'::jsonb ->> 'ok')::boolean and :'bv'::text like '%make the item consumable%'
  and not (:'bv2'::jsonb ->> 'ok')::boolean and :'bv2'::text like '%requires attunement%', :'bv'::text || :'bv2'::text);
select tl_test.as_root();
select tl_test.rec('IE4a the homebrew writer itself refuses effects and spells on a non-DM-content item (player homebrew ids)',
  tl_test.code($$select public._write_homebrew('hb-ie4', '{"name": "Cheat Ring", "kind_id": "gear", "effects": [{"type": "ac_bonus", "value": 5}]}', '{}', true)$$) = '42501'
  and tl_test.code($$select public._write_homebrew('hb-ie4', '{"name": "Cheat Book", "kind_id": "gear", "spells": [{"spell": "light-phb"}]}', '{}', true)$$) = '42501');
select tl_test.as_user(:'alice');
select tl_test.rec('IE4 a player cannot author effects: DM content refuses players, player homebrew refuses effects and spells',
  tl_test.code(format('select public.create_dm_content(%L, %L, %L)', 'item', :'camp', '{"name": "Player Amulet"}')) = 'TLDMO'
  and tl_test.code($$select public.create_homebrew_item(gen_random_uuid(), '{"name": "Cheat Ring", "kind_id": "gear", "effects": [{"type": "ac_bonus", "value": 5}]}')$$) <> 'ok'
  and tl_test.code($$select public.create_homebrew_item(gen_random_uuid(), '{"name": "Cheat Book", "kind_id": "gear", "spells": [{"spell": "light-phb"}]}')$$) <> 'ok'
  and tl_test.code($$insert into public.item_spell_grants (item_id, seq, spell_version_id, casting, activation) values ('longsword', 1, 'light-phb', 'at_will', 'owned')$$) = '42501'
  and tl_test.code('select * from public.character_permanent_effects') = '42501');

-- ---- 3. activations: attuned (amulet), equipped (boots), owned (spell) -------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_give_item(:'amu', array[:'e1']::uuid[], 1, true);
select public.dm_give_item(:'bts', array[:'e1']::uuid[], 1, true);
select tl_test.as_user(:'alice');
select tl_test.row_of(:'e1', :'amu') as am_row, tl_test.row_of(:'e1', :'bts') as bt_row \gset
select tl_test.d(:'e1') as d0 \gset
select tl_test.rec('IE5 carried but not attuned: no bonus, the effects are listed as not counted (not_attuned)',
  (:'d0'::jsonb -> 'saving_throws' -> 'wis' ->> 'item_bonus')::int = 0
  and (:'d0'::jsonb -> 'saving_throws' -> 'wis' -> 'inactive_effects' -> 0 ->> 'inactive_reason') = 'not_attuned'
  and (:'d0'::jsonb -> 'initiative' -> 'inactive_effects' -> 0 ->> 'source_name') = 'Amulet of the Grave'
  and coalesce((:'d0'::jsonb -> 'skills' -> 'religion' ->> 'item_bonus')::int, 0) = 0
  and tl_test.src(:'e1') = 1);                                    -- the boots' Shield (owned) is granted already
select public.attune_item(:'am_row');
select tl_test.d(:'e1') as d1 \gset
select tl_test.rec('IE6 attuned: +1 to every save, +2 initiative, +3 Religion, each with its source',
  (:'d1'::jsonb -> 'saving_throws' -> 'con' ->> 'item_bonus')::int = 1
  and (:'d1'::jsonb -> 'saving_throws' -> 'con' -> 'item_sources' -> 0 ->> 'source_name') = 'Amulet of the Grave'
  and (:'d1'::jsonb -> 'initiative' ->> 'bonus')::int = 2 and (:'d1'::jsonb -> 'initiative' -> 'sources') ? 'Amulet of the Grave'
  and (:'d1'::jsonb -> 'skills' -> 'religion' ->> 'item_bonus')::int = 3
  and (:'d1'::jsonb -> 'skills' -> 'religion' -> 'item_sources' -> 0 ->> 'value')::int = 3);
select tl_test.rec('IE7 the attuned amulet grants Speak with Dead once per long rest (source, spell, counter 1 of 1)',
  tl_test.src(:'e1') = 2 and (tl_test.grant_of(:'e1', 'speak-with-dead-phb') ->> 'uses')::int = 1
  and (tl_test.grant_of(:'e1', 'speak-with-dead-phb') ->> 'remaining')::int = 1
  and tl_test.grant_of(:'e1', 'speak-with-dead-phb') ->> 'recharge' = 'long_rest'
  and tl_test.grant_of(:'e1', 'speak-with-dead-phb') ->> 'source_label' = 'Amulet of the Grave'
  and not (tl_test.grant_of(:'e1', 'speak-with-dead-phb') ->> 'uses_spell_slot')::boolean
  and (tl_test.ires(:'e1')).active and (tl_test.ires(:'e1')).recharge = 'long_rest');
select tl_test.rec('IE7b the counter is also a resource of the character (Play tab): "Free cast: Speak with Dead"',
  exists (select 1 from jsonb_array_elements(public.get_character_resources(:'e1') -> 'resources') r where r ->> 'name' = 'Free cast: Speak with Dead'),
  public.get_character_resources(:'e1')::text);
select tl_test.rec('IE8 a spell with the character''s slots (Shield from the boots, owned) uses a slot and has no counter',
  (tl_test.grant_of(:'e1', 'shield-phb') ->> 'uses_spell_slot')::boolean and tl_test.grant_of(:'e1', 'shield-phb') ->> 'remaining' is null);
select public.expend_character_resource(:'e1', 'r:' || (tl_test.ires(:'e1')).id, 1);
select public.short_rest_character(:'e1');
select (tl_test.grant_of(:'e1', 'speak-with-dead-phb') ->> 'remaining')::int as after_short \gset
select public.unattune_item(:'am_row');
select tl_test.rec('IE9 unattune: the spell and its source are gone, the counter is only deactivated (expended kept), bonuses stop',
  :'after_short'::int = 0 and tl_test.grant_of(:'e1', 'speak-with-dead-phb') is null and tl_test.src(:'e1') = 1
  and not (tl_test.ires(:'e1')).active and (tl_test.ires(:'e1')).expended = 1
  and (tl_test.d(:'e1') -> 'initiative' ->> 'bonus')::int = 0);
select public.attune_item(:'am_row');
select tl_test.rec('IE10 attune again: the same counter comes back still spent (no refill by re-attuning); a long rest recharges it',
  (tl_test.grant_of(:'e1', 'speak-with-dead-phb') ->> 'remaining')::int = 0
  and (select (public.long_rest_character(:'e1') is not null))
  and (tl_test.grant_of(:'e1', 'speak-with-dead-phb') ->> 'remaining')::int = 1);
select tl_test.d(:'e1') as dbe \gset
select public.equip_item(:'bt_row', 'feet', true);
select tl_test.d(:'e1') as dbq \gset
select tl_test.rec('IE11 equipped: +10 ft speed and +1 Acrobatics; unequipped they are listed as not counted',
  (:'dbq'::jsonb -> 'speed' ->> 'value')::int = (:'dbe'::jsonb -> 'speed' ->> 'value')::int + 10
  and (:'dbq'::jsonb -> 'skills' -> 'acrobatics' ->> 'item_bonus')::int = 1
  and (:'dbe'::jsonb -> 'speed' -> 'inactive_effects' -> 0 ->> 'inactive_reason') = 'not_equipped'
  and (:'dbe'::jsonb -> 'skills' -> 'acrobatics' -> 'inactive_effects' -> 0 ->> 'inactive_reason') = 'not_equipped');
select public.unequip_item(:'bt_row');
select public.transfer_inventory_item(:'bt_row', tl_test.inv(:'e2'), 1);
select tl_test.rec('IE12 transfer: the giver loses the granted spell, the receiver gets it (owned activation)',
  tl_test.grant_of(:'e1', 'shield-phb') is null and tl_test.grant_of(:'e2', 'shield-phb') is not null and tl_test.src(:'e2') = 1);
select public.remove_inventory_item(tl_test.row_of(:'e2', :'bts'), 1);
select tl_test.rec('IE13 dropping the item removes the grant', tl_test.src(:'e2') = 0);

-- ---- 4. stacking -----------------------------------------------------------------------------------------------------------------
select tl_test.give(:'e2', 'ring-of-protection', 'ring_1') as rp \gset
select tl_test.give(:'e2', 'cloak-of-protection', 'cloak') as cp \gset
select public.attune_item(:'rp'); select public.attune_item(:'cp');
select tl_test.as_root();
insert into public.item_effects (item_id, seq, effect_type, value, target, activation, stacking, stack_group) values
  ('ring-of-protection', 9, 'skill_bonus', 2, 'insight', 'equipped_and_attuned', 'non_stacking_group', 'luck'),
  ('cloak-of-protection', 9, 'skill_bonus', 1, 'insight', 'equipped_and_attuned', 'non_stacking_group', 'luck');
select tl_test.as_user(:'alice');
select tl_test.d(:'e2') as ds \gset
select tl_test.rec('IE14 stacking: additive save bonuses add up (ring + cloak = +2), a stack group counts only the best (+2, not +3)',
  (:'ds'::jsonb -> 'saving_throws' -> 'dex' ->> 'item_bonus')::int = 2
  and jsonb_array_length(:'ds'::jsonb -> 'saving_throws' -> 'dex' -> 'item_sources') = 2
  and (:'ds'::jsonb -> 'skills' -> 'insight' ->> 'item_bonus')::int = 2);

-- ---- 5. permanent effects --------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_give_item(:'hh', array[:'e1']::uuid[], 2, true);
select public.dm_give_item(:'tom', array[:'e3']::uuid[], 1, true);
select tl_test.as_user(:'alice');
select tl_test.row_of(:'e1', :'hh') as hh_row \gset
select (tl_test.d(:'e1') -> 'abilities' -> 'wis' ->> 'score')::int as wis0 \gset
select public.use_inventory_item(:'hh_row', 1, 'e0000000-0000-0000-0000-0000000000a1') as use1 \gset
select public.use_inventory_item(:'hh_row', 1, 'e0000000-0000-0000-0000-0000000000a1') as use1b \gset
select tl_test.rec('IE15 Hag''s Hair: using it applies +1 Wisdom once; the same request again uses nothing and applies nothing',
  :'wis0'::int = 19 and (:'use1'::jsonb ->> 'consumed')::boolean and (:'use1'::jsonb -> 'permanent' -> 0 ->> 'value')::int = 1
  and (:'use1b'::jsonb ->> 'replayed')::boolean
  and (select quantity from public.inventory_items where id = :'hh_row') = 1
  and (tl_test.d(:'e1') -> 'abilities' -> 'wis' ->> 'score')::int = 20
  and (tl_test.d(:'e1') -> 'abilities' -> 'wis' -> 'permanent_sources' -> 0 ->> 'source_name') = 'Hag''s Hair'
  and (select count(*) from tl_test.pe(:'e1') where true and kind = 'effect') = 1);
select tl_test.rec('IE16 its permanent spell (Light, at will) stays after the item is gone',
  tl_test.grant_of(:'e1', 'light-phb') ->> 'uses' = 'at_will');
select public.use_inventory_item(:'hh_row', 1) as use2 \gset
select tl_test.d(:'e1') as dp \gset
select tl_test.rec('IE17 the cap: a second +1 at Wisdom 20 applies nothing (max 20), the source still shows it with 0 applied',
  (:'dp'::jsonb -> 'abilities' -> 'wis' ->> 'score')::int = 20 and (:'dp'::jsonb -> 'abilities' -> 'wis' ->> 'permanent_applied')::int = 1
  and (:'dp'::jsonb -> 'abilities' -> 'wis' -> 'permanent_sources' -> 1 ->> 'applied')::int = 0
  and not exists (select 1 from public.inventory_items where id = :'hh_row'));
select public.use_inventory_item(tl_test.row_of(:'e3', :'tom'), 1);
select tl_test.rec('IE18 a raised maximum: the Tome (+2, max 22) takes Wisdom 20 to 22',
  (tl_test.d(:'e3') -> 'abilities' -> 'wis' ->> 'score')::int = 22 and (tl_test.d(:'e3') -> 'abilities' -> 'wis' ->> 'modifier')::int = 6);
select (select x ->> 'id' from jsonb_array_elements(tl_test.d(:'e1') -> 'permanent_effects') x where x ->> 'kind' = 'effect' limit 1) as pe1 \gset
select tl_test.rec('IE19 a player cannot revert a permanent effect',
  tl_test.code(format('select public.revert_permanent_effect(%L)', :'pe1')) = '42501'
  and not (tl_test.d(:'e1') -> 'permanent_effects' -> 0 ->> 'can_revert')::boolean);
select tl_test.as_user(:'dm');
select tl_test.rec('IE20 the DM sees the source and can revert it',
  (tl_test.d(:'e1') -> 'permanent_effects' -> 0 ->> 'can_revert')::boolean
  and (tl_test.d(:'e1') -> 'permanent_effects' -> 0 ->> 'item_id') = :'hh');
select public.revert_permanent_effect(:'pe1', 'Wrong hair');
select (select (public.revert_permanent_effect(:'pe1') ->> 'already')::boolean) as again \gset
select tl_test.as_user(:'alice');
select tl_test.rec('IE21 reverted: the other +1 now applies (19 + 1 = 20 again); the reverted row is kept with its reason',
  :'again'::boolean and (tl_test.d(:'e1') -> 'abilities' -> 'wis' ->> 'score')::int = 20
  and jsonb_array_length(tl_test.d(:'e1') -> 'abilities' -> 'wis' -> 'permanent_sources') = 1
  and (select count(*) from tl_test.pe(:'e1') where true and reverted_at is not null and revert_reason = 'Wrong hair') = 1);

-- ---- 6. secrecy: an unidentified amulet -------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select tl_test.pub('{"name": "Periapt of the Lich", "definition": {"item": {"kind_id": "magic_item", "is_magic": true, "rarity_id": "rare",
  "effects": [{"type": "ac_bonus", "value": 1, "activation": "owned"}, {"type": "initiative_bonus", "value": 1, "activation": "owned"}],
  "spells": [{"spell": "speak-with-dead-phb", "casting": "per_rest", "uses": 2, "recharge": "short_rest", "activation": "owned"}]},
  "hidden": {"unidentified_name": "Dull pendant", "unidentified_description": "A dull grey pendant."}}}') as lich \gset
select tl_test.ref(:'lich') as lr \gset
select public.dm_give_item(:'lr', array[:'e2']::uuid[], 1, false);
select tl_test.d(:'e2')::text as dm_view \gset
select tl_test.as_user(:'alice');
select tl_test.d(:'e2')::text as pl_view, public.get_character_spellbook(:'e2')::text as pl_book,
       public.get_character_resources(:'e2')::text as pl_res \gset
select public.get_character_reads(:'e2', array['get_character_derived_stats', 'get_character_spellbook', 'get_character_resources']) ->> 'reads' as rd1 \gset
select public.get_character_reads(:'e2', array['get_character_derived_stats', 'get_character_spellbook', 'get_character_resources']) ->> 'reads' as rd2 \gset
select tl_test.rec('IE22 unidentified: the bonuses work for the player too (AC +1, initiative +1), labelled only with the disguise',
  (:'pl_view'::jsonb -> 'initiative' ->> 'bonus')::int = 1
  and (:'pl_view'::jsonb -> 'armor_class' ->> 'value')::int = (:'dm_view'::jsonb -> 'armor_class' ->> 'value')::int
  and (:'pl_view'::jsonb -> 'initiative' -> 'sources') ? 'Dull pendant'
  and position('Periapt' in :'pl_view') = 0 and position(:'lr' in :'pl_view') = 0);
select tl_test.rec('IE23 the DM view shows the truth', position('Periapt of the Lich (unidentified)' in :'dm_view') > 0);
select tl_test.rec('IE24 spellbook, resources, cached reads (miss and hit), tl_cache rows: the spell is there, the true name never',
  position('Speak with Dead' in :'pl_book') > 0 and position('Dull pendant' in :'pl_book') > 0
  and position('Periapt' in :'pl_book') = 0 and position('Periapt' in :'pl_res') = 0
  and position('Periapt' in :'rd1') = 0 and position('Periapt' in :'rd2') = 0 and position(:'lr' in :'rd1') = 0
  and position('Periapt' in tl_test.cache_text(:'e2', :'alice')) = 0);
select tl_test.rec('IE25 REST (what Realtime carries): source label, spell notes, resource name / notes / key show no true name or item id',
  not exists (select 1 from public.character_spellcasting_sources where character_id = :'e2' and (label like '%Periapt%' or label like '%' || :'lr' || '%' or item_grant_key like '%' || :'lr' || '%'))
  and exists (select 1 from public.character_spellcasting_sources where character_id = :'e2' and label = 'Dull pendant')
  and not exists (select 1 from public.character_spells where character_id = :'e2' and acquisition_notes like '%Periapt%')
  and not exists (select 1 from public.character_resources where character_id = :'e2' and (name || coalesce(notes, '') || resource_key || coalesce(source_id, '')) like '%Periapt%')
  and not exists (select 1 from public.character_resources where character_id = :'e2' and (resource_key || coalesce(source_id, '')) like '%' || :'lr' || '%'));
select tl_test.as_user(:'bob');
select tl_test.rec('IE26 an outsider reads no item effects or permanent rows of the character',
  not exists (select 1 from public._character_item_effect_rows(:'e2')) and public._character_permanent_effect_rows(:'e1') = '[]'::jsonb);
select tl_test.as_user(:'dm');
select public.set_item_knowledge(tl_test.row_of(:'e2', :'lr'), 'identified');
select tl_test.as_user(:'alice');
select tl_test.rec('IE27 identified: the player now sees the true name on the bonuses and the spell source',
  (tl_test.d(:'e2') -> 'initiative' -> 'sources') ? 'Periapt of the Lich'
  and exists (select 1 from public.character_spellcasting_sources where character_id = :'e2' and label = 'Periapt of the Lich'));

-- an unidentified consumable with a permanent effect: applied, the answer names nothing, the player sees the disguise
select tl_test.as_user(:'dm');
select tl_test.pub('{"name": "Draught of Clarity", "definition": {"item": {"kind_id": "potion", "is_consumable": true,
  "effects": [{"type": "skill_bonus", "target": "perception", "value": 1, "activation": "permanent"}]},
  "hidden": {"unidentified_name": "Murky vial"}}}') as dr \gset
select tl_test.ref(:'dr') as drr \gset
select public.dm_give_item(:'drr', array[:'e3']::uuid[], 1, false);
select tl_test.as_user(:'alice');
select public.use_inventory_item(tl_test.row_of(:'e3', :'drr'), 1) as mu \gset
select tl_test.rec('IE28 used unidentified: the effect applies (+1 Perception), the answer lists nothing, the source is the disguise',
  (:'mu'::jsonb -> 'permanent') = '[]'::jsonb and (:'mu'::jsonb ->> 'unidentified')::boolean
  and (tl_test.d(:'e3') -> 'skills' -> 'perception' ->> 'item_bonus')::int = 1
  and (tl_test.d(:'e3') -> 'skills' -> 'perception' -> 'item_sources' -> 0 ->> 'source_name') = 'Murky vial (permanent)'
  and position('Clarity' in tl_test.d(:'e3')::text) = 0);
select tl_test.as_user(:'dm');
select tl_test.rec('IE29 the DM sees which item it was', (tl_test.d(:'e3') -> 'skills' -> 'perception' -> 'item_sources' -> 0 ->> 'source_name') = 'Draught of Clarity (permanent)');

-- an unidentified attunement item that is not attuned: nothing about its effects reaches the player (they apply nothing)
select tl_test.pub('{"name": "Circlet of Insight", "definition": {"item": {"kind_id": "magic_item", "is_magic": true, "rarity_id": "rare",
  "requires_attunement": true, "effects": [{"type": "skill_bonus", "target": "insight", "value": 4, "activation": "attuned"}]},
  "hidden": {"unidentified_name": "Tarnished band"}}}') as circ \gset
select public.dm_give_item(tl_test.ref(:'circ'), array[:'e3']::uuid[], 1, false);
select tl_test.d(:'e3')::text as dm_c \gset
select tl_test.as_user(:'alice');
select tl_test.d(:'e3')::text as pl_c \gset
select tl_test.rec('IE31 unidentified and not attuned: the player''s derived stats name neither the disguise nor the effect; the DM sees it as not counted',
  position('Tarnished band' in :'pl_c') = 0 and position('Circlet' in :'pl_c') = 0
  and coalesce((:'pl_c'::jsonb -> 'skills' -> 'insight' -> 'inactive_effects'), '[]'::jsonb) = '[]'::jsonb
  and (:'dm_c'::jsonb -> 'skills' -> 'insight' -> 'inactive_effects' -> 0 ->> 'source_name') = 'Circlet of Insight (unidentified)');
select tl_test.as_user(:'dm');

-- ---- 7. versions -----------------------------------------------------------------------------------------------------------------
select public.new_dm_content_version(:'boots');
select public.save_dm_content(:'boots', '{"definition": {"item": {"kind_id": "magic_item", "category_id": "wondrous-item", "is_magic": true, "rarity_id": "common", "effects": [{"type": "speed_bonus", "value": 5, "activation": "equipped"}]}}}');
select public.publish_dm_content(:'boots');
select tl_test.rec('IE30 a new version has its own catalog row and effects; the old version''s rows stay as they were',
  tl_test.ref(:'boots') <> :'bts' and (select value from public.item_effects where item_id = tl_test.ref(:'boots')) = 5
  and (select count(*) from public.item_effects where item_id = :'bts') = 2
  and not exists (select 1 from public.item_spell_grants where item_id = tl_test.ref(:'boots')));
