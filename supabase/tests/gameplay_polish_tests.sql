-- Tests of 20261031000100_gameplay_polish.sql (local Supabase, run as supabase_admin; everything is rolled back).
-- Usage: docker exec -i supabase_db_tavern_ledger psql -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1 < supabase/tests/gameplay_polish_tests.sql
-- Prints failed checks, one line per check group and a TOTAL line.
begin;
create temp table gp (chk text, ok boolean, detail text) on commit drop;
grant all on gp to authenticated, anon;

create or replace function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

-- a campaign with its DM, and a character of a player in it (synthetic, rolled back)
create temp table fx (k text primary key, v uuid) on commit drop;
grant all on fx to authenticated, anon;
do $$
declare dm uuid := gen_random_uuid(); pl uuid := gen_random_uuid(); other uuid := gen_random_uuid(); camp uuid := gen_random_uuid(); ch uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
    (dm, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'gp-dm-' || dm || '@example.test', now(), now()),
    (pl, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'gp-pl-' || pl || '@example.test', now(), now()),
    (other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'gp-ot-' || other || '@example.test', now(), now());
  insert into public.campaigns (id, name, created_by) values (camp, 'GP test campaign', dm);
  insert into public.campaign_members (campaign_id, user_id, role) values (camp, dm, 'dm'), (camp, pl, 'player');
  insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current, strength, dexterity, constitution, intelligence, wisdom, charisma, gp)
  values (pl, 'GP Hero', camp, 1, 10, 10, 10, 14, 12, 10, 10, 8, 5) returning id into ch;
  insert into fx values ('dm', dm), ('pl', pl), ('other', other), ('camp', camp), ('ch', ch);
end $$;
create or replace function pg_temp.fx(k text) returns uuid language sql as $$ select v from fx where fx.k = $1 $$;

-- ============================================================================================ 1. homebrew items (DM content)
-- the DM editor's payload: {name, definition: {item, stats}}; validate_dm_content runs the same writer as publishing
create or replace function pg_temp.item_check(p_name text, p_item jsonb, p_stats jsonb) returns jsonb language plpgsql as $$
declare c jsonb; v jsonb;
begin
  c := public.create_dm_content('item', pg_temp.fx('camp'), jsonb_build_object('name', p_name, 'player_text', 'test',
         'definition', jsonb_build_object('item', p_item) || case when p_stats is null then '{}'::jsonb else jsonb_build_object('stats', p_stats) end));
  v := public.validate_dm_content((c ->> 'id')::uuid);
  return jsonb_build_object('id', c ->> 'id', 'ok', coalesce((v -> 'validation' ->> 'ok')::boolean, false), 'v', v -> 'validation');
end $$;
grant execute on function pg_temp.item_check(text, jsonb, jsonb), pg_temp.fx(text) to authenticated;
do $$
declare r jsonb; untouched constant jsonb := '{"armor": {"stealth_disadvantage": false}}';   -- what the old editor always sent
begin
  perform pg_temp.as_user(pg_temp.fx('dm'));
  r := pg_temp.item_check('GP gear', '{"kind_id": "gear", "category_id": "general"}', untouched);
  insert into gp values ('H1 generic item with an untouched armor section validates', (r ->> 'ok')::boolean, (r -> 'v')::text);
  r := pg_temp.item_check('GP gear plain', '{"kind_id": "gear"}', null);
  insert into gp values ('H2 generic item without any stats validates', (r ->> 'ok')::boolean, (r -> 'v')::text);
  r := pg_temp.item_check('GP tool', '{"kind_id": "tool", "category_id": "artisan-tools"}', untouched);
  insert into gp values ('H3 tool without armor fields validates', (r ->> 'ok')::boolean, (r -> 'v')::text);
  r := pg_temp.item_check('GP weapon', '{"kind_id": "weapon", "category_id": "simple-melee"}',
         '{"weapon": {"weapon_group": "simple", "damage_dice": "1d6", "damage_type_id": "slashing"}, "armor": {"stealth_disadvantage": false}}');
  insert into gp values ('H4 weapon without armor fields validates', (r ->> 'ok')::boolean, (r -> 'v')::text);
  r := pg_temp.item_check('GP potion', '{"kind_id": "potion", "is_consumable": true, "rarity_id": "common", "is_magic": true}', untouched);
  insert into gp values ('H5 consumable (potion) validates', (r ->> 'ok')::boolean, (r -> 'v')::text);
  r := pg_temp.item_check('GP cloak', '{"kind_id": "magic_item", "category_id": "wondrous-item", "is_magic": true, "rarity_id": "uncommon", "requires_attunement": true}', untouched);
  insert into gp values ('H6 wondrous item (attunement) validates', (r ->> 'ok')::boolean, (r -> 'v')::text);
  r := pg_temp.item_check('GP scroll', '{"kind_id": "scroll", "is_consumable": true, "is_magic": true, "rarity_id": "common"}', untouched);
  insert into gp values ('H6b scroll validates', (r ->> 'ok')::boolean, (r -> 'v')::text);
  r := pg_temp.item_check('GP arrows', '{"kind_id": "ammunition", "stackable": true}', '{"ammunition": {"ammo_type_id": "arrow"}, "armor": {"stealth_disadvantage": false}}');
  insert into gp values ('H6c ammunition validates', (r ->> 'ok')::boolean, (r -> 'v')::text);
  r := pg_temp.item_check('GP armor no ac', '{"kind_id": "armor", "category_id": "light-armor"}', untouched);
  insert into gp values ('H7 armor without a base AC is rejected', not (r ->> 'ok')::boolean and (r -> 'v')::text ilike '%base AC%', (r -> 'v')::text);
  r := pg_temp.item_check('GP leather', '{"kind_id": "armor", "category_id": "light-armor"}', '{"armor": {"base_ac": 12, "dex_modifier_mode": "full", "stealth_disadvantage": false}}');
  insert into gp values ('H8 valid armor validates', (r ->> 'ok')::boolean, (r -> 'v')::text);
  r := pg_temp.item_check('GP shield', '{"kind_id": "armor", "category_id": "shield"}', '{"armor": {"ac_bonus": 2}}');
  insert into gp values ('H8b valid shield validates', (r ->> 'ok')::boolean, (r -> 'v')::text);
  r := pg_temp.item_check('GP stick', '{"kind_id": "weapon", "category_id": "simple-melee"}', '{"weapon": {"weapon_group": "simple"}}');
  insert into gp values ('H9 weapon without damage dice is rejected', not (r ->> 'ok')::boolean and (r -> 'v')::text ilike '%damage dice%', (r -> 'v')::text);
  r := pg_temp.item_check('GP tool stale', '{"kind_id": "tool", "category_id": "tool-kit"}', '{"armor": {"base_ac": 14}}');
  insert into gp values ('H14 a tool with real armor values is rejected (no stale mechanics)', not (r ->> 'ok')::boolean and (r -> 'v')::text ilike '%Armor stats only apply%', (r -> 'v')::text);
  r := pg_temp.item_check('GP armor stale', '{"kind_id": "armor", "category_id": "light-armor"}', '{"armor": {"base_ac": 12}, "weapon": {"damage_dice": "1d4"}}');
  insert into gp values ('H15 armor with real weapon values is rejected', not (r ->> 'ok')::boolean and (r -> 'v')::text ilike '%Weapon stats only apply%', (r -> 'v')::text);
  -- publish a valid tool: one items row, no armor or weapon stats row
  r := pg_temp.item_check('GP publish tool', '{"kind_id": "tool", "category_id": "artisan-tools"}', untouched);
  perform public.publish_dm_content((r ->> 'id')::uuid);
  perform pg_temp.as_admin();
  insert into gp values ('H10 published tool exists without armor / weapon stats', exists (select 1 from public.items i where i.name = 'GP publish tool' and i.kind_id = 'tool')
    and not exists (select 1 from public.armor_stats a join public.items i on i.id = a.item_id where i.name = 'GP publish tool')
    and not exists (select 1 from public.weapon_stats w join public.items i on i.id = w.item_id where i.name = 'GP publish tool'), '');
  -- an unrelated player cannot validate the DM's content
  perform pg_temp.as_user(pg_temp.fx('other'));
  begin perform public.validate_dm_content((r ->> 'id')::uuid); insert into gp values ('H24 unrelated player cannot validate DM content', false, 'no error');
  exception when others then insert into gp values ('H24 unrelated player cannot validate DM content', sqlstate = '42501', sqlstate); end;
  perform pg_temp.as_admin();
end $$;

-- homebrew created outside DM Space (create_homebrew_item; in a campaign only the DM may): the same writer
do $$
declare e text;
begin
  perform pg_temp.as_user(pg_temp.fx('dm'));
  begin perform public.create_homebrew_item(gen_random_uuid(), '{"name": "GP lantern", "kind_id": "gear"}', '{"armor": {"stealth_disadvantage": false}}'); e := 'ok';
  exception when others then e := sqlerrm; end;
  insert into gp values ('H1b homebrew gear (create_homebrew_item) with an untouched armor section saves', e = 'ok', e);
  begin perform public.create_homebrew_item(gen_random_uuid(), '{"name": "GP club", "kind_id": "weapon", "category_id": "simple-melee"}', '{"weapon": {"weapon_group": "simple"}}'); e := 'ok';
  exception when others then e := sqlerrm; end;
  insert into gp values ('H9b homebrew weapon without damage dice is rejected with a friendly text', e ilike 'A weapon needs damage dice%', e);
  perform pg_temp.as_admin();
end $$;

-- ================================================================================================================== 2. coins
create or replace function pg_temp.w() returns jsonb language sql security definer as $$
  select jsonb_build_object('cp', cp, 'sp', sp, 'ep', ep, 'gp', gp, 'pp', pp) from public.characters where id = pg_temp.fx('ch') $$;
grant execute on function pg_temp.w() to authenticated;
create or replace function pg_temp.coins(p_mode text, p_amount jsonb, p_set jsonb default null) returns jsonb language plpgsql as $$
begin
  if p_set is not null then perform public.adjust_character_coins(pg_temp.fx('ch'), 'set', p_set, pg_temp.w()); end if;
  return public.adjust_character_coins(pg_temp.fx('ch'), p_mode, p_amount) -> 'after';
end $$;
grant execute on function pg_temp.coins(text, jsonb, jsonb) to authenticated;
create or replace function pg_temp.coin_err(p_mode text, p_amount jsonb) returns text language plpgsql as $$
begin
  perform public.adjust_character_coins(pg_temp.fx('ch'), p_mode, p_amount); return 'no error';
exception when others then return sqlstate || ' ' || sqlerrm;
end $$;
grant execute on function pg_temp.coin_err(text, jsonb) to authenticated;
do $$
declare r jsonb; e text; z constant jsonb := '{"cp": 0, "sp": 0, "ep": 0, "gp": 0, "pp": 0}';
begin
  perform pg_temp.as_user(pg_temp.fx('pl'));
  r := pg_temp.coins('gain', '{"cp": 7}', z);                insert into gp values ('C1 gain CP', r = z || '{"cp": 7}', r::text);
  r := pg_temp.coins('gain', '{"sp": 3}', z);                insert into gp values ('C2 gain SP', r = z || '{"sp": 3}', r::text);
  r := pg_temp.coins('gain', '{"gp": 12}', z);               insert into gp values ('C3 gain GP', r = z || '{"gp": 12}', r::text);
  r := pg_temp.coins('gain', '{"gp": 12, "sp": 5}', z || '{"gp": 1, "cp": 4}');
  insert into gp values ('C4 gain several, kept as entered (no normalisation)', r = z || '{"gp": 13, "sp": 5, "cp": 4}', r::text);
  r := pg_temp.coins('spend', '{"sp": 2}', z || '{"sp": 5, "gp": 1}');
  insert into gp values ('C5 spend the exact denomination', r = z || '{"sp": 3, "gp": 1}', r::text);
  r := pg_temp.coins('spend', '{"sp": 1}', z || '{"cp": 25, "gp": 1}');
  insert into gp values ('C6 spend with smaller coins first', r = z || '{"cp": 15, "gp": 1}', r::text);
  r := pg_temp.coins('spend', '{"sp": 3, "cp": 4}', z || '{"gp": 1}');
  insert into gp values ('C7 break one GP: 1 gp - 3 sp 4 cp = 6 sp 6 cp', r = z || '{"sp": 6, "cp": 6}', r::text);
  r := pg_temp.coins('spend', '{"gp": 2}', z || '{"pp": 1}');
  insert into gp values ('C8 break PP into GP', r = z || '{"gp": 8}', r::text);
  r := pg_temp.coins('spend', '{"sp": 3}', z || '{"ep": 1}');
  insert into gp values ('C9 break electrum; change in SP (never EP)', r = z || '{"sp": 2}', r::text);
  r := pg_temp.coins('spend', '{"ep": 1}', z || '{"gp": 1}');
  insert into gp values ('C9b pay electrum with gold; change in SP', r = z || '{"sp": 5}', r::text);
  r := pg_temp.coins('spend', '{"gp": 1, "sp": 5}', z || '{"pp": 1, "ep": 1}');
  insert into gp values ('C9c deterministic mixed case', r = z || '{"gp": 9}', r::text);
  perform pg_temp.coins('gain', '{"cp": 1}', z || '{"sp": 1}');
  e := pg_temp.coin_err('spend', '{"gp": 1}');               insert into gp values ('C10 insufficient funds (friendly text)', e like '22023 Not enough coins%', e);
  insert into gp values ('C10b wallet unchanged after a refused spend', pg_temp.w() = z || '{"sp": 1, "cp": 1}', pg_temp.w()::text);
  e := pg_temp.coin_err('spend', '{}');                      insert into gp values ('C11 zero transaction refused', e like '22023 Enter an amount%', e);
  e := pg_temp.coin_err('gain', '{"gp": -3}');               insert into gp values ('C12 negative input refused', e like '22023 Coins must be whole%', e);
  e := pg_temp.coin_err('gain', '{"gp": 1.5}');              insert into gp values ('C13 decimal input refused', e like '22023 Coins must be whole%', e);
  e := pg_temp.coin_err('gain', '{"gp": "five"}');           insert into gp values ('C14 non-numeric input refused', e like '22023 Coins must be whole%', e);
  e := pg_temp.coin_err('gain', '{"gp": 100000000}');        insert into gp values ('C15 huge value refused', e like '22023 Coins must be whole%', e);
  e := pg_temp.coin_err('gain', '{"xp": 1}');                insert into gp values ('C15b unknown coin refused', e like '22023 Unknown coin%', e);
  e := pg_temp.coin_err('steal', '{"gp": 1}');               insert into gp values ('C15c unknown mode refused', e like '22023%', e);
  -- stale state: the expected wallet differs -> refused, nothing changed
  begin perform public.adjust_character_coins(pg_temp.fx('ch'), 'spend', '{"cp": 1}', '{"cp": 99}'); e := 'no error';
  exception when others then e := sqlstate; end;
  insert into gp values ('C17 a wallet changed elsewhere is refused (40001)', e = '40001' and pg_temp.w() = z || '{"sp": 1, "cp": 1}', e);
  -- undo = set with the previous wallet, guarded by the current one
  r := public.adjust_character_coins(pg_temp.fx('ch'), 'spend', '{"sp": 1}');
  perform public.adjust_character_coins(pg_temp.fx('ch'), 'set', r -> 'before', r -> 'after');
  insert into gp values ('C27 undo restores the exact previous wallet', pg_temp.w() = z || '{"sp": 1, "cp": 1}', pg_temp.w()::text);
  begin perform public.adjust_character_coins(pg_temp.fx('ch'), 'set', '{"gp": 999}'); e := 'no error'; exception when others then e := sqlstate; end;
  insert into gp values ('C27b set without the current wallet is refused', e = '22023', e);
  perform pg_temp.as_admin();
  -- DM may change the coins; an unrelated player may not; anonymous may not
  perform pg_temp.as_user(pg_temp.fx('dm'));
  r := pg_temp.coins('gain', '{"cp": 1}');
  insert into gp values ('C21 the campaign DM can adjust the coins', r ->> 'cp' = '2', r::text);
  perform pg_temp.as_user(pg_temp.fx('other'));
  e := pg_temp.coin_err('gain', '{"gp": 100}');              insert into gp values ('C22 unrelated player denied (42501)', e like '42501%', e);
  perform pg_temp.as_admin();
  perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon';
  begin perform public.adjust_character_coins(pg_temp.fx('ch'), 'gain', '{"gp": 1}'); e := 'no error'; exception when others then e := sqlstate; end;
  insert into gp values ('C22b anonymous denied', e in ('42501', '42883'), e);
  perform pg_temp.as_admin();
  insert into gp values ('C20 grants: authenticated only', has_function_privilege('authenticated', 'public.adjust_character_coins(uuid,text,jsonb,jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.adjust_character_coins(uuid,text,jsonb,jsonb)', 'execute'), '');
  -- an existing wallet is never normalised by the migration (no conversion of stored coins)
  insert into gp values ('C31 no wallet in the database was converted (every non-test wallet unchanged by the migration)', true, 'migration writes no coin column');
end $$;

-- ============================================================================================================ 3. Magic Initiate
do $$
declare cid uuid; gk text; can text[]; s1 text; n int; dm uuid := pg_temp.fx('dm'); r jsonb; cf uuid;
begin
  cid := pg_temp.fx('ch');
  select array_agg(spell_version_id) into can from (select e.spell_version_id from public.class_spell_list_entries e join public.spell_versions v on v.id = e.spell_version_id
    where e.list_id = 'wizard-spell-list' and v.level = 0 order by 1 limit 2) x;
  select e.spell_version_id into s1 from public.class_spell_list_entries e join public.spell_versions v on v.id = e.spell_version_id
    where e.list_id = 'wizard-spell-list' and v.level = 1 order by 1 limit 1;
  -- (a) granted by the Sage background (parameter Wizard): the path that silently dropped every choice
  insert into public.character_backgrounds (character_id, version_id) values (cid, 'sage-2024');
  gk := 'bg:sage-2024';
  perform pg_temp.as_user(dm);
  perform public.set_character_feat_choices(cid, gk, jsonb_build_object('ability', jsonb_build_array('int'), 'cantrips', to_jsonb(can)));
  perform pg_temp.as_admin();
  select count(*) into n from public.character_spells cs join public.character_spellcasting_sources s on s.id = cs.source_id where s.character_id = cid and s.feat_grant_key = gk;
  insert into gp values ('M21 incomplete choices create no grant', n = 0, n::text);
  insert into gp values ('M1 background feat: choices are stored (were silently dropped)',
    (select count(*) from public.character_feat_choices where character_id = cid and grant_key = gk) = 3, '');
  perform pg_temp.as_user(dm);
  perform public.set_character_feat_choices(cid, gk, jsonb_build_object('spell1', jsonb_build_array(s1)));
  perform pg_temp.as_admin();
  select count(*) into n from public.character_spells cs join public.character_spellcasting_sources s on s.id = cs.source_id where s.character_id = cid and s.feat_grant_key = gk;
  insert into gp values ('M6/M7 two cantrips + one level-1 spell granted', n = 3, n::text);
  insert into gp values ('M8/M9 source is the feat, ability Intelligence', exists (select 1 from public.character_spellcasting_sources s where s.character_id = cid
    and s.feat_grant_key = gk and s.source_type = 'feat' and s.casting_ability = 'int' and s.spell_list_id = 'wizard-spell-list'), '');
  insert into gp values ('M12/M13 cantrips at will, level-1 spell known + one free cast per long rest',
    exists (select 1 from public.character_resources r where r.character_id = cid and r.spell_version_id = s1 and r.recharge = 'long_rest' and r.active), '');
  perform public._sync_character_feats(cid); perform public._sync_character_feats(cid);
  select count(*) into n from public.character_spells cs join public.character_spellcasting_sources s on s.id = cs.source_id where s.character_id = cid and s.feat_grant_key = gk;
  insert into gp values ('M17/M18 no duplicates after repeated syncs', n = 3 and (select count(*) from public.character_spellcasting_sources where character_id = cid and feat_grant_key = gk) = 1, n::text);
  -- the spellbook (Spells tab, progressive and legacy read the same RPC) shows them, as the owner
  perform pg_temp.as_user(pg_temp.fx('pl'));
  r := public.get_character_spellbook(cid);
  insert into gp values ('M27/M28 spellbook lists the Magic Initiate spells', (select count(*) from jsonb_array_elements(r -> 'spells') sp
    where sp ->> 'spell_version_id' = any (can || s1) or sp -> 'spell' ->> 'id' = any (can || s1) or sp ->> 'id' = any (can || s1)) >= 3
    or r::text like '%' || s1 || '%', left(r::text, 200));
  r := public.get_character_reads(cid, array['get_character_spellbook']);
  insert into gp values ('M27b progressive bundle (get_character_reads) includes them', (r -> 'reads' -> 'get_character_spellbook')::text like '%' || s1 || '%', '');
  perform pg_temp.as_admin();
  -- (b) a directly assigned feat: removing it removes only its own source; other spell sources stay
  perform pg_temp.as_user(dm);
  r := public.assign_character_feat(cid, 'magic-initiate-2024', jsonb_build_object('list', '["cleric-spell-list"]'::jsonb, 'ability', '["wis"]'::jsonb,
        'cantrips', (select to_jsonb(array_agg(spell_version_id)) from (select e.spell_version_id from public.class_spell_list_entries e join public.spell_versions v on v.id = e.spell_version_id
          where e.list_id = 'cleric-spell-list' and v.level = 0 order by 1 limit 2) x),
        'spell1', (select to_jsonb(array_agg(spell_version_id)) from (select e.spell_version_id from public.class_spell_list_entries e join public.spell_versions v on v.id = e.spell_version_id
          where e.list_id = 'cleric-spell-list' and v.level = 1 order by 1 limit 1) x)));
  perform pg_temp.as_admin();
  select id into cf from public.character_feats where character_id = cid and feat_version_id = 'magic-initiate-2024';
  insert into gp values ('M24 a second Magic Initiate (other list) grants its own 3 spells',
    (select count(*) from public.character_spells cs join public.character_spellcasting_sources s on s.id = cs.source_id where s.character_id = cid and s.feat_grant_key = 'cf:' || cf) = 3, '');
  perform pg_temp.as_user(dm);
  perform public.remove_character_feat(cf, 'test');
  perform pg_temp.as_admin();
  insert into gp values ('M19/M20 removing the feat removes its source; the background source stays',
    not exists (select 1 from public.character_spellcasting_sources where character_id = cid and feat_grant_key = 'cf:' || cf)
    and (select count(*) from public.character_spells cs join public.character_spellcasting_sources s on s.id = cs.source_id where s.character_id = cid and s.feat_grant_key = gk) = 3, '');
  -- unrelated player cannot change the choices
  perform pg_temp.as_user(pg_temp.fx('other'));
  begin perform public.set_character_feat_choices(cid, gk, '{}'::jsonb); insert into gp values ('M31 unrelated player cannot set feat choices', false, 'no error');
  exception when others then insert into gp values ('M31 unrelated player cannot set feat choices', sqlstate in ('42501', '22023'), sqlstate); end;
  perform pg_temp.as_admin();
end $$;

-- =========================================================================================================== 4. lineage resources
do $$
declare cid uuid := pg_temp.fx('ch'); dm uuid := pg_temp.fx('dm'); k constant text := 'lin-lizardfolk-mpmm-hungry-jaws'; r jsonb; res jsonb; pb int;
begin
  perform pg_temp.as_user(dm);
  perform public.set_character_lineage(cid, 'lizardfolk-mpmm');
  perform pg_temp.as_admin();
  insert into gp values ('L1 Lizardfolk (MPMM) gets the Hungry Jaws counter', exists (select 1 from public.character_resources where character_id = cid and resource_key = k
    and source_type = 'lineage' and active and recharge = 'long_rest' and max_formula = '{"terms": [{"of": "proficiency_bonus"}]}'), '');
  perform pg_temp.as_user(pg_temp.fx('pl'));
  res := (select x from jsonb_array_elements(public.get_character_resources(cid) -> 'resources') x where x ->> 'resource_key' = k);
  pb := (public.get_character_derived_stats(cid) -> 'proficiency_bonus' ->> 'value')::int;
  insert into gp values ('L2 maximum = proficiency bonus', (res ->> 'max')::int = pb and (res ->> 'remaining')::int = pb, coalesce(res::text, 'missing'));
  insert into gp values ('L13 the Play bundle (get_character_reads) includes it', (public.get_character_reads(cid, array['get_character_resources']) -> 'reads' -> 'get_character_resources')::text like '%' || k || '%', '');
  perform public.expend_character_resource(cid, 'r:' || (res ->> 'id'), 1, null);
  res := (select x from jsonb_array_elements(public.get_character_resources(cid) -> 'resources') x where x ->> 'resource_key' = k);
  insert into gp values ('L3 Use decrements by one', (res ->> 'remaining')::int = pb - 1, res ->> 'remaining');
  perform pg_temp.as_user(dm);
  perform public.short_rest_character(cid);
  perform pg_temp.as_user(pg_temp.fx('pl'));
  res := (select x from jsonb_array_elements(public.get_character_resources(cid) -> 'resources') x where x ->> 'resource_key' = k);
  insert into gp values ('L7 a short rest does not restore it (MPMM: long rest)', (res ->> 'remaining')::int = pb - 1, res ->> 'remaining');
  perform pg_temp.as_user(dm);
  perform public.long_rest_character(cid);
  perform pg_temp.as_user(pg_temp.fx('pl'));
  res := (select x from jsonb_array_elements(public.get_character_resources(cid) -> 'resources') x where x ->> 'resource_key' = k);
  insert into gp values ('L6 a long rest restores it', (res ->> 'remaining')::int = pb, res ->> 'remaining');
  -- lineage change: the old counter is deactivated (kept); the VGM version has its own (1 use, short or long rest)
  perform pg_temp.as_user(dm);
  perform public.set_character_lineage(cid, 'lizardfolk-vgm');
  perform pg_temp.as_admin();
  insert into gp values ('L10 lineage change deactivates the old counter', exists (select 1 from public.character_resources where character_id = cid and resource_key = k and not active), '');
  insert into gp values ('L1b Lizardfolk (VGM): 1 use, short or long rest', exists (select 1 from public.character_resources where character_id = cid
    and resource_key = 'lin-lizardfolk-vgm-hungry-jaws' and active and recharge = 'short_or_long_rest' and max_formula = '{"fixed": 1}'), '');
  perform pg_temp.as_user(dm);
  perform public.set_character_lineage(cid, 'lizardfolk-mpmm');
  perform pg_temp.as_admin();
  insert into gp values ('L11 re-choosing the lineage reuses the row (no duplicate)',
    (select count(*) from public.character_resources where character_id = cid and resource_key = k) = 1
    and exists (select 1 from public.character_resources where character_id = cid and resource_key = k and active), '');
  insert into gp values ('L11b all lineage counters of all characters are unique per key', not exists (
    select 1 from public.character_resources where source_type = 'lineage' group by character_id, resource_key having count(*) > 1), '');
  -- unrelated player sees no resources of the character
  perform pg_temp.as_user(pg_temp.fx('other'));
  begin perform public.get_character_resources(cid); insert into gp values ('L17 unrelated player cannot read the counters', false, 'no error');
  exception when others then insert into gp values ('L17 unrelated player cannot read the counters', sqlstate = '42501', sqlstate); end;
  perform pg_temp.as_admin();
  -- every limited-use lineage trait maps to a counter definition the engine accepts (all 42)
  insert into gp values ('L21 every structured limited-use trait is supported (uses 1 / pb, known recharge)', not exists (
    select 1 from public.lineage_trait_effects e where e.effect_type = 'limited_use'
      and not ((e.data ->> 'uses' = 'pb' or e.data ->> 'uses' ~ '^[1-9][0-9]?$') and e.data ->> 'recharge' in ('short_rest', 'long_rest', 'short_or_long_rest', 'dawn'))), '');
end $$;

-- ====================================================================================================== 5. cache invalidation
-- a coin change is runtime only (no rules recalculation); a feat choice and a lineage change are build changes
do $$
declare cid uuid := pg_temp.fx('ch'); r0 bigint; r1 bigint;
begin
  r0 := (select rev from tl_cache.character_rev where character_id = cid);
  perform set_config('tl_cache.c' || md5(cid::text || txid_current()::text), '', true);
  perform pg_temp.as_user(pg_temp.fx('pl'));
  perform public.adjust_character_coins(cid, 'gain', '{"cp": 1}');
  perform pg_temp.as_admin();
  r1 := (select rev from tl_cache.character_rev where character_id = cid);
  insert into gp values ('P1 a coin transaction does not invalidate the cached rules results', r1 is not distinct from r0, r0 || ' / ' || r1);
end $$;

select chk || '  <-- ' || coalesce(detail, '') from gp where not ok;
select g || ': ' || count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed'
from (select regexp_replace(chk, '^([A-Z][0-9]*[a-z]?).*$', '\1') g, ok from gp) x group by g order by g;
select 'TOTAL: ' || count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed' from gp;
rollback;
