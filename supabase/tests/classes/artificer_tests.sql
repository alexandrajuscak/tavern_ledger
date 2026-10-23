-- =============================================================================
-- Artificer (artificer-tce) and Alchemist (artificer-alchemist-tce): infusions known (catalog, prerequisites), Infuse Item on
-- inventory items (instance modifiers, item rules, one per item, infused item limit, managed modifiers RPC-only, attunement
-- needed by the infusion, level variants), Replicate Magic Item, Homunculus Servant (companion), attunement limit from
-- Magic Item Adept, Alchemist spells / resources / Chemical Mastery, progression, multiclass, RLS.
-- =============================================================================
\set a1 f2000000-0000-0000-0000-000000000001
\set a2 f2000000-0000-0000-0000-000000000002
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'a1', :'alice', 'Artificer Tester', :'camp', 10, 14, 14, 16, 10, 8),
  (:'a2', :'alice', 'Fighter then Artificer', null, 16, 12, 14, 13, 10, 8);
create function tl_test.inf(p_char uuid) returns jsonb language sql as $$ select public.get_character_infusions(p_char) $$;
create function tl_test.add(p_char uuid, p_item text) returns uuid language sql as $$
  select public.add_inventory_item((select id from public.inventories where character_id = p_char and kind = 'character'), p_item, 1) $$;
create function tl_test.ii(p_char uuid, p_item text) returns uuid language sql as $$
  select ii.id from public.inventory_items ii join public.inventories v on v.id = ii.inventory_id
  where v.character_id = p_char and ii.item_id = p_item order by ii.created_at limit 1 $$;
create function tl_test.weapon(p_char uuid, p_item text) returns jsonb language sql as $$
  select w from jsonb_array_elements(tl_test.d(p_char) -> 'equipped_weapon_attacks') w where w ->> 'item_id' = p_item limit 1 $$;
create function tl_test.choose_inf(p_char uuid, p_vals text[]) returns text language sql as $$
  select tl_test.raises(format('select tl_test.choose(%L, %L, %L, %L, %L)', p_char, 'artificer', 'artificer-tce-u2-infuse-item',
                               'artificer-infuse-item-tce-infusions', p_vals)) $$;
grant all on all functions in schema tl_test to public;

select tl_test.rec('AR1 Artificer: every class level 1-20 is represented; 16 official infusions (Armor of Tools, UA, not offered); infusion modifiers are managed',
  tl_test.levels_represented('artificer-tce') = 20
  and (select count(*) from public.class_feature_choice_options where choice_id = 'artificer-infuse-item-tce-infusions') = 16
  and (select bool_and(managed_by = 'class_infusion') from public.item_modifiers where id like 'infusion-%'));

select tl_test.as_user(:'alice');
select tl_test.setc(:'a1', 'artificer-tce', 2);
select tl_test.rec('AR2 Artificer 2: four infusions known; Radiant Weapon (level 6) is refused',
  tl_test.choose_inf(:'a1', '{enhanced-weapon,enhanced-arcane-focus,replicate-magic-item,radiant-weapon}') like '%level 6%');
select tl_test.choose_inf(:'a1', '{enhanced-weapon,enhanced-arcane-focus,replicate-magic-item,homunculus-servant}');
select tl_test.add(:'a1', 'mace');
select tl_test.add(:'a1', 'rod');
select tl_test.add(:'a1', 'shield');
select tl_test.rec('AR3 candidates: the mace can take Enhanced Weapon, the rod cannot ("needs a simple or martial weapon")',
  (select c ->> 'refusal' is null from jsonb_array_elements(tl_test.inf(:'a1') -> 'choices' -> 0 -> 'known') k, jsonb_array_elements(k -> 'candidates') c
   where k ->> 'id' = 'enhanced-weapon' and c ->> 'name' = 'Mace')
  and (select c ->> 'refusal' is not null from jsonb_array_elements(tl_test.inf(:'a1') -> 'choices' -> 0 -> 'known') k, jsonb_array_elements(k -> 'candidates') c
       where k ->> 'id' = 'enhanced-weapon' and c ->> 'name' = 'Rod'));
select public.apply_infusion(:'a1', 'enhanced-weapon', tl_test.ii(:'a1', 'mace'));
select public.equip_item(tl_test.ii(:'a1', 'mace'), 'main_hand');
select tl_test.rec('AR4 Enhanced Weapon on the equipped mace: +3 to hit (STR 0 + PB 2 + 1), 1d6 + 1',
  (tl_test.weapon(:'a1', 'mace') ->> 'attack_bonus')::int = 3 and tl_test.weapon(:'a1', 'mace') ->> 'damage' = '1d6 + 1',
  tl_test.weapon(:'a1', 'mace')::text);
select tl_test.rec('AR5 infusion modifiers are RPC-only: applying or removing one directly is refused; a second infusion on the same item is refused',
  tl_test.raises(format('insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (%L, %L)', tl_test.ii(:'a1', 'shield'), 'infusion-enhanced-weapon-l2')) like '%Infuse Item%'
  and tl_test.raises(format('delete from public.inventory_item_modifiers where inventory_item_id = %L', tl_test.ii(:'a1', 'mace'))) like '%managed%'
  and tl_test.raises(format('select public.apply_infusion(%L, %L, %L)', :'a1', 'enhanced-weapon', tl_test.ii(:'a1', 'mace'))) like '%already holds%');
select tl_test.rec('AR6 a plain rod cannot be attuned; Enhanced Arcane Focus (attunement) makes it attunable',
  tl_test.raises(format('select public.attune_item(%L)', tl_test.ii(:'a1', 'rod'))) like '%does not require attunement%'
  and (select public.apply_infusion(:'a1', 'enhanced-arcane-focus', tl_test.ii(:'a1', 'rod')) is not null)
  and tl_test.raises(format('select public.attune_item(%L)', tl_test.ii(:'a1', 'rod'))) is null);
select tl_test.rec('AR7 two infused items is the limit at level 2: a third is refused',
  tl_test.raises(format('select public.apply_infusion(%L, %L, null, %L)', :'a1', 'replicate-magic-item', 'bag-of-holding')) like '%2 infused items%');
select public.remove_infusion(:'a1', (select id from public.character_infusions where character_id = :'a1' and infusion_id = 'enhanced-arcane-focus'));
select tl_test.rec('AR8 ending Enhanced Arcane Focus: the modifier goes and the rod is no longer attuned',
  not (select is_attuned from public.inventory_items where id = tl_test.ii(:'a1', 'rod'))
  and not exists (select 1 from public.inventory_item_modifiers where inventory_item_id = tl_test.ii(:'a1', 'rod')));
select tl_test.rec('AR9 Replicate Magic Item: Boots of Elvenkind (level 6 table) refused at level 2; Bag of Holding created in the inventory',
  tl_test.raises(format('select public.apply_infusion(%L, %L, null, %L)', :'a1', 'replicate-magic-item', 'boots-of-elvenkind')) like '%replicate%'
  and (select public.apply_infusion(:'a1', 'replicate-magic-item', null, 'bag-of-holding') is not null)
  and tl_test.ii(:'a1', 'bag-of-holding') is not null);
select public.remove_infusion(:'a1', (select id from public.character_infusions where character_id = :'a1' and infusion_id = 'replicate-magic-item'));
select tl_test.rec('AR10 ending the replication removes the Bag of Holding', tl_test.ii(:'a1', 'bag-of-holding') is null);
select public.apply_infusion(:'a1', 'homunculus-servant');
select tl_test.rec('AR11 Homunculus Servant: a companion with 1 + INT 3 + level 2 = 6 hit points',
  (select hp_max = 6 and name = 'Homunculus Servant' from public.character_companions where character_id = :'a1'));

select tl_test.setc(:'a1', 'artificer-tce', 10, 'artificer-alchemist-tce');
select tl_test.rec('AR12 at level 10 the Enhanced Weapon infusion is outdated (+1 instead of +2); the attunement limit is 4 (Magic Item Adept)',
  (select (a ->> 'outdated')::boolean from jsonb_array_elements(tl_test.inf(:'a1') -> 'active') a where a ->> 'infusion_id' = 'enhanced-weapon')
  and (select attunement_limit from public.v_character_attunement where character_id = :'a1') = 4);
select public.refresh_infusions(:'a1');
select tl_test.rec('AR13 refresh: the mace now has +2 (1d6 + 2)', tl_test.weapon(:'a1', 'mace') ->> 'damage' = '1d6 + 2',
  tl_test.weapon(:'a1', 'mace') ->> 'damage');
select tl_test.rec('AR14 Alchemist 10: Healing Word and Gaseous Form always prepared; Experimental Elixir 2 per long rest; Restorative Reagents 3 uses',
  (select bool_and((g ->> 'always_prepared')::boolean) from (select g from jsonb_array_elements(tl_test.spell(:'a1', 'gaseous-form-phb') -> 'grants') g where g ->> 'source_type' = 'class_feature') q)
  and (tl_test.res(:'a1', 'artificer-alchemist-experimental-elixir-tce-uses') ->> 'max')::int = 2
  and (tl_test.res(:'a1', 'artificer-alchemist-restorative-reagents-tce-uses') ->> 'max')::int = 3);
select tl_test.setc(:'a1', 'artificer-tce', 15);
select tl_test.rec('AR15 Chemical Mastery: resistance to acid and poison, immune to poisoned; Heal once per long rest',
  (tl_test.d(:'a1') -> 'resistances')::text like '%acid%' and (tl_test.d(:'a1') -> 'resistances')::text like '%poison%'
  and tl_test.d(:'a1') -> 'condition_immunities' ? 'poisoned'
  and (tl_test.res(:'a1', 'artificer-alchemist-chemical-mastery-tce-heal') ->> 'max')::int = 1);

-- ---- progression snapshot ---------------------------------------------------------------------------------------------------
select tl_test.as_root();
create table tl_test.asnap (level int, known int, items int, attune int);
grant all on tl_test.asnap to public;
select tl_test.as_user(:'alice');
do $$
declare l int; ch uuid := 'f2000000-0000-0000-0000-000000000001';
begin
  for l in 1..20 loop
    perform tl_test.setc(ch, 'artificer-tce', l);
    insert into tl_test.asnap values (l,
      coalesce((case when (tl_test.ch(ch, 'artificer', 'artificer-tce-u2-infuse-item:artificer-infuse-item-tce-infusions') ->> 'open')::boolean
                     then tl_test.ch(ch, 'artificer', 'artificer-tce-u2-infuse-item:artificer-infuse-item-tce-infusions') ->> 'max' end)::int, 0),
      coalesce((select (c ->> 'max_items')::int from jsonb_array_elements(tl_test.inf(ch) -> 'choices') c limit 1), 0),
      (select attunement_limit from public.v_character_attunement where character_id = ch));
  end loop;
end $$;
select tl_test.rec('AR16 progression snapshot 1-20 (infusions known, infused items, attunement limit)',
  (select string_agg(format('%s:%s/%s/%s', level, known, items, attune), ' ' order by level) from tl_test.asnap)
  = '1:0/0/3 2:4/2/3 3:4/2/3 4:4/2/3 5:4/2/3 6:6/3/3 7:6/3/3 8:6/3/3 9:6/3/3 10:8/4/4 11:8/4/4 12:8/4/4 13:8/4/4 14:10/5/5 '
    '15:10/5/5 16:10/5/5 17:10/5/5 18:12/6/6 19:12/6/6 20:12/6/6',
  (select string_agg(format('%s:%s/%s/%s', level, known, items, attune), ' ' order by level) from tl_test.asnap));

select tl_test.setc(:'a2', 'fighter-phb', 2);
select tl_test.setc(:'a2', 'artificer-tce', 2);
select tl_test.rec('AR17 Artificer as a second class: no CON / INT saves from it; infusions work from Artificer 2',
  not coalesce((tl_test.d(:'a2') -> 'saving_throws' -> 'int' ->> 'class_proficient')::boolean, false)
  and (tl_test.ch(:'a2', 'artificer', 'artificer-tce-u2-infuse-item:artificer-infuse-item-tce-infusions') ->> 'max')::int = 4);
select tl_test.as_user(:'bob');
select tl_test.rec('AR18 an outsider cannot read or apply infusions, or read the infusion rows',
  tl_test.raises($$select public.get_character_infusions('f2000000-0000-0000-0000-000000000001')$$) is not null
  and tl_test.raises($$select public.apply_infusion('f2000000-0000-0000-0000-000000000001', 'enhanced-weapon', null)$$) is not null
  and not exists (select 1 from public.character_infusions where character_id = 'f2000000-0000-0000-0000-000000000001'));
select tl_test.as_root();
