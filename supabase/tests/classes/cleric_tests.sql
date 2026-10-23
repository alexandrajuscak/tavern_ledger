-- =============================================================================
-- Cleric (cleric-phb) and Life Domain (cleric-life-phb): catalog, domain spells (always prepared, not counted), Channel
-- Divinity, Turn / Destroy Undead, Divine Intervention, Divine Strike vs Blessed Strikes (optional replacement), Harness
-- Divine Power (slot recovery that also spends Channel Divinity), progression, multiclass, RLS.
-- =============================================================================
\set c1 f1c10000-0000-0000-0000-000000000001
\set c2 f1c10000-0000-0000-0000-000000000002
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'c1', :'alice', 'Cleric Tester', :'camp', 14, 10, 14, 10, 16, 12),
  (:'c2', :'alice', 'Rogue then Cleric', null, 10, 16, 12, 10, 14, 10);
create function tl_test.csrc(p_char uuid) returns jsonb language sql as $$
  select s from jsonb_array_elements(public.get_character_spellbook(p_char) -> 'sources') s where s ->> 'class_version_id' = 'cleric-phb' $$;
create function tl_test.granted(p_char uuid, p_spell text) returns jsonb language sql as $$
  select g from jsonb_array_elements(tl_test.spell(p_char, p_spell) -> 'grants') g where g ->> 'source_type' = 'class_feature' limit 1 $$;
grant all on all functions in schema tl_test to public;

select tl_test.rec('CL1 Cleric: every class level 1-20 is represented', tl_test.levels_represented('cleric-phb') = 20);
select tl_test.rec('CL2 class metadata: d8, WIS primary, WIS and CHA saves, two skills from five, subclass at 1',
  (select hit_die = 'd8' and primary_abilities = '{wis}' and saving_throws = '{wis,cha}' and (skill_choice ->> 'count')::int = 2
          and jsonb_array_length(skill_choice -> 'from') = 5 and subclass_level = 1 and feature_status = 'complete'
   from public.class_versions where id = 'cleric-phb'));
select tl_test.rec('CL3 14 official domains in the catalog (Life complete, Death a DMG option needing DM permission)',
  (select count(*) from public.subclass_versions where class_id = 'cleric') = 14
  and (select implementation_status from public.subclass_versions where id = 'cleric-life-phb') = 'complete'
  and (select requires_dm_permission from public.subclass_versions where id = 'cleric-death-dmg'));

select tl_test.as_user(:'alice');
select tl_test.setc(:'c1', 'cleric-phb', 1, 'cleric-life-phb');
select tl_test.rec('CL4 Life 1: Bless and Cure Wounds are always prepared through the domain; heavy armor proficiency',
  (tl_test.granted(:'c1', 'bless-phb') ->> 'always_prepared')::boolean and (tl_test.granted(:'c1', 'cure-wounds-phb') ->> 'always_prepared')::boolean
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'c1') -> 'proficiencies') p where p ->> 'group_id' = 'heavy-armor'));
select tl_test.rec('CL5 domain spells never count against the prepared limit (Cleric source: 0 prepared, limit WIS 3 + 1 = 4)',
  (tl_test.csrc(:'c1') -> 'counts' ->> 'prepared')::int = 0
  and not (tl_test.granted(:'c1', 'bless-phb') ->> 'counts_against_prepared_limit')::boolean);
select tl_test.rec('CL6 Lesser Restoration is not granted before Cleric 3', tl_test.granted(:'c1', 'lesser-restoration-phb') is null
  or not (tl_test.granted(:'c1', 'lesser-restoration-phb') ->> 'unlocked')::boolean);
select tl_test.setc(:'c1', 'cleric-phb', 3);
select tl_test.rec('CL7 Cleric 3: Lesser Restoration and Spiritual Weapon join the domain spells',
  (tl_test.granted(:'c1', 'lesser-restoration-phb') ->> 'unlocked')::boolean and (tl_test.granted(:'c1', 'spiritual-weapon-phb') ->> 'always_prepared')::boolean);
select tl_test.rec('CL8 Channel Divinity 1 use (short or long rest); Turn Undead and Preserve Life (15 HP at Cleric 3) are reminders',
  (tl_test.res(:'c1', 'cleric-channel-divinity-phb-uses') ->> 'max')::int = 1
  and tl_test.res(:'c1', 'cleric-channel-divinity-phb-uses') ->> 'recharge' = 'short_or_long_rest'
  and (select automation from public.class_feature_versions where id = 'cleric-turn-undead-phb') = 'informational'
  and exists (select 1 from jsonb_array_elements(tl_test.f(:'c1') -> 'classes' -> 0 -> 'features') f, jsonb_array_elements(f -> 'scaling') s
              where f ->> 'unlock_id' = 'cleric-life-phb-u2-preserve-life' and s -> 'value' = '15'::jsonb));

-- ---- Harness Divine Power (optional; spends Channel Divinity and restores one slot) ----------------------------------------------------
select public.set_character_optional_feature(:'c1', tl_test.k(:'c1', 'cleric'), 'cleric-phb-u2-harness-divine-power', true);
select public.expend_standard_spell_slot(:'c1', 1); select public.expend_standard_spell_slot(:'c1', 2);
select tl_test.rec('CL9 Harness Divine Power at PB 2: one slot of level 1 at most (a 2nd-level slot is refused)',
  tl_test.raises($$select public.recover_spell_slots('f1c10000-0000-0000-0000-000000000001', tl_test.rkey('f1c10000-0000-0000-0000-000000000001', 'cleric', 'cleric-harness-divine-power-tce-uses'), '{2}')$$) like '%level 1 to%'
  or tl_test.raises($$select public.recover_spell_slots('f1c10000-0000-0000-0000-000000000001', tl_test.rkey('f1c10000-0000-0000-0000-000000000001', 'cleric', 'cleric-harness-divine-power-tce-uses'), '{2}')$$) like '%at most 1%');
select public.recover_spell_slots(:'c1', tl_test.rkey(:'c1', 'cleric', 'cleric-harness-divine-power-tce-uses'), '{1}');
select tl_test.rec('CL10 the recovery restores the 1st-level slot and spends both Harness Divine Power and Channel Divinity',
  (select expended from public.character_spell_slot_state where character_id = :'c1' and pool = 'standard' and slot_level = 1) = 0
  and (tl_test.res(:'c1', 'cleric-harness-divine-power-tce-uses') ->> 'remaining')::int = 0
  and (tl_test.res(:'c1', 'cleric-channel-divinity-phb-uses') ->> 'remaining')::int = 0);
select public.short_rest_character(:'c1');
select tl_test.rec('CL11 a short rest restores Channel Divinity but not Harness Divine Power (long rest)',
  (tl_test.res(:'c1', 'cleric-channel-divinity-phb-uses') ->> 'remaining')::int = 1
  and (tl_test.res(:'c1', 'cleric-harness-divine-power-tce-uses') ->> 'remaining')::int = 0);
select public.long_rest_character(:'c1');
select public.expend_character_resource(:'c1', tl_test.rkey(:'c1', 'cleric', 'cleric-channel-divinity-phb-uses'));
select public.expend_standard_spell_slot(:'c1', 1);
select tl_test.rec('CL12 without a Channel Divinity use left, Harness Divine Power is refused and changes nothing',
  tl_test.raises($$select public.recover_spell_slots('f1c10000-0000-0000-0000-000000000001', tl_test.rkey('f1c10000-0000-0000-0000-000000000001', 'cleric', 'cleric-harness-divine-power-tce-uses'), '{1}')$$) like '%none is left%'
  and (tl_test.res(:'c1', 'cleric-harness-divine-power-tce-uses') ->> 'remaining')::int = 1);

-- ---- Divine Strike, Blessed Strikes, Destroy Undead, Divine Intervention --------------------------------------------------------------
select tl_test.setc(:'c1', 'cleric-phb', 8);
select tl_test.rec('CL13 Cleric 8: Divine Strike 1d8 radiant (once per turn); Destroy Undead CR 1; Channel Divinity 2 uses',
  tl_test.d(:'c1') -> 'attack_riders' @> '[{"name": "Divine Strike", "dice": "1d8", "once_per_turn": true, "damage_type": "radiant"}]'::jsonb
  and (tl_test.res(:'c1', 'cleric-channel-divinity-phb-uses') ->> 'max')::int = 2
  and exists (select 1 from jsonb_array_elements(tl_test.f(:'c1') -> 'classes' -> 0 -> 'features') f, jsonb_array_elements(f -> 'scaling') s
              where f ->> 'unlock_id' = 'cleric-phb-u5-destroy-undead' and s -> 'value' = '"1"'::jsonb));
select public.set_character_optional_feature(:'c1', tl_test.k(:'c1', 'cleric'), 'cleric-life-phb-u8-blessed-strikes', true);
select tl_test.rec('CL14 Blessed Strikes (optional) replaces Divine Strike: only one rider remains',
  tl_test.ust(:'c1', 'cleric-life-phb-u8-divine-strike') = 'replaced'
  and tl_test.d(:'c1') -> 'attack_riders' @> '[{"name": "Blessed Strikes", "dice": "1d8"}]'::jsonb
  and not tl_test.d(:'c1') -> 'attack_riders' @> '[{"name": "Divine Strike"}]'::jsonb);
select public.set_character_optional_feature(:'c1', tl_test.k(:'c1', 'cleric'), 'cleric-life-phb-u8-blessed-strikes', false);
select tl_test.setc(:'c1', 'cleric-phb', 14);
select tl_test.rec('CL15 switching back: Divine Strike again, 2d8 at Cleric 14', tl_test.d(:'c1') -> 'attack_riders' @> '[{"name": "Divine Strike", "dice": "2d8"}]'::jsonb);
select tl_test.setc(:'c1', 'cleric-phb', 10);
select public.expend_character_resource(:'c1', tl_test.rkey(:'c1', 'cleric', 'cleric-divine-intervention-phb-uses'));
select tl_test.rec('CL16 Divine Intervention is restored by hand (a long rest lists it as not restored)',
  (select (public.long_rest_character(:'c1') -> 'breakdown' -> 'not_restored') @> '[{"name": "Divine Intervention"}]'::jsonb)
  and (tl_test.res(:'c1', 'cleric-divine-intervention-phb-uses') ->> 'remaining')::int = 0);

-- ---- progression snapshot -------------------------------------------------------------------------------------------------------------
select tl_test.as_root();
create table tl_test.csnap (level int, cd int, cr text, spells int);
grant all on tl_test.csnap to public;
select tl_test.as_user(:'alice');
do $$
declare l int; ch uuid := 'f1c10000-0000-0000-0000-000000000001';
begin
  for l in 1..20 loop
    perform tl_test.setc(ch, 'cleric-phb', l);
    insert into tl_test.csnap values (l,
      coalesce((case when (tl_test.res(ch, 'cleric-channel-divinity-phb-uses') ->> 'active')::boolean then tl_test.res(ch, 'cleric-channel-divinity-phb-uses') ->> 'max' end)::int, 0),
      coalesce((select s ->> 'value' from jsonb_array_elements(tl_test.f(ch) -> 'classes' -> 0 -> 'features') f, jsonb_array_elements(f -> 'scaling') s
                where f ->> 'unlock_id' = 'cleric-phb-u5-destroy-undead'), '-'),
      (select count(*) from jsonb_array_elements(public.get_character_spellbook(ch) -> 'spells') sp, jsonb_array_elements(sp -> 'grants') g
       where g ->> 'source_type' = 'class_feature' and (g ->> 'unlocked')::boolean));
  end loop;
end $$;
select tl_test.rec('CL17 progression snapshot 1-20 (Channel Divinity uses, Destroy Undead CR, unlocked domain spells)',
  (select string_agg(format('%s:%s/%s/%s', level, cd, cr, spells), ' ' order by level) from tl_test.csnap)
  = '1:0/-/2 2:1/-/2 3:1/-/4 4:1/-/4 5:1/1/2/6 6:2/1/2/6 7:2/1/2/8 8:2/1/8 9:2/1/10 10:2/1/10 11:2/2/10 12:2/2/10 13:2/2/10 14:2/3/10 '
    '15:2/3/10 16:2/3/10 17:2/4/10 18:3/4/10 19:3/4/10 20:3/4/10',
  (select string_agg(format('%s:%s/%s/%s', level, cd, cr, spells), ' ' order by level) from tl_test.csnap));

-- ---- multiclass ----------------------------------------------------------------------------------------------------------------------
select tl_test.setc(:'c2', 'rogue-phb', 2);
select tl_test.setc(:'c2', 'cleric-phb', 1, 'cleric-life-phb');
select tl_test.rec('CL18 Cleric as a second class: no WIS / CHA saves; medium armor and shields; no simple weapons from the Cleric; domain spells still granted',
  not coalesce((tl_test.d(:'c2') -> 'saving_throws' -> 'cha' ->> 'class_proficient')::boolean, false)
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'c2') -> 'proficiencies') p where p ->> 'group_id' = 'medium-armor')
  and not exists (select 1 from jsonb_array_elements(tl_test.d(:'c2') -> 'proficiencies') p where p ->> 'group_id' = 'simple-weapons' and p ->> 'notes' like 'Cleric%')
  and (tl_test.granted(:'c2', 'bless-phb') ->> 'always_prepared')::boolean);

select tl_test.as_user(:'bob');
select tl_test.rec('CL19 an outsider cannot read the Cleric spellbook or spend Channel Divinity',
  tl_test.raises($$select public.get_character_spellbook('f1c10000-0000-0000-0000-000000000001')$$) is not null
  and tl_test.raises($$select public.expend_character_resource('f1c10000-0000-0000-0000-000000000001', 'f:' || gen_random_uuid() || ':cleric-channel-divinity-phb-uses')$$) is not null);
select tl_test.as_root();
