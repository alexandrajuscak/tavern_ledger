-- =============================================================================
-- Wild Shape engine (20261017001300; docs/WILD_SHAPE_RULES.md): eligibility by Druid class level, Circle of the Moon CR,
-- swim / fly limits, seen forms (enforce / warn / DM grant), costs (1, elemental 2, unlimited at 20), rests, the transformed
-- sheet (physical scores from the form, retained mental scores, saves / skills with the higher of your proficiency and the
-- form's, AC), form HP with temporary HP, damage / healing / lethal carry-over / revert, equipment modes, actions and limited
-- abilities, spellcasting (Beast Spells, Archdruid), concentration, Combat Wild Shape healing, RLS, data integrity.
-- =============================================================================
\set w1 f1e10000-0000-0000-0000-000000000001
\set w2 f1e10000-0000-0000-0000-000000000002
\set w3 f1e10000-0000-0000-0000-000000000003
\set w4 f1e10000-0000-0000-0000-000000000004
\set w5 f1e10000-0000-0000-0000-000000000005
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, hp_temp) values
  (:'w1', :'alice', 'Normal Druid', :'camp', 8, 12, 14, 10, 16, 10, 20, 20, 0),
  (:'w2', :'alice', 'Moon Druid', :'camp', 8, 12, 14, 10, 16, 10, 31, 22, 3),
  (:'w3', :'alice', 'Fighter Druid', null, 16, 12, 14, 10, 14, 10, 50, 50, 0),
  (:'w4', :'alice', 'Old Druid', null, 8, 12, 14, 10, 18, 10, 90, 90, 0),
  (:'w5', :'alice', 'Elemental Druid', null, 8, 12, 14, 10, 16, 10, 60, 60, 0);
create function tl_test.ws(p_char uuid) returns jsonb language sql as $$ select public.get_character_transformation(p_char) $$;
create function tl_test.opt(p_char uuid, p_creature text) returns jsonb language sql as $$
  select o from jsonb_array_elements(public.get_character_transformation(p_char) -> 'options') o where o ->> 'id' = p_creature $$;
create function tl_test.allowed(p_char uuid, p_creature text) returns boolean language sql as $$
  select coalesce((tl_test.opt(p_char, p_creature) ->> 'allowed')::boolean, false) $$;
create function tl_test.maxcr(p_char uuid) returns numeric language sql as $$
  select max((r ->> 'max_cr')::numeric) from jsonb_array_elements(public.get_character_transformation(p_char) -> 'rules') r
  where r -> 'creature_types' ? 'beast' $$;
create function tl_test.sheet(p_char uuid) returns jsonb language sql as $$ select public.get_character_transformation(p_char) -> 'active' -> 'sheet' $$;
create function tl_test.wsuses(p_char uuid) returns int language sql as $$
  select (r ->> 'remaining')::int from jsonb_array_elements(public.get_character_resources(p_char) -> 'resources') r
  where r ->> 'resource_id' = 'druid-wild-shape-phb-uses' $$;
create function tl_test.moon_cr_sweep(p_char uuid) returns text language plpgsql as $$
declare l int; want numeric; bad text := '';
begin
  foreach l in array array[3, 4, 6, 8, 9, 12, 15, 18] loop
    perform tl_test.setc(p_char, 'druid-phb', l, 'druid-moon-phb');
    want := case when l < 6 then 1 else floor(l / 3.0) end;
    if tl_test.maxcr(p_char) is distinct from want then bad := bad || format('level %s: %s <> %s; ', l, tl_test.maxcr(p_char), want); end if;
  end loop;
  return bad;
end $$;
grant all on all functions in schema tl_test to public;

select tl_test.as_user(:'alice');
select tl_test.setc(:'w1', 'druid-phb', 1);
select tl_test.rec('WS1 Druid level 1 has no Wild Shape (no rules, no options) and cannot transform',
  jsonb_array_length(tl_test.ws(:'w1') -> 'rules') = 0
  and tl_test.raises(format('select public.start_transformation(%L, ''wolf'')', :'w1')) like '%no feature that lets you change shape%');
select tl_test.setc(:'w1', 'druid-phb', 2);
select tl_test.rec('WS2 Druid 2: maximum CR 1/4 (wolf yes, ape CR 1/2 no, with the reason)',
  tl_test.maxcr(:'w1') = 0.25 and tl_test.allowed(:'w1', 'wolf') and not tl_test.allowed(:'w1', 'ape')
  and tl_test.opt(:'w1', 'ape') -> 'reasons' ->> 0 like 'challenge rating 1/2 is above your maximum 1/4 (Druid level 2)');
select tl_test.rec('WS3 Druid 2: a swimming form is blocked (constrictor snake: swimming forms need Druid level 4)',
  not tl_test.allowed(:'w1', 'constrictor-snake') and tl_test.opt(:'w1', 'constrictor-snake') -> 'reasons' ? 'swimming forms need Druid level 4');
select tl_test.rec('WS4 Druid 2: a flying form is blocked (giant owl: flying forms need Druid level 8)',
  not tl_test.allowed(:'w1', 'giant-owl') and tl_test.opt(:'w1', 'giant-owl') -> 'reasons' ? 'flying forms need Druid level 8');
select tl_test.setc(:'w1', 'druid-phb', 4);
select tl_test.rec('WS5-7 Druid 4: CR 1/2; swimming allowed (crocodile); flying still blocked (giant owl)',
  tl_test.maxcr(:'w1') = 0.5 and tl_test.allowed(:'w1', 'crocodile') and not tl_test.allowed(:'w1', 'giant-owl'));
select tl_test.setc(:'w1', 'druid-phb', 8);
select tl_test.rec('WS8-9 Druid 8: CR 1; flying allowed (giant eagle, CR 1)',
  tl_test.maxcr(:'w1') = 1 and tl_test.allowed(:'w1', 'giant-eagle') and not tl_test.allowed(:'w1', 'giant-boar'));
select tl_test.rec('WS9b no elemental forms without the Circle of the Moon', tl_test.opt(:'w1', 'air-elemental') is null);

-- Circle of the Moon progression (Druid level, not total level)
select tl_test.setc(:'w2', 'druid-phb', 2, 'druid-moon-phb');
select tl_test.rec('WS10 Moon Druid 2: CR 1 (brown bear), still no swim (giant octopus CR 1 blocked)',
  tl_test.maxcr(:'w2') = 1 and tl_test.allowed(:'w2', 'brown-bear') and not tl_test.allowed(:'w2', 'giant-octopus'));
select tl_test.moon_cr_sweep(:'w2') as moon_sweep \gset
select tl_test.rec('WS11-15 Moon CR by Druid level: 3:1, 4:1, 6:2, 8:2, 9:3, 12:4, 15:5, 18:6', :'moon_sweep' = '', :'moon_sweep');
select tl_test.setc(:'w2', 'druid-phb', 6, 'druid-moon-phb');
select tl_test.rec('WS11b Moon Druid 6: CR 2 (giant boar) but flying still needs level 8 (giant eagle blocked)',
  tl_test.allowed(:'w2', 'giant-boar') and not tl_test.allowed(:'w2', 'giant-eagle'));
select tl_test.setc(:'w3', 'fighter-phb', 6);
select tl_test.setc(:'w3', 'druid-phb', 2);
select tl_test.rec('WS16 a Fighter 6 / Druid 2 (total 8) uses Druid level 2: CR 1/4, no swim, no fly',
  (tl_test.ws(:'w3') ->> 'druid_level')::int = 2 and (tl_test.ws(:'w3') ->> 'total_level')::int = 8 and tl_test.maxcr(:'w3') = 0.25
  and not tl_test.allowed(:'w3', 'crocodile') and not tl_test.allowed(:'w3', 'ape'));

-- seen forms
select public.set_wild_shape_settings(:'w1', 'enforce');
select tl_test.rec('WS17 enforce: an unseen eligible form is locked with a reason; marking it seen unlocks it',
  not tl_test.allowed(:'w1', 'wolf') and tl_test.opt(:'w1', 'wolf') ->> 'status' = 'unseen_locked'
  and tl_test.raises(format('select public.start_transformation(%L, ''wolf'')', :'w1')) like '%not seen this beast%'
  and (select (o ->> 'allowed')::boolean from jsonb_array_elements(public.set_seen_forms(:'w1', '{wolf}') -> 'options') o where o ->> 'id' = 'wolf'));
select public.set_wild_shape_settings(:'w1', 'warn');
select tl_test.rec('WS18 warn: an unseen eligible form is allowed and marked eligible_unseen',
  tl_test.allowed(:'w1', 'panther') and tl_test.opt(:'w1', 'panther') ->> 'status' = 'eligible_unseen');
select tl_test.rec('WS19 a DM grant: only the DM may grant it (the player is refused in a campaign); granted, an ineligible form is allowed',
  tl_test.raises(format('select public.set_seen_forms(%L, ''{giant-boar}'', true, ''dm_grant'')', :'w1')) like '%Only the DM%'
  and tl_test.raises(format('select public.set_wild_shape_settings(%L, ''unrestricted'')', :'w1')) like '%Only the DM%');
select tl_test.as_user(:'dm');
select public.set_seen_forms(:'w1', '{giant-boar}', true, 'dm_grant', 'Gift of the grove');
select tl_test.as_user(:'alice');
select tl_test.rec('WS19b the DM-granted giant boar (CR 2, above the maximum) is allowed and labelled dm_granted',
  tl_test.allowed(:'w1', 'giant-boar') and tl_test.opt(:'w1', 'giant-boar') ->> 'status' = 'dm_granted');

-- costs and the resource
select tl_test.wsuses(:'w1') as before_uses \gset
select public.start_transformation(:'w1', 'wolf', '{"equipment": {"mode": "merge"}}');
select tl_test.rec('WS20 a transformation spends one Wild Shape use and records the duration (Druid 8: 4 hours)',
  tl_test.wsuses(:'w1') = :'before_uses'::int - 1 and (tl_test.sheet(:'w1') -> 'duration' ->> 'max_minutes')::int = 240
  and exists (select 1 from public.character_transformation_events where character_id = :'w1' and event_type = 'transformed'));
select tl_test.rec('WS20b a second form is refused while one is active',
  tl_test.raises(format('select public.start_transformation(%L, ''panther'')', :'w1')) like '%End the current form first%');
select public.end_transformation(:'w1');
select public.start_transformation(:'w1', 'panther');
select public.end_transformation(:'w1');
select tl_test.rec('WS22 with no uses left a transformation is refused',
  tl_test.wsuses(:'w1') = 0 and tl_test.raises(format('select public.start_transformation(%L, ''wolf'')', :'w1')) like '%Not enough Wild Shape%');
select public.short_rest_character(:'w1');
select tl_test.rec('WS24 a short rest restores Wild Shape (2 / 2)', tl_test.wsuses(:'w1') = 2);
select public.start_transformation(:'w1', 'wolf');
select public.end_transformation(:'w1');
select public.long_rest_character(:'w1');
select tl_test.rec('WS25 a long rest restores Wild Shape too', tl_test.wsuses(:'w1') = 2);

select tl_test.setc(:'w5', 'druid-phb', 10, 'druid-moon-phb');
select tl_test.rec('WS21a Moon 10: the four elementals are options at cost 2, marked elemental',
  (select count(*) from jsonb_array_elements(tl_test.ws(:'w5') -> 'options') o where (o ->> 'elemental')::boolean and (o ->> 'cost')::int = 2) = 4);
select public.start_transformation(:'w5', 'earth-elemental');
select tl_test.rec('WS21 Elemental Wild Shape spends two uses; the sheet uses the elemental''s HP and is marked elemental',
  tl_test.wsuses(:'w5') = 0 and (tl_test.sheet(:'w5') -> 'hp' ->> 'max')::int = 126 and (tl_test.sheet(:'w5') -> 'creature' ->> 'elemental')::boolean);
select public.end_transformation(:'w5');
select public.short_rest_character(:'w5');
select public.start_transformation(:'w5', 'brown-bear');
select public.end_transformation(:'w5');
select tl_test.rec('WS22b an elemental needs two uses: with one left it is refused',
  tl_test.wsuses(:'w5') = 1 and tl_test.raises(format('select public.start_transformation(%L, ''fire-elemental'')', :'w5')) like '%Not enough Wild Shape%');
select tl_test.setc(:'w4', 'druid-phb', 20);
select public.start_transformation(:'w4', 'brown-bear');
select tl_test.rec('WS23 Archdruid: Wild Shape is unlimited (no use spent)',
  exists (select 1 from jsonb_array_elements(public.get_character_resources(:'w4') -> 'resources') r
          where r ->> 'resource_id' = 'druid-wild-shape-phb-uses' and (r ->> 'unlimited')::boolean)
  and (select expended from public.character_resources where character_id = :'w4' and feature_resource_id = 'druid-wild-shape-phb-uses') = 0);

-- the transformed sheet (Moon 6, WIS 16, Perception from the class, Athletics by hand with expertise)
select tl_test.choose(:'w2', 'druid', 'druid-phb-u1-proficiencies', 'druid-proficiencies-phb-skills', '{perception,animal_handling}');
update public.characters set skill_proficiencies = '{"athletics": 2}', save_proficiencies = '{"str": true}' where id = :'w2';
select tl_test.give(:'w2', 'leather', 'armor') \gset lea_
select tl_test.give(:'w2', 'shield', 'shield') \gset shd_
select public.start_transformation(:'w2', 'brown-bear', format('{"equipment": {"mode": "merge", "items": {"%s": "wear"}}}', :'shd_give')::jsonb);
select tl_test.rec('WS26-27 physical scores come from the bear (STR 19, DEX 10, CON 16); INT / WIS / CHA stay (WIS 16) with their sources',
  (tl_test.sheet(:'w2') -> 'abilities' -> 'str' ->> 'score')::int = 19 and (tl_test.sheet(:'w2') -> 'abilities' -> 'con' ->> 'score')::int = 16
  and (tl_test.sheet(:'w2') -> 'abilities' -> 'wis' ->> 'score')::int = 16 and tl_test.sheet(:'w2') -> 'abilities' -> 'str' ->> 'source' = 'form'
  and tl_test.sheet(:'w2') -> 'abilities' -> 'wis' ->> 'source' = 'retained'
  and (tl_test.d(:'w2') -> 'abilities' -> 'str' ->> 'score')::int = 19 and (select strength from public.characters where id = :'w2') = 8);
select tl_test.rec('WS28-31 saves: STR (your proficiency) +4 + PB 3 = 7; DEX +0; CON +3; WIS keeps your WIS (+3 + PB 3 class save = 6)',
  (tl_test.sheet(:'w2') -> 'saving_throws' -> 'str' ->> 'total')::int = 7 and (tl_test.sheet(:'w2') -> 'saving_throws' -> 'dex' ->> 'total')::int = 0
  and (tl_test.sheet(:'w2') -> 'saving_throws' -> 'con' ->> 'total')::int = 3 and (tl_test.sheet(:'w2') -> 'saving_throws' -> 'wis' ->> 'total')::int = 6
  and (tl_test.d(:'w2') -> 'saving_throws' -> 'str' ->> 'form_total')::int = 7,
  (tl_test.sheet(:'w2') -> 'saving_throws')::text);
select tl_test.rec('WS32-35 skills: Athletics with your expertise on the bear''s STR (+4 + 6 = 10); Perception: your proficiency (+3 + 3 = 6) beats the bear''s printed +3',
  (tl_test.sheet(:'w2') -> 'skills' -> 'athletics' ->> 'total')::int = 10 and tl_test.sheet(:'w2') -> 'skills' -> 'athletics' ->> 'chosen' = 'character'
  and (tl_test.sheet(:'w2') -> 'skills' -> 'perception' ->> 'total')::int = 6 and (tl_test.sheet(:'w2') -> 'skills' -> 'perception' ->> 'creature_printed')::int = 3
  and tl_test.sheet(:'w2') -> 'skills' -> 'perception' -> 'advantage_traits' ? 'Keen Smell',
  (tl_test.sheet(:'w2') -> 'skills' -> 'perception')::text);
select tl_test.rec('WS36-37 AC: the bear''s natural 11 plus the worn shield +2 = 13; merged leather armor does not count',
  (tl_test.sheet(:'w2') -> 'armor_class' ->> 'value')::int = 13 and (tl_test.d(:'w2') -> 'armor_class' ->> 'value')::int = 13
  and not exists (select 1 from jsonb_array_elements(tl_test.sheet(:'w2') -> 'armor_class' -> 'options') o where o ->> 'kind' = 'worn_armor'),
  (tl_test.sheet(:'w2') -> 'armor_class')::text);
select tl_test.rec('WS47-48 merged armor has no effect; the worn shield keeps working (item effects follow the mode)',
  exists (select 1 from jsonb_array_elements(tl_test.sheet(:'w2') -> 'equipment') e where e ->> 'name' ilike 'leather%' and not (e ->> 'effects_active')::boolean)
  and exists (select 1 from jsonb_array_elements(tl_test.sheet(:'w2') -> 'equipment') e where e ->> 'name' = 'Shield' and (e ->> 'effects_active')::boolean));
select tl_test.rec('WS53-54 senses and movement are the form''s: walk 40, climb 30; passive Perception 16; your character speed is not active',
  (tl_test.sheet(:'w2') -> 'speed' ->> 'walk')::int = 40 and (tl_test.sheet(:'w2') -> 'speed' ->> 'climb')::int = 30
  and (tl_test.sheet(:'w2') -> 'senses' ->> 'passive_perception')::int = 16 and (tl_test.d(:'w2') -> 'speed' ->> 'value')::int = 40);
select tl_test.rec('WS50-51 attacks resolve from the stat block (Bite +5, 1d8+4 piercing) and Multiattack lists Bite and Claws',
  exists (select 1 from jsonb_array_elements(tl_test.sheet(:'w2') -> 'actions') a where a ->> 'name' = 'Bite' and (a ->> 'attack_bonus')::int = 5
          and a -> 'damage' -> 0 ->> 'dice' = '1d8+4')
  and exists (select 1 from jsonb_array_elements(tl_test.sheet(:'w2') -> 'actions') a where a ->> 'name' = 'Multiattack'
              and a -> 'multiattack' @> '[{"action": "Bite"}, {"action": "Claws"}]'::jsonb));
select tl_test.rec('WS55-56 no spellcasting before Beast Spells (reason given); the Concentrating condition is kept and shown',
  not (tl_test.sheet(:'w2') -> 'spellcasting' ->> 'can_cast')::boolean and tl_test.sheet(:'w2') -> 'spellcasting' ->> 'rule' like '%cannot cast%'
  and (tl_test.sheet(:'w2') ->> 'primal_strike')::boolean);

-- HP engine (normal form 22 + 3 temp, bear 34)
select tl_test.rec('WS38 the form has its own HP (34 / 34); the normal form keeps 22 + 3 temporary',
  (tl_test.sheet(:'w2') -> 'hp' ->> 'current')::int = 34 and (tl_test.sheet(:'w2') -> 'hp' ->> 'normal_current')::int = 22
  and (select hp_current from public.characters where id = :'w2') = 22);
select public.damage_active_transformation(:'w2', 10);
select tl_test.rec('WS39 damage reduces the form (34 -> 24); the normal form is untouched',
  (tl_test.sheet(:'w2') -> 'hp' ->> 'current')::int = 24 and (select hp_current from public.characters where id = :'w2') = 22);
select public.heal_active_transformation(:'w2', 5);
select tl_test.rec('WS40-41 healing restores form HP (29) and never above the maximum (heal 50 -> 34)',
  (tl_test.sheet(:'w2') -> 'hp' ->> 'current')::int = 29
  and (public.heal_active_transformation(:'w2', 50) -> 'active' ->> 'hp_current')::int = 34);
select public.set_transformation_hp(:'w2', 5, 2, 'test');
select public.damage_active_transformation(:'w2', 13) as lethal \gset
select tl_test.rec('WS42-43 lethal damage: temp 2 then form 5 absorb 7 of 13; the form ends; 6 carries over once (normal temp 3 first, 22 -> 19)',
  (:'lethal'::jsonb -> 'result' ->> 'ended')::boolean and (:'lethal'::jsonb -> 'result' ->> 'carryover')::int = 6
  and (select hp_current from public.characters where id = :'w2') = 19 and (select hp_temp from public.characters where id = :'w2') = 0
  and not exists (select 1 from public.character_transformations where character_id = :'w2')
  and (select count(*) from public.character_transformation_events where character_id = :'w2' and event_type = 'excess_damage') = 1,
  :'lethal');
select tl_test.rec('WS45-46 after the form ends the normal values are back (STR 8, AC from leather + shield, the character speed)',
  (tl_test.d(:'w2') -> 'abilities' -> 'str' ->> 'score')::int = 8 and (tl_test.d(:'w2') -> 'armor_class' ->> 'value')::int = 14
  and tl_test.d(:'w2') -> 'wild_shape' = 'null'::jsonb);
select public.long_rest_character(:'w2');
select public.start_transformation(:'w2', 'brown-bear', '{"equipment": {"mode": "drop"}}');
select tl_test.rec('WS49 dropped equipment stays in the inventory but is unequipped and not re-equipped automatically',
  not exists (select 1 from public.character_equipment where character_id = :'w2')
  and (select count(*) from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id where i.character_id = :'w2'
       and ii.item_id in ('leather', 'shield')) = 2);
select public.end_transformation(:'w2');
select tl_test.rec('WS44 manual revert: no use spent, the normal HP unchanged (19), still unequipped',
  (select hp_current from public.characters where id = :'w2') = 19 and tl_test.wsuses(:'w2') = 1
  and not exists (select 1 from public.character_equipment where character_id = :'w2'));

-- actions with save DCs and limited abilities (giant spider: Web recharge 5-6; DC on the bite)
select public.start_transformation(:'w2', 'giant-spider');
select tl_test.rec('WS52 action DCs come from the stat block (Bite: DC 11 CON, poison); Web is a recharge ability',
  exists (select 1 from jsonb_array_elements(tl_test.sheet(:'w2') -> 'actions') a where a ->> 'name' = 'Bite'
          and (a -> 'save' ->> 'dc')::int = 11 and a -> 'save' ->> 'ability' = 'CON')
  and exists (select 1 from jsonb_array_elements(tl_test.sheet(:'w2') -> 'actions') a where a ->> 'name' = 'Web'
              and (a -> 'usage' ->> 'min_value')::int = 5 and (a ->> 'available')::boolean));
select public.use_form_ability(:'w2', 'Web', 'use');
select tl_test.rec('WS52b using Web makes it unavailable; a recharge roll of 4 fails, 5 succeeds; it is not a permanent resource',
  tl_test.raises(format('select public.use_form_ability(%L, ''Web'', ''use'')', :'w2')) like '%not available%'
  and not (public.use_form_ability(:'w2', 'Web', 'roll', 4) -> 'result' ->> 'available')::boolean
  and (public.use_form_ability(:'w2', 'Web', 'roll', 5) -> 'result' ->> 'available')::boolean);

-- Combat Wild Shape: a slot heals 1d8 per slot level
select public.set_transformation_hp(:'w2', 10, null, 'test');
select (select (s ->> 'remaining')::int from jsonb_array_elements(public.get_character_spell_slots(:'w2') -> 'standard') s where (s ->> 'slot_level')::int = 2) as slots2 \gset
select public.combat_wild_shape_heal(:'w2', 2, 'standard', 11) as heal \gset
select tl_test.rec('WS59 Combat Wild Shape: a 2nd-level slot is spent once and heals the player''s roll of 11 (10 -> 21)',
  (:'heal'::jsonb -> 'result' ->> 'form_hp_after')::int = 21
  and (select (s ->> 'remaining')::int from jsonb_array_elements(public.get_character_spell_slots(:'w2') -> 'standard') s where (s ->> 'slot_level')::int = 2) = :'slots2'::int - 1);
select tl_test.rec('WS60 a failed healing (impossible roll) spends no slot',
  tl_test.raises(format('select public.combat_wild_shape_heal(%L, 2, ''standard'', 40)', :'w2')) like '%between 2 and 16%'
  and (select (s ->> 'remaining')::int from jsonb_array_elements(public.get_character_spell_slots(:'w2') -> 'standard') s where (s ->> 'slot_level')::int = 2) = :'slots2'::int - 1);
select public.end_transformation(:'w2');

-- Beast Spells (18) and Archdruid (20)
select tl_test.rec('WS57-58 Archdruid at 20: can cast in the form (Beast Spells + Archdruid component rule)',
  (tl_test.sheet(:'w4') -> 'spellcasting' ->> 'can_cast')::boolean and tl_test.sheet(:'w4') -> 'spellcasting' ->> 'feature' = 'Archdruid');
select public.end_transformation(:'w4');
select tl_test.setc(:'w4', 'druid-phb', 18);
select public.start_transformation(:'w4', 'wolf');
select tl_test.rec('WS57 Beast Spells at 18: can cast with verbal and somatic components, no material ones',
  (tl_test.sheet(:'w4') -> 'spellcasting' ->> 'can_cast')::boolean and tl_test.sheet(:'w4') -> 'spellcasting' ->> 'feature' = 'Beast Spells');

-- expiry
select tl_test.as_root();
update public.character_transformations set expires_at = now() - interval '1 minute' where character_id = :'w4';
select tl_test.as_user(:'alice');
select (tl_test.sheet(:'w4') -> 'duration' ->> 'expired') as expired_on_read \gset
select public.damage_active_transformation(:'w4', 1) -> 'result' as expired_result \gset
select tl_test.rec('WS-dur an expired form is flagged on read and ended by the next change (reverted_expired, kept)',
  :'expired_on_read'::boolean and (:'expired_result'::jsonb ->> 'expired')::boolean
  and not exists (select 1 from public.character_transformations where character_id = :'w4')
  and exists (select 1 from public.character_transformation_events where character_id = :'w4' and event_type = 'reverted_expired'),
  :'expired_result');

-- security
select tl_test.as_user(:'bob');
select tl_test.rec('WS63-64 another user can neither transform nor damage, heal, revert or mark forms seen',
  tl_test.raises(format('select public.start_transformation(%L, ''wolf'')', :'w3')) like '%not found%'
  and tl_test.raises(format('select public.damage_active_transformation(%L, 1)', :'w3')) like '%not found%'
  and tl_test.raises(format('select public.heal_active_transformation(%L, 1)', :'w3')) like '%not found%'
  and tl_test.raises(format('select public.end_transformation(%L)', :'w3')) like '%not found%'
  and tl_test.raises(format('select public.set_seen_forms(%L, ''{wolf}'')', :'w3')) like '%not found%'
  and tl_test.raises(format('select public.get_character_transformation(%L)', :'w3')) like '%not found%');
select tl_test.as_user(:'alice');
select tl_test.rec('WS64b direct writes are blocked (form HP, seen forms, events, settings)',
  tl_test.raises(format('update public.character_transformations set hp_max = 999 where character_id = %L', :'w1')) like '%permission denied%'
  and tl_test.raises(format('insert into public.character_seen_forms (character_id, creature_id) values (%L, ''tiger'')', :'w1')) like '%permission denied%'
  and tl_test.raises(format('insert into public.character_transformation_events (character_id, event_type) values (%L, ''healed'')', :'w1')) like '%permission denied%'
  and tl_test.raises(format('insert into public.character_wild_shape_settings (character_id, seen_mode) values (%L, ''unrestricted'')', :'w1')) like '%permission denied%');
select tl_test.rec('WS-forge the RPCs take no HP maximum, ability scores or carry-over from the client (unknown creature refused)',
  tl_test.raises(format('select public.start_transformation(%L, ''brown-bear-xl'')', :'w3')) like '%Unknown creature%');
select tl_test.as_user(:'dm');
select tl_test.rec('WS-dm the campaign DM reads and changes a campaign character''s Wild Shape (settings unrestricted)',
  (public.set_wild_shape_settings(:'w1', 'unrestricted') -> 'settings' ->> 'seen_mode') = 'unrestricted');

-- data integrity
select tl_test.as_root();
select tl_test.rec('WS68 every beast of CR 0-6 and the four elementals have complete structured mechanics (no orphans)',
  not exists (select 1 from public.creatures where ((creature_type = 'beast' and challenge_rating <= 6) or id in ('air-elemental', 'earth-elemental', 'fire-elemental', 'water-elemental'))
              and mechanics_status <> 'complete')
  and not exists (select 1 from public.creatures c, jsonb_array_elements(c.actions) a
                  where c.creature_type = 'beast' and c.challenge_rating <= 6 and a ->> 'name' = 'Multiattack' and not a ? 'multiattack'));
select tl_test.rec('WS69 no orphan transformation state (every row has its character class and creature)',
  not exists (select 1 from public.character_transformations t left join public.character_classes cc on cc.id = t.character_class_id
              left join public.creatures c on c.id = t.creature_id where cc.id is null or c.id is null));
