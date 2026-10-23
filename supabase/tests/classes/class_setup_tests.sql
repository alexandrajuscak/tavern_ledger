-- =============================================================================
-- Class setup flow (generic): guided Add Class preview (nothing stored; features, proficiencies, choices, slots, multiclass
-- prerequisites of every class, starting equipment only for the first class) and the starting equipment review (candidates,
-- validation, applied once, primary class only, inventory rows), RLS.
-- =============================================================================
\set s1 f1b00000-0000-0000-0000-000000000001
\set s2 f1b00000-0000-0000-0000-000000000002
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'s1', :'alice', 'Setup Tester', :'camp', 15, 12, 14, 10, 12, 12),
  (:'s2', :'alice', 'New Character', null, 10, 14, 12, 10, 10, 10);
grant all on all functions in schema tl_test to public;

select tl_test.as_user(:'alice');
select tl_test.rec('SU1 first class preview: Paladin 1 shows Divine Sense, saves, starting equipment groups; nothing is stored',
  (select (p ->> 'possible')::boolean and (p ->> 'first_class')::boolean
          and p -> 'features_activated' @> '[{"name": "Divine Sense"}]'::jsonb
          and jsonb_array_length(p -> 'starting_equipment' -> 'groups') = 4 and p -> 'prerequisites' = '[]'::jsonb
     from (select public.preview_character_class_add(:'s2', 'paladin-phb', 1) p) q)
  and not exists (select 1 from public.character_classes where character_id = :'s2'));
select tl_test.setc(:'s1', 'fighter-phb', 3);
select tl_test.rec('SU2 multiclass preview Fighter 3 -> + Wizard 1: INT 10 fails the Wizard prerequisite (INT 13); Fighter''s (STR 13 or DEX 13) is met',
  (select not (p ->> 'prerequisites_met')::boolean
          and p -> 'prerequisites' @> '[{"class_id": "wizard", "met": false, "requirement": "INT 13", "new_class": true}]'::jsonb
          and p -> 'prerequisites' @> '[{"class_id": "fighter", "met": true}]'::jsonb
          and p -> 'starting_equipment' = 'null'::jsonb and p ->> 'starting_equipment_note' like '%no starting equipment%'
     from (select public.preview_character_class_add(:'s1', 'wizard-phb', 1) p) q));
select tl_test.rec('SU3 multiclass preview Fighter 3 -> + Cleric 1: slots 1st x2 appear, the multiclass proficiencies (light / medium armor, shields) are listed',
  (select p -> 'standard_slots' -> 'to' ->> '1' = '2' and (p -> 'total_level' ->> 'to')::int = 4
          and exists (select 1 from jsonb_array_elements(p -> 'proficiencies' -> 'added') a where a ->> 'value' = 'medium-armor')
     from (select public.preview_character_class_add(:'s1', 'cleric-phb', 1) p) q)
  and (select count(*) from public.character_classes where character_id = :'s1') = 1);
select tl_test.rec('SU4 preview refuses a class already on the character and a level beyond 20',
  (public.preview_character_class_add(:'s1', 'fighter-phb', 1) ->> 'possible')::boolean = false
  and (public.preview_character_class_add(:'s1', 'rogue-phb', 18) ->> 'error') like '%at most 20%');

select tl_test.rec('SU5 starting equipment of the Paladin: "martial weapon" candidates are official martial weapons (Longsword yes, Dagger no)',
  (select exists (select 1 from jsonb_array_elements(i -> 'candidates') c where c ->> 'id' = 'longsword')
      and not exists (select 1 from jsonb_array_elements(i -> 'candidates') c where c ->> 'id' = 'dagger')
   from jsonb_array_elements(public.get_class_starting_equipment('paladin-phb') -> 'groups') g, jsonb_array_elements(g -> 'options') o,
        jsonb_array_elements(o -> 'items') i
   where (g ->> 'group')::int = 1 and o ->> 'key' = 'a' and i ? 'group'));
select tl_test.setc(:'s2', 'paladin-phb', 1);
select tl_test.rec('SU6 a missing pick is refused; a pick that is not a candidate is refused',
  tl_test.raises($$select public.apply_class_starting_equipment('f1b00000-0000-0000-0000-000000000002', 'paladin-phb',
    '{"options": {"1": "a", "2": "a", "3": "a"}, "picks": {"4:a:1": "amulet"}}')$$) like '%Choose 1%'
  and tl_test.raises($$select public.apply_class_starting_equipment('f1b00000-0000-0000-0000-000000000002', 'paladin-phb',
    '{"options": {"1": "a", "2": "a", "3": "a"}, "picks": {"1:a:0": "dagger", "4:a:1": "amulet"}}')$$) like '%not a choice%');
select public.apply_class_starting_equipment(:'s2', 'paladin-phb',
  '{"options": {"1": "b", "2": "a", "3": "b"}, "picks": {"1:b:0": ["longsword", "warhammer"], "4:a:1": "emblem"}}');
select tl_test.rec('SU7 applied: longsword, warhammer, 5 javelins, explorer''s pack, chain mail, emblem in the inventory (noted as starting equipment)',
  (select string_agg(ii.item_id || 'x' || ii.quantity, ',' order by ii.item_id)
   from public.inventory_items ii join public.inventories v on v.id = ii.inventory_id where v.character_id = :'s2')
  = 'chain-mailx1,emblemx1,explorers-packx1,javelinx5,longswordx1,warhammerx1',
  (select string_agg(ii.item_id || 'x' || ii.quantity, ',' order by ii.item_id)
   from public.inventory_items ii join public.inventories v on v.id = ii.inventory_id where v.character_id = :'s2'));
select tl_test.rec('SU8 a second application is refused; a multiclass (not primary) class cannot apply',
  tl_test.raises($$select public.apply_class_starting_equipment('f1b00000-0000-0000-0000-000000000002', 'paladin-phb', '{"options": {"1": "b", "2": "a", "3": "b"}}')$$) like '%already%'
  and tl_test.raises($$select public.apply_class_starting_equipment('f1b00000-0000-0000-0000-000000000001', 'cleric-phb', '{}')$$) like '%first (primary)%');
select tl_test.as_user(:'bob');
select tl_test.rec('SU9 an outsider cannot preview, apply or read the record',
  tl_test.raises($$select public.preview_character_class_add('f1b00000-0000-0000-0000-000000000001', 'cleric-phb', 1)$$) is not null
  and tl_test.raises($$select public.apply_class_starting_equipment('f1b00000-0000-0000-0000-000000000001', 'fighter-phb', '{}')$$) is not null
  and not exists (select 1 from public.character_starting_equipment where character_id = 'f1b00000-0000-0000-0000-000000000002'));
select tl_test.as_user(:'alice');
select tl_test.rec('SU10 the owner reads the record; direct writes are refused (RPC only)',
  exists (select 1 from public.character_starting_equipment where character_id = :'s2')
  and tl_test.raises($$delete from public.character_starting_equipment$$) is not null);
select tl_test.as_root();
