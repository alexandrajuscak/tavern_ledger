-- =============================================================================
-- Druid (druid-phb) and Circle of the Moon (druid-moon-phb): Wild Shape through the transformation engine (forms from the
-- creature catalog, CR / fly / swim limits by level, uses spent, form hit points with carry-over, one form at a time),
-- Circle Forms, Elemental Wild Shape (two uses), Thousand Forms, Archdruid (unlimited), Wild Companion, companions,
-- progression, multiclass, RLS.
-- =============================================================================
\set d1 f1e00000-0000-0000-0000-000000000001
\set d2 f1e00000-0000-0000-0000-000000000002
\set d3 f1e00000-0000-0000-0000-000000000003
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current) values
  (:'d1', :'alice', 'Druid Tester', :'camp', 10, 14, 14, 12, 16, 10, 20, 20),
  (:'d2', :'alice', 'Moon Druid', null, 10, 14, 14, 12, 16, 10, 30, 30),
  (:'d3', :'alice', 'Fighter then Druid', null, 16, 12, 14, 10, 14, 8, 30, 30);
create function tl_test.tf(p_char uuid) returns jsonb language sql as $$ select public.get_character_transformation(p_char) $$;
create function tl_test.opt(p_char uuid, p_creature text) returns jsonb language sql as $$
  select o from jsonb_array_elements(tl_test.tf(p_char) -> 'options') o where o ->> 'id' = p_creature $$;
grant all on all functions in schema tl_test to public;

select tl_test.rec('DR1 Druid: every class level 1-20 is represented; the creature catalog holds the SRD beasts and the four elementals',
  tl_test.levels_represented('druid-phb') = 20 and (select count(*) from public.creatures where creature_type = 'beast') > 50
  and (select count(*) from public.creatures where id in ('air-elemental', 'earth-elemental', 'fire-elemental', 'water-elemental')) = 4);

select tl_test.as_user(:'alice');
select tl_test.setc(:'d1', 'druid-phb', 1);
select tl_test.rec('DR2 Druid 1: no Wild Shape yet (no rules, no options); Druidic known',
  tl_test.tf(:'d1') -> 'rules' = '[]'::jsonb
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'d1') -> 'languages') l where l ->> 'id' = 'druidic'));
select tl_test.setc(:'d1', 'druid-phb', 2);
select tl_test.rec('DR3 Druid 2: wolf (CR 1/4) allowed; reef shark (swim) refused for swimming, giant eagle for flying (and CR), brown bear for CR',
  (tl_test.opt(:'d1', 'wolf') ->> 'allowed')::boolean and (tl_test.opt(:'d1', 'wolf') ->> 'cost')::int = 1
  and tl_test.opt(:'d1', 'brown-bear') ->> 'reason' = 'challenge_rating'
  and not (tl_test.opt(:'d1', 'giant-eagle') ->> 'allowed')::boolean
  and tl_test.opt(:'d1', 'cat') ->> 'allowed' = 'true' and tl_test.opt(:'d1', 'air-elemental') is null,
  tl_test.opt(:'d1', 'giant-eagle')::text);
select public.start_transformation(:'d1', 'wolf');
select tl_test.rec('DR4 taking the wolf form: one Wild Shape use spent (1 / 2); form HP 11 / 11; a second form is refused',
  (tl_test.res(:'d1', 'druid-wild-shape-phb-uses') ->> 'remaining')::int = 1 and (tl_test.tf(:'d1') -> 'active' ->> 'hp_current')::int = 11
  and tl_test.raises($$select public.start_transformation('f1e00000-0000-0000-0000-000000000001', 'cat')$$) like '%End the current form%');
select public.change_transformation_hp(:'d1', -5);
select tl_test.rec('DR5 5 damage: the wolf has 6 / 11; healing 20 caps at 11',
  (tl_test.tf(:'d1') -> 'active' ->> 'hp_current')::int = 6
  and (public.change_transformation_hp(:'d1', 20) -> 'active' ->> 'hp_current')::int = 11);
select tl_test.rec('DR6 15 damage drops the wolf to 0: the form ends and 4 damage carries over (character HP 20 -> 16)',
  (select (r ->> 'ended')::boolean and (r ->> 'carryover')::int = 4 from (select public.change_transformation_hp(:'d1', -15) r) q));
select tl_test.rec('DR6b afterwards the character has 16 HP and no form', (select hp_current from public.characters where id = :'d1') = 16
  and tl_test.tf(:'d1') -> 'active' = 'null'::jsonb);
select public.start_transformation(:'d1', 'cat');
select public.end_transformation(:'d1');
select tl_test.rec('DR7 both uses spent: a third form is refused (no uses left)',
  tl_test.raises($$select public.start_transformation('f1e00000-0000-0000-0000-000000000001', 'wolf')$$) like '%Not enough%');
select public.short_rest_character(:'d1');
select tl_test.setc(:'d1', 'druid-phb', 4);
select tl_test.rec('DR8 Druid 4 after a short rest: uses back (2 / 2); crocodile (CR 1/2, swims) allowed; giant eagle (flies) still refused',
  (tl_test.res(:'d1', 'druid-wild-shape-phb-uses') ->> 'remaining')::int = 2 and (tl_test.opt(:'d1', 'crocodile') ->> 'allowed')::boolean
  and tl_test.opt(:'d1', 'giant-eagle') ->> 'reason' in ('flying_speed', 'challenge_rating'));
select tl_test.setc(:'d1', 'druid-phb', 8);
select tl_test.rec('DR9 Druid 8: CR 1 forms with flying speed (giant eagle) allowed',
  (tl_test.opt(:'d1', 'giant-eagle') ->> 'allowed')::boolean and (tl_test.opt(:'d1', 'brown-bear') ->> 'allowed')::boolean);

select tl_test.setc(:'d2', 'druid-phb', 2, 'druid-moon-phb');
select tl_test.rec('DR10 Moon 2 (Circle Forms): brown bear (CR 1) allowed; still no flying form; elementals not offered yet',
  (tl_test.opt(:'d2', 'brown-bear') ->> 'allowed')::boolean and not (tl_test.opt(:'d2', 'giant-eagle') ->> 'allowed')::boolean
  and tl_test.opt(:'d2', 'air-elemental') is null);
select tl_test.setc(:'d2', 'druid-phb', 10);
select tl_test.rec('DR11 Moon 10: CR 3 forms (Druid level / 3); the elementals cost two uses',
  (tl_test.opt(:'d2', 'killer-whale') ->> 'allowed')::boolean and (tl_test.opt(:'d2', 'earth-elemental') ->> 'cost')::int = 2,
  tl_test.opt(:'d2', 'killer-whale')::text);
select public.start_transformation(:'d2', 'earth-elemental');
select tl_test.rec('DR12 Elemental Wild Shape spends both uses (0 / 2); the form keeps the elemental hit points (126)',
  (tl_test.res(:'d2', 'druid-wild-shape-phb-uses') ->> 'remaining')::int = 0 and (tl_test.tf(:'d2') -> 'active' ->> 'hp_max')::int = 126);
select public.end_transformation(:'d2');
select tl_test.setc(:'d2', 'druid-phb', 14);
select tl_test.rec('DR13 Thousand Forms: Alter Self at will (no slot)',
  not ((select g from jsonb_array_elements(tl_test.spell(:'d2', 'alter-self-phb') -> 'grants') g where g ->> 'source_type' = 'class_feature' limit 1) ->> 'uses_spell_slot')::boolean);
select tl_test.setc(:'d2', 'druid-phb', 20);
select public.start_transformation(:'d2', 'brown-bear');
select tl_test.rec('DR14 Archdruid: Wild Shape is unlimited (no uses run out)',
  (tl_test.res(:'d2', 'druid-wild-shape-phb-uses') ->> 'unlimited')::boolean and tl_test.tf(:'d2') -> 'active' ->> 'creature_id' = 'brown-bear');
select public.end_transformation(:'d2');

-- ---- progression snapshot (max CR of the base Druid and the Moon) --------------------------------------------------------------
select tl_test.as_root();
create table tl_test.dsnap (level int, base numeric, moon numeric, uses text);
grant all on tl_test.dsnap to public;
select tl_test.as_user(:'alice');
do $$
declare l int;
begin
  for l in 2..20 loop
    perform tl_test.setc('f1e00000-0000-0000-0000-000000000001', 'druid-phb', l);
    perform tl_test.setc('f1e00000-0000-0000-0000-000000000002', 'druid-phb', l, 'druid-moon-phb');
    insert into tl_test.dsnap values (l,
      (select max((r ->> 'max_cr')::numeric) from jsonb_array_elements(tl_test.tf('f1e00000-0000-0000-0000-000000000001') -> 'rules') r),
      (select max((r ->> 'max_cr')::numeric) from jsonb_array_elements(tl_test.tf('f1e00000-0000-0000-0000-000000000002') -> 'rules') r),
      case when (tl_test.res('f1e00000-0000-0000-0000-000000000001', 'druid-wild-shape-phb-uses') ->> 'unlimited')::boolean then 'U'
           else tl_test.res('f1e00000-0000-0000-0000-000000000001', 'druid-wild-shape-phb-uses') ->> 'max' end);
  end loop;
end $$;
select tl_test.rec('DR15 progression snapshot 2-20 (max CR base / Moon, Wild Shape uses)',
  (select string_agg(format('%s:%s/%s/%s', level, base::float, moon::float, uses), ' ' order by level) from tl_test.dsnap)
  = '2:0.25/1/2 3:0.25/1/2 4:0.5/1/2 5:0.5/1/2 6:0.5/2/2 7:0.5/2/2 8:1/2/2 9:1/3/2 10:1/3/2 11:1/3/2 12:1/4/2 13:1/4/2 14:1/4/2 '
    '15:1/5/2 16:1/5/2 17:1/5/2 18:1/6/2 19:1/6/2 20:1/6/U',
  (select string_agg(format('%s:%s/%s/%s', level, base::float, moon::float, uses), ' ' order by level) from tl_test.dsnap));

-- ---- Wild Companion and companions ---------------------------------------------------------------------------------------
select public.set_character_optional_feature(:'d1', tl_test.k(:'d1', 'druid'), 'druid-phb-u2-wild-companion', true);
select tl_test.rec('DR16 Wild Companion (optional): Find Familiar granted without a slot',
  not ((select g from jsonb_array_elements(tl_test.spell(:'d1', 'find-familiar-phb') -> 'grants') g where g ->> 'source_type' = 'class_feature' limit 1) ->> 'uses_spell_slot')::boolean);
select public.add_character_companion(:'d1', 'owl', 'Hoot', 'Wild Companion');
select tl_test.rec('DR17 an owl familiar named Hoot with 1 HP; a custom companion needs a name and hit points',
  (select hp_max = 1 and name = 'Hoot' and creature_id = 'owl' from public.character_companions where character_id = :'d1')
  and tl_test.raises($$select public.add_character_companion('f1e00000-0000-0000-0000-000000000001', null, 'Nameless')$$) like '%custom companion%');
select public.update_character_companion((select id from public.character_companions where character_id = :'d1'), '{"hp_current": 9, "notes": "Scouts ahead"}');
select tl_test.rec('DR18 companion hit points are clamped to the maximum (9 -> 1); notes saved',
  (select hp_current = 1 and notes = 'Scouts ahead' from public.character_companions where character_id = :'d1'));

select tl_test.setc(:'d3', 'fighter-phb', 3);
select tl_test.setc(:'d3', 'druid-phb', 2);
select tl_test.rec('DR19 Druid as a second class: Wild Shape works from Druid level 2; no INT / WIS saves from the Druid',
  (tl_test.opt(:'d3', 'wolf') ->> 'allowed')::boolean and not coalesce((tl_test.d(:'d3') -> 'saving_throws' -> 'wis' ->> 'class_proficient')::boolean, false));
select tl_test.as_user(:'bob');
select tl_test.rec('DR20 an outsider cannot read forms, transform, or add / change / read companions',
  tl_test.raises($$select public.get_character_transformation('f1e00000-0000-0000-0000-000000000001')$$) is not null
  and tl_test.raises($$select public.start_transformation('f1e00000-0000-0000-0000-000000000001', 'wolf')$$) is not null
  and tl_test.raises($$select public.add_character_companion('f1e00000-0000-0000-0000-000000000001', 'owl')$$) is not null
  and tl_test.raises($$select public.update_character_companion((select id from public.character_companions limit 1), '{"hp_current": 0}')$$) is not null
  and not exists (select 1 from public.character_companions where character_id = 'f1e00000-0000-0000-0000-000000000001'));
select tl_test.as_user(:'alice');
select tl_test.rec('DR21 even the owner cannot write companions or forms directly (RPC only)',
  tl_test.raises($$update public.character_companions set hp_max = 99$$) is not null
  and tl_test.raises($$delete from public.character_transformations$$) is not null);
select tl_test.as_root();
