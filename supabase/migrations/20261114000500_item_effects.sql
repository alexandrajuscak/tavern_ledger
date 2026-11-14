-- R-D1 item effects (docs/ITEM_EFFECTS.md). Additive; rollback supabase/rollback/rollback_item_effects.sql (keeps every DM-authored
-- effect: the new rows are copied to backup tables, never dropped).
--
--  1. item_effects (20261015001400) gets two kinds (initiative_bonus, a numeric skill_bonus), the activation 'permanent' (applied
--     once when a consumable is USED) and an optional max_score for a permanent ability increase (Manual of Bodily Health: 22).
--  2. item_spell_grants: spells an item grants (at will, with the character's spell slots, or N per short / long rest), while
--     owned / equipped / attuned, or permanently when used. Materialized like feat spell grants: one spellcasting source per
--     inventory row (item_grant_key 'ii:<inventory row>'), character_spells, and a character_resources counter per limited grant.
--     _sync_item_spell_grants runs from triggers on every write that can change it (equip, unequip, attune, unattune, use,
--     transfer, drop, give, identification); a grant that stops is removed, its counter only deactivated (expended kept).
--  3. character_permanent_effects: what a used consumable did to a character, exactly once per use (request id), with the source,
--     revertible by the DM (reverted_at; never deleted). Players have no grant on the table: read models mask the source.
--  4. _character_item_effect_rows (SECURITY DEFINER, own access check): the item effects of a character for every viewer, so the
--     player and the DM compute the same numbers; an unidentified item is shown to the player only under its disguise
--     (no item id, an opaque stack group). _character_effects reads it (signature unchanged).
--  5. _derived_stats_core: permanent ability increases (capped), item initiative, numeric skill bonus, the sources of save /
--     skill / initiative / ability bonuses and the inactive effects (as armor_class.inactive_effects already had).
--  6. use_inventory_item(p_item, p_quantity, p_request): applies the permanent effects of a consumed item (idempotent per request).
--  7. revert_permanent_effect (DM), _write_homebrew accepts effects / spells for DM content items only (cc-), validated.
--  8. _character_spell_grants: item grants carry uses, recharge, the remaining count and the counter key.
set lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------------- 0. reapply after a rollback
-- the rollback moved the rows of the new kinds to backup tables: bring them back (copy, then drop the emptied backup)
do $$
begin
  if to_regclass('public.character_permanent_effects') is null and to_regclass('public.character_permanent_effects_rd1_backup') is not null then
    execute 'alter table public.character_permanent_effects_rd1_backup rename to character_permanent_effects';
  end if;
  if to_regclass('public.item_spell_grants') is null and to_regclass('public.item_spell_grants_rd1_backup') is not null then
    execute 'alter table public.item_spell_grants_rd1_backup rename to item_spell_grants';
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------------- 1. item_effects
alter table public.item_effects drop constraint item_effects_effect_type_check;
alter table public.item_effects add constraint item_effects_effect_type_check check (effect_type in (
  'ac_bonus', 'attack_bonus', 'damage_bonus', 'save_bonus', 'ability_bonus', 'ability_override', 'speed_bonus', 'speed_penalty',
  'resistance', 'carrying_capacity_bonus', 'skill_advantage', 'skill_disadvantage', 'initiative_bonus', 'skill_bonus'));
alter table public.item_effects drop constraint item_effects_activation_check;
alter table public.item_effects add constraint item_effects_activation_check
  check (activation in ('owned', 'equipped', 'attuned', 'equipped_and_attuned', 'permanent'));
alter table public.item_effects add column if not exists max_score int check (max_score between 1 and 30);
comment on column public.item_effects.max_score is
  'Permanent ability increases only: the score this increase may reach (default 20; e.g. 22 for a Manual of Bodily Health).';
comment on column public.item_effects.activation is
  'owned / equipped / attuned / equipped_and_attuned: while that holds. permanent: applied once to the character when the consumable is used (character_permanent_effects).';


CREATE OR REPLACE FUNCTION public.item_effects_before_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare abilities constant text[] := array['str', 'dex', 'con', 'int', 'wis', 'cha'];
        skills constant text[] := array['acrobatics', 'animal_handling', 'arcana', 'athletics', 'deception', 'history', 'insight',
          'intimidation', 'investigation', 'medicine', 'nature', 'perception', 'performance', 'persuasion', 'religion',
          'sleight_of_hand', 'stealth', 'survival'];
        k text; attune boolean;
begin
  if new.effect_type in ('ac_bonus', 'attack_bonus', 'damage_bonus', 'speed_bonus', 'speed_penalty', 'carrying_capacity_bonus', 'initiative_bonus') then
    if new.target is not null then raise exception '% takes no target', new.effect_type using errcode = '22023'; end if;
    if new.value is null then raise exception '% needs a value', new.effect_type using errcode = '22023'; end if;
  elsif new.effect_type = 'save_bonus' then
    if new.target is not null and not new.target = any (abilities) then raise exception 'Unknown saving throw "%"', new.target using errcode = '22023'; end if;
    if new.value is null then raise exception 'save_bonus needs a value' using errcode = '22023'; end if;
  elsif new.effect_type in ('ability_bonus', 'ability_override') then
    if new.target is null or not new.target = any (abilities) then raise exception 'Unknown ability "%"', new.target using errcode = '22023'; end if;
    if new.value is null or new.value not between -30 and 30 then raise exception 'Ability value out of range' using errcode = '22023'; end if;
  elsif new.effect_type = 'resistance' then
    if new.target is null or not exists (select 1 from public.damage_types where id = new.target) then
      raise exception 'Unknown damage type "%"', new.target using errcode = '22023';
    end if;
  elsif new.effect_type in ('skill_advantage', 'skill_disadvantage', 'skill_bonus') then
    if new.target is null or not new.target = any (skills) then raise exception 'Unknown skill "%"', new.target using errcode = '22023'; end if;
    if new.effect_type = 'skill_bonus' and (new.value is null or new.value not between -10 and 10) then
      raise exception 'skill_bonus needs a value from -10 to 10' using errcode = '22023';
    end if;
  end if;
  if (new.stacking = 'override') <> (new.effect_type = 'ability_override') then
    raise exception 'Only ability_override uses the override stacking rule' using errcode = '22023';
  end if;
  -- 20261114000500: permanent = applied once when used; an override or a reminder cannot be permanent
  if new.activation = 'permanent' and new.effect_type not in ('ability_bonus', 'ac_bonus', 'save_bonus', 'skill_bonus', 'initiative_bonus', 'speed_bonus') then
    raise exception 'A permanent effect is an ability, AC, saving throw, skill, initiative or speed bonus' using errcode = '22023';
  end if;
  if new.max_score is not null and not (new.effect_type = 'ability_bonus' and new.activation = 'permanent') then
    raise exception 'A maximum score only applies to a permanent ability increase' using errcode = '22023';
  end if;
  for k in select jsonb_object_keys(new.conditions) loop
    if not k = any (array['no_armor', 'no_shield']) or jsonb_typeof(new.conditions -> k) <> 'boolean' then
      raise exception 'Unknown effect condition "%"', k using errcode = '22023';
    end if;
  end loop;
  -- an item that needs attunement never works merely because it is owned or equipped (a used consumable: permanent)
  select requires_attunement into attune from public.items where id = new.item_id;
  if attune and new.activation not in ('attuned', 'equipped_and_attuned', 'permanent') then
    raise exception 'This item requires attunement: use activation attuned or equipped_and_attuned' using errcode = '22023';
  end if;
  return new;
end;
$function$;

-- reapply after a rollback: the rows the rollback copied away come back (checked by the new trigger function above)
do $$
begin
  if to_regclass('public.item_effects_rd1_backup') is not null then
    insert into public.item_effects (item_id, seq, effect_type, value, target, activation, stacking, stack_group, priority, conditions, max_score)
    select b.item_id, b.seq, b.effect_type, b.value, b.target, b.activation, b.stacking, b.stack_group, b.priority, b.conditions, b.max_score
    from public.item_effects_rd1_backup b where exists (select 1 from public.items i where i.id = b.item_id)
    on conflict (item_id, seq) do nothing;
    if not exists (select 1 from public.item_effects_rd1_backup b where not exists (
                     select 1 from public.item_effects e where e.item_id = b.item_id and e.seq = b.seq)) then
      execute 'drop table public.item_effects_rd1_backup';
    end if;
  end if;
end $$;

-- ------------------------------------------------------------------------------------------------------ 2. item_spell_grants
create table if not exists public.item_spell_grants (
  item_id          text not null references public.items (id) on delete cascade,
  seq              int  not null check (seq between 1 and 50),
  spell_version_id text not null references public.spell_versions (id),
  casting          text not null check (casting in ('at_will', 'spell_slots', 'per_rest')),
  uses             int  check (uses between 1 and 20),
  recharge         text check (recharge in ('short_rest', 'long_rest')),
  activation       text not null check (activation in ('owned', 'equipped', 'attuned', 'equipped_and_attuned', 'permanent')),
  ability          text check (ability in ('str', 'dex', 'con', 'int', 'wis', 'cha')),
  primary key (item_id, seq),
  constraint item_spell_grant_uses check ((casting = 'per_rest') = (uses is not null and recharge is not null))
);
comment on table public.item_spell_grants is
  'Spells an item grants (20261114000500): at will, with the character''s spell slots, or N times per short / long rest (own counter). Materialized by _sync_item_spell_grants.';

create or replace function public.item_spell_grants_before_write()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if (select requires_attunement from public.items where id = new.item_id) and new.activation not in ('attuned', 'equipped_and_attuned', 'permanent') then
    raise exception 'This item requires attunement: use activation attuned or equipped_and_attuned' using errcode = '22023';
  end if;
  return new;
end $$;
drop trigger if exists item_spell_grants_before_write on public.item_spell_grants;
create trigger item_spell_grants_before_write before insert or update on public.item_spell_grants
  for each row execute function public.item_spell_grants_before_write();

alter table public.item_spell_grants enable row level security;
drop policy if exists item_spell_grants_read on public.item_spell_grants;
create policy item_spell_grants_read on public.item_spell_grants for select to anon, authenticated using (public.can_view_item(item_id));
revoke all on public.item_spell_grants from public, anon, authenticated;
grant select on public.item_spell_grants to anon, authenticated;            -- writes: _write_homebrew (DM content) only
drop trigger if exists tl_cache_rev on public.item_spell_grants;
create trigger tl_cache_rev after insert or update or delete on public.item_spell_grants
  for each row execute function tl_cache.bump('global');

-- ---------------------------------------------------------------------------------------------- 3. character_permanent_effects
create table if not exists public.character_permanent_effects (
  id               uuid primary key default gen_random_uuid(),
  character_id     uuid not null references public.characters (id) on delete cascade,
  kind             text not null check (kind in ('effect', 'spell')),
  use_request      uuid not null,
  unit             int  not null default 1 check (unit between 1 and 99),
  seq              int  not null,
  source_item_id   text references public.items (id) on delete set null,     -- DM only (no player grant on this table)
  source_true_name text check (length(source_true_name) <= 120),             -- DM only
  source_label     text not null check (length(source_label) between 1 and 120),   -- what the player saw when it was used
  masked           boolean not null default false,                           -- used while unidentified
  effect_type      text check (effect_type in ('ability_bonus', 'ac_bonus', 'save_bonus', 'skill_bonus', 'initiative_bonus', 'speed_bonus')),
  target           text,
  value            numeric,
  max_score        int check (max_score between 1 and 30),
  spell_version_id text references public.spell_versions (id),
  casting          text check (casting in ('at_will', 'spell_slots', 'per_rest')),
  uses             int check (uses between 1 and 20),
  recharge         text check (recharge in ('short_rest', 'long_rest')),
  ability          text check (ability in ('str', 'dex', 'con', 'int', 'wis', 'cha')),
  applied_at       timestamptz not null default now(),
  applied_by       uuid default auth.uid(),
  reverted_at      timestamptz,
  reverted_by      uuid,
  revert_reason    text check (length(revert_reason) <= 300),
  unique (character_id, use_request, unit, kind, seq),
  check ((kind = 'effect') = (effect_type is not null)),
  check ((kind = 'spell') = (spell_version_id is not null and casting is not null))
);
create index if not exists character_permanent_effects_character on public.character_permanent_effects (character_id) where reverted_at is null;
create index if not exists character_permanent_effects_request on public.character_permanent_effects (use_request);
comment on table public.character_permanent_effects is
  'Effects a used consumable applied to a character (20261114000500), once per use request; reverted_at = undone by the DM (never deleted). No player grant: read through get_character_derived_stats (masked).';
alter table public.character_permanent_effects enable row level security;
revoke all on public.character_permanent_effects from public, anon, authenticated;
drop trigger if exists tl_cache_rev on public.character_permanent_effects;
create trigger tl_cache_rev after insert or update or delete on public.character_permanent_effects
  for each row execute function tl_cache.bump('character');
drop trigger if exists character_permanent_effects_revision on public.character_permanent_effects;
create trigger character_permanent_effects_revision after insert or update or delete on public.character_permanent_effects
  for each row execute function public._bump_character_revision();

-- ------------------------------------------------------------------------------------------- 4. spellcasting sources of items
alter table public.character_spellcasting_sources add column if not exists item_grant_key text;
create unique index if not exists character_spellcasting_sources_item on public.character_spellcasting_sources (character_id, item_grant_key)
  where item_grant_key is not null;

-- ------------------------------------------------------------------------------------------------------------ 5. read helpers
-- the label of a permanent row for the caller: the DM (and admins, and internal calls) see the item's true name; a player sees
-- what he saw when it was used, until the character identifies the item
create or replace function public._permanent_effect_label(p public.character_permanent_effects, p_knows_all boolean)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when p_knows_all or not p.masked then coalesce(p.source_true_name, p.source_label)
    when p.source_item_id is not null and exists (select 1 from public.character_item_knowledge k where k.character_id = p.character_id
                                                  and k.item_id = p.source_item_id and k.state = 'identified')
      then coalesce(p.source_true_name, p.source_label)
    else p.source_label end;
$$;

create or replace function public._character_knows_all(p_character uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is null or public.is_admin()
         or exists (select 1 from public.characters c where c.id = p_character and c.campaign_id is not null and public.is_campaign_dm(c.campaign_id));
$$;

-- the active permanent rows of a character (abilities are read by _derived_stats_core, the rest also flows through
-- _character_effects); nothing for a caller who cannot read the character
create or replace function public._character_permanent_effect_rows(p_character uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  with v as (select public.can_access_character(p_character) as ok, public._character_knows_all(p_character) as dm)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'kind', p.kind, 'effect_type', p.effect_type, 'target', p.target, 'value', p.value, 'max_score', p.max_score,
           'spell_version_id', p.spell_version_id, 'spell_name', sv.name, 'casting', p.casting, 'uses', p.uses, 'recharge', p.recharge,
           'source_type', 'permanent', 'source_name', public._permanent_effect_label(p, v.dm), 'applied_at', p.applied_at,
           'item_id', case when v.dm then p.source_item_id end, 'can_revert', v.dm and auth.uid() is not null)
           order by p.applied_at, p.id), '[]'::jsonb)
  from v, public.character_permanent_effects p
  left join public.spell_versions sv on sv.id = p.spell_version_id
  where v.ok and p.character_id = p_character and p.reverted_at is null;
$$;

-- item effects of the character's own inventory, for every viewer alike (SECURITY DEFINER: the items row of an unidentified item
-- is invisible to the player, yet the worn item works). Masking follows v_inventory_detail: an unidentified row of a reader who
-- does not know everything shows only its disguise (display name), no item id, no stack group.
create or replace function public._character_item_effect_rows(p_character uuid)
returns table (source_type text, source_id uuid, item_id text, source_name text, seq int, effect_type text, value numeric, target text,
               activation text, stacking text, stack_group text, priority int, kind_id text, inactive_reason text)
language sql stable security definer set search_path = public, pg_temp as $$
  with v as (select public.can_access_character(p_character) as ok),
  owned as (
    select ii.id, ii.item_id, ii.is_attuned and public._item_active_in_form(p_character, ii.id) as is_attuned,
           coalesce(ii.custom_name, it.name) as plain_name, it.name as true_name,
           coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item') as display_name, it.kind_id, e.slot_id,
           kk.state is not null and kk.state <> 'identified' as unidentified,
           kk.state is not null and kk.state <> 'identified' and auth.uid() is not null and not public._inventory_knows_all(inv.id) as masked
    from v, public.inventories inv
    join public.inventory_items ii on ii.inventory_id = inv.id
    join public.items it on it.id = ii.item_id
    left join public.inventory_item_knowledge kk on kk.inventory_item_id = ii.id
    left join public.character_equipment e on e.inventory_item_id = ii.id and e.character_id = p_character
      and public._item_active_in_form(p_character, ii.id)              -- merged or dropped in Wild Shape: no effect
    where v.ok and inv.character_id = p_character
      and exists (select 1 from public.item_effects x where x.item_id = ii.item_id and x.activation <> 'permanent')
  ),
  worn as (
    select coalesce(bool_or(slot_id = 'armor'), false) as has_armor, coalesce(bool_or(slot_id = 'shield'), false) as has_shield
    from public.character_equipment where character_id = p_character
  )
  select 'item_effect'::text, o.id, case when o.masked then null else o.item_id end,
         case when o.masked then o.display_name when o.unidentified then o.true_name || ' (unidentified)' else o.plain_name end,
         ie.seq, ie.effect_type, ie.value, ie.target, ie.activation, ie.stacking,
         case when o.masked then 'masked:' || md5(p_character::text || ':' || ie.stack_group) else ie.stack_group end, ie.priority, o.kind_id,
         coalesce(
           case ie.activation
             when 'equipped' then case when o.slot_id is null then 'not_equipped' end
             when 'attuned' then case when not o.is_attuned then 'not_attuned' end
             when 'equipped_and_attuned' then case when o.slot_id is null then 'not_equipped' when not o.is_attuned then 'not_attuned' end
           end,
           case when ie.conditions ->> 'no_armor' = 'true' and w.has_armor then 'wearing_armor'
                when ie.conditions ->> 'no_shield' = 'true' and w.has_shield then 'using_shield' end)
  from owned o
  join public.item_effects ie on ie.item_id = o.item_id and ie.activation <> 'permanent'
  cross join worn w
  union all
  -- permanent effects of used consumables (abilities are capped in _derived_stats_core and not repeated here)
  select 'permanent', (x ->> 'id')::uuid, x ->> 'item_id', (x ->> 'source_name') || ' (permanent)', 1, x ->> 'effect_type',
         (x ->> 'value')::numeric, x ->> 'target', 'permanent', 'additive', null, 0, null, null
  from jsonb_array_elements(public._character_permanent_effect_rows(p_character)) x
  where x ->> 'kind' = 'effect' and x ->> 'effect_type' <> 'ability_bonus';
$$;

revoke all on function public._permanent_effect_label(public.character_permanent_effects, boolean), public._character_knows_all(uuid)
  from public, anon, authenticated;
revoke all on function public._character_permanent_effect_rows(uuid), public._character_item_effect_rows(uuid) from public, anon;
grant execute on function public._character_permanent_effect_rows(uuid), public._character_item_effect_rows(uuid) to authenticated;

-- _character_effects: the item branch reads _character_item_effect_rows (same columns as before; modifiers, class features unchanged)
CREATE OR REPLACE FUNCTION public._character_effects(p_character uuid)
 RETURNS TABLE(source_type text, source_id uuid, item_id text, source_name text, modifier_id text, seq integer, effect_type text, value numeric, target text, activation text, stacking text, stack_group text, scope text, active boolean, inactive_reason text, applied boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with owned as (
    select ii.id, ii.item_id, ii.is_attuned and public._item_active_in_form(p_character, ii.id) as is_attuned,
           coalesce(ii.custom_name, it.name) as name, it.kind_id, it.requires_attunement, e.slot_id
    from public.inventories inv
    join public.inventory_items ii on ii.inventory_id = inv.id
    join public.items it on it.id = ii.item_id                       -- RLS: modifiers of invisible items do not exist
    left join public.character_equipment e on e.inventory_item_id = ii.id and e.character_id = p_character
      and public._item_active_in_form(p_character, ii.id)              -- merged or dropped in Wild Shape: no effect
    where inv.character_id = p_character
      and exists (select 1 from public.inventory_item_modifiers im where im.inventory_item_id = ii.id)
  ),
  raw as (
    -- 20261114000500: item effects of every owned item (also unidentified ones, under their disguise) and permanent effects
    select x.source_type, x.source_id, x.item_id, x.source_name, null::text as modifier_id, x.seq,
           x.effect_type, x.value, x.target, x.activation, x.stacking, x.stack_group, x.priority,
           case when x.effect_type in ('attack_bonus', 'damage_bonus') and x.kind_id = 'weapon' then 'self' else 'global' end as scope,
           x.inactive_reason
    from public._character_item_effect_rows(p_character) x
    union all
    select 'modifier', o.id, o.item_id, o.name || ' (' || md.name || ')', md.id, me.seq,
           me.effect_type, me.value, null,
           case when coalesce(md.requires_attunement_override, o.requires_attunement) then 'equipped_and_attuned' else 'equipped' end,
           'additive', null, 0,
           case when me.effect_type in ('attack_bonus', 'damage_bonus') then 'self' else 'global' end,
           case when o.slot_id is null then 'not_equipped'
                when coalesce(md.requires_attunement_override, o.requires_attunement) and not o.is_attuned then 'not_attuned' end
    from owned o
    join public.inventory_item_modifiers im on im.inventory_item_id = o.id
    join public.item_modifiers md on md.id = im.modifier_id
    join public.item_modifier_effects me on me.modifier_id = md.id
    union all
    -- class feature effects (20261015001800); only active features, the effect's own conditions decide inactive_reason
    select 'class_feature', ce.character_class_id, null, ce.class_name || ': ' || ce.feature_name,
           ce.unlock_id || ':' || ce.seq || ':' || coalesce(ce.pick, 0), ce.seq,
           ce.effect_type, ce.value, case when ce.effect_type = 'resistance' then coalesce(ce.target, ce.value_text) else ce.target end,
           'owned', 'additive', null, 0, 'global',
           case when ce.active then null else coalesce(ce.inactive_reason, 'inactive') end
    from public._character_feature_effects(p_character) ce
    where ce.feature_active and ce.automation <> 'informational'
      and ce.effect_type in ('ability_bonus', 'ac_bonus', 'save_bonus', 'speed_bonus', 'resistance', 'skill_advantage',
                             'skill_disadvantage', 'carrying_capacity_bonus')
  ),
  ranked as (
    select r.*, r.inactive_reason is null as active,
           row_number() over (
             partition by r.inactive_reason is null, r.effect_type, coalesce(r.target, ''), r.scope,
                          case when r.scope = 'self' then r.source_id::text else '' end,
                          case r.stacking when 'additive' then r.source_type || r.source_id || coalesce(r.modifier_id, '') || r.seq
                                          when 'non_stacking_group' then 'group:' || r.stack_group
                                          else r.stacking end
             order by r.value desc nulls last, r.priority desc, r.source_id) as rn
    from raw r
  )
  select source_type, source_id, item_id, source_name, modifier_id, seq, effect_type, value, target, activation, stacking, stack_group,
         scope, active, inactive_reason, active and rn = 1 as applied
  from ranked;
$function$;


-- --------------------------------------------------------------------------- 5b. derived stats core (body of 20261017001300 + R-D1)
CREATE OR REPLACE FUNCTION public._derived_stats_core(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c public.characters;
  pb int;
  effects jsonb;
  abilities jsonb := '{}'; scores jsonb := '{}'; mods jsonb := '{}';
  k text; base_score int; override_score int; bonus int; score int;
  armor record; shield record; w record;
  dex_mod int; dex_part int; formula text; ac_parts jsonb := '[]'; ac_calc int; alternatives jsonb := '[]';
  armor_prof jsonb; shield_prof jsonb; nonprof_armor boolean := false; nonprof_shield boolean := false;
  stealth_sources jsonb := '[]'; str_unmet boolean := false; speed_parts jsonb; speed_val int;
  warnings jsonb := '[]'; weapons jsonb := '[]'; saves jsonb := '{}'; skills jsonb := '{}';
  ab text; ab_mod int; prof jsonb; atk_magic int; dmg_magic int; atk_total int; dmg_bonus int; atk_parts jsonb; dmg_parts jsonb;
  grp text; legacy_eq int; hidden jsonb;
  -- lineage layer (20261015001500)
  lsel public.character_lineages; leff jsonb := '[]'; lin_included boolean := false; lin_bonus int; after_lineage int;
  bg_alloc jsonb := '{}'; bg_bonus int; lin_after int;
  form_ab jsonb; form_name text;
  nat jsonb; nat_val int; armor_val int; worn boolean; use_nat boolean; armor_cat text; heavy_ignore jsonb;
  walk_eff jsonb; movement jsonb; mv text; best jsonb; any_mode jsonb; lin_skills jsonb; nat_weapons jsonb := '[]';
  -- item effects (20261114000500): permanent increases (used consumables), capped per row (default max 20)
  perm jsonb := '[]'; pk jsonb; pscore int; pbefore int; papplied jsonb;
begin
  select * into c from public.characters where id = p_character;                 -- RLS: owner, campaign DM, admin
  if not found then raise exception 'Character not found' using errcode = '42501'; end if;

  pb := (greatest(c.level, 1) - 1) / 4 + 2;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.effect_type, e.source_name, e.seq), '[]'::jsonb) into effects
  from public._character_effects(p_character) e;
  perm := public._character_permanent_effect_rows(p_character);       -- 20261114000500
  select * into lsel from public.character_lineages where character_id = p_character;
  if found then
    lin_included := lsel.ability_bonuses_included;
    select coalesce(jsonb_agg(to_jsonb(e)), '[]') into leff from public._lineage_effects(p_character) e;
  end if;

  select f.abilities, f.name into form_ab, form_name from public._active_form(p_character) f;   -- Wild Shape (20261017001300)
  bg_alloc := public._character_background_abilities(p_character);         -- 2024 background increases (20261017001200)
  -- abilities: base score, highest active override (never lowers the score), plus additive bonuses (max 30)
  foreach k in array array['str', 'dex', 'con', 'int', 'wis', 'cha'] loop
    base_score := (to_jsonb(c) ->> (case k when 'str' then 'strength' when 'dex' then 'dexterity' when 'con' then 'constitution'
                                          when 'int' then 'intelligence' when 'wis' then 'wisdom' else 'charisma' end))::int;
    select max((e ->> 'value')::int) into override_score from jsonb_array_elements(effects) e
    where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'ability_override' and e ->> 'target' = k;
    bonus := public._effect_total(effects, 'ability_bonus', k);
    lin_bonus := coalesce((select sum((e ->> 'value')::int) from jsonb_array_elements(leff) e
                           where (e ->> 'active')::boolean and e ->> 'effect_type' = 'ability_bonus' and e ->> 'target' = k), 0);
    lin_after := case when lin_included then base_score else greatest(base_score, least(20, base_score + lin_bonus)) end;
    bg_bonus := coalesce((bg_alloc ->> k)::int, 0);
    after_lineage := greatest(lin_after, least(20, lin_after + bg_bonus));      -- background after the lineage, both up to 20
    -- 20261114000500: permanent increases from used items, in the order they were applied; each up to its maximum (default 20),
    -- never lowering a score that is already higher; a negative one lowers the score (minimum 1). Reverted rows are not read.
    pscore := after_lineage; papplied := '[]';
    for pk in select x from jsonb_array_elements(perm) x
              where x ->> 'kind' = 'effect' and x ->> 'effect_type' = 'ability_bonus' and x ->> 'target' = k
              order by x ->> 'applied_at', x ->> 'id' loop
      pbefore := pscore;
      if (pk ->> 'value')::int >= 0 then
        pscore := greatest(pscore, least(coalesce((pk ->> 'max_score')::int, 20), pscore + (pk ->> 'value')::int));
      else
        pscore := greatest(1, pscore + (pk ->> 'value')::int);
      end if;
      papplied := papplied || jsonb_build_array(pk || jsonb_build_object('applied', pscore - pbefore));
    end loop;
    score := least(30, greatest(pscore, coalesce(override_score, 0)) + bonus);
    if form_ab is not null and k in ('str', 'dex', 'con') then score := (form_ab ->> k)::int; end if;   -- the form's physical scores
    scores := scores || jsonb_build_object(k, score);
    mods := mods || jsonb_build_object(k, public._ability_mod(score));
    abilities := abilities || jsonb_build_object(k, jsonb_build_object('base', base_score, 'score', score,
      'modifier', public._ability_mod(score), 'override', override_score, 'bonus', bonus,
      'lineage_bonus', lin_bonus, 'lineage_applied', lin_after - base_score, 'lineage_included', lin_included,
      'background_bonus', bg_bonus, 'background_applied', after_lineage - lin_after,
      'permanent_bonus', coalesce((select sum((x ->> 'value')::int) from jsonb_array_elements(papplied) x), 0),
      'permanent_applied', pscore - after_lineage, 'permanent_sources', papplied,
      'inactive_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                           where e ->> 'effect_type' in ('ability_override', 'ability_bonus') and e ->> 'target' = k
                             and not (e ->> 'active')::boolean),
      'form_score', case when form_ab is not null and k in ('str', 'dex', 'con') then (form_ab ->> k)::int end,
      'form_name', case when form_ab is not null and k in ('str', 'dex', 'con') then form_name end,
      'lineage_sources', (select coalesce(jsonb_agg(jsonb_build_object('trait_id', e ->> 'trait_id', 'source_name', e ->> 'trait_name',
                                                                        'value', (e ->> 'value')::int)), '[]')
                          from jsonb_array_elements(leff) e
                          where (e ->> 'active')::boolean and e ->> 'effect_type' = 'ability_bonus' and e ->> 'target' = k),
      'sources', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                  where (e ->> 'applied')::boolean and e ->> 'effect_type' in ('ability_override', 'ability_bonus') and e ->> 'target' = k)));
  end loop;
  dex_mod := (mods ->> 'dex')::int;

  -- equipped armor and shield (stats of the item itself, or of its base item)
  select e.inventory_item_id, ii.item_id, coalesce(ii.custom_name, it.name) as name, it.id is not null as visible, it.category_id,
         it.base_item_id, st.base_ac, st.ac_bonus, st.dex_modifier_mode, st.dex_cap, st.strength_requirement, st.stealth_disadvantage, st.is_shield
  into armor
  from public.character_equipment e
  join public.inventory_items ii on ii.id = e.inventory_item_id
  left join public.items it on it.id = ii.item_id
  left join lateral (select s.* from public.armor_stats s where s.item_id in (it.id, it.base_item_id)
                     order by s.item_id = it.id desc limit 1) st on true
  where e.character_id = p_character and e.slot_id = 'armor';

  select e.inventory_item_id, ii.item_id, coalesce(ii.custom_name, it.name) as name, it.id is not null as visible, it.category_id,
         it.base_item_id, st.ac_bonus, st.is_shield
  into shield
  from public.character_equipment e
  join public.inventory_items ii on ii.id = e.inventory_item_id
  left join public.items it on it.id = ii.item_id
  left join lateral (select s.* from public.armor_stats s where s.item_id in (it.id, it.base_item_id)
                     order by s.item_id = it.id desc limit 1) st on true
  where e.character_id = p_character and e.slot_id = 'shield';

  -- ---- Armor Class: exactly one base formula, then additive bonuses --------------------------------------------
  -- candidates: unarmored (10 + DEX), worn armor, lineage natural armor ('best_of' competes with armor; 'replaces_armor'
  -- means worn armor gives no benefit). The best applicable one is used; the others are listed as alternatives.
  worn := armor.inventory_item_id is not null and armor.base_ac is not null and not armor.is_shield;
  if worn then
    armor_val := armor.base_ac + case armor.dex_modifier_mode when 'full' then dex_mod when 'capped' then least(dex_mod, armor.dex_cap) else 0 end;
  end if;
  select e into nat from jsonb_array_elements(leff) e
  where (e ->> 'active')::boolean and e ->> 'effect_type' = 'natural_armor'
  order by (e ->> 'value')::int + case when e -> 'data' ->> 'dex' = 'full' then dex_mod else 0 end desc limit 1;
  nat_val := (nat ->> 'value')::int + case when nat -> 'data' ->> 'dex' = 'full' then dex_mod else 0 end;
  use_nat := nat is not null and ((not worn and nat_val >= 10 + dex_mod)
                                  or (worn and nat -> 'data' ->> 'mode' = 'replaces_armor')
                                  or (worn and nat -> 'data' ->> 'mode' = 'best_of' and nat_val > armor_val));
  if use_nat then
    formula := 'natural_armor';
    ac_parts := ac_parts || jsonb_build_object('source_type', 'lineage', 'source_id', nat ->> 'trait_id', 'source_name', nat ->> 'trait_name',
                  'effect', 'base_ac', 'value', (nat ->> 'value')::int);
    ac_parts := ac_parts || jsonb_build_object('source_type', 'ability', 'source_id', 'dex', 'source_name', 'Dexterity',
                  'effect', 'ability_modifier', 'value', case when nat -> 'data' ->> 'dex' = 'full' then dex_mod else 0 end,
                  'modifier', dex_mod, 'mode', case when nat -> 'data' ->> 'dex' = 'full' then 'full' else 'none' end, 'cap', null,
                  'applied', nat -> 'data' ->> 'dex' = 'full');
    alternatives := alternatives || jsonb_build_object('formula', 'unarmored', 'value', 10 + dex_mod, 'used', false, 'reason', 'natural_armor_better');
    if worn then
      alternatives := alternatives || jsonb_build_object('formula', 'armor', 'value', armor_val, 'used', false,
        'reason', case when nat -> 'data' ->> 'mode' = 'replaces_armor' then 'natural_armor_replaces_armor' else 'natural_armor_better' end);
      if nat -> 'data' ->> 'mode' = 'replaces_armor' then
        warnings := warnings || jsonb_build_object('code', 'lineage_armor_no_benefit', 'severity', 'warning', 'source_type', 'armor',
                      'source_id', armor.inventory_item_id, 'item_id', armor.item_id, 'source_name', armor.name,
                      'trait_name', nat ->> 'trait_name');
      end if;
    end if;
  elsif worn then
    formula := case armor.dex_modifier_mode when 'full' then 'light_armor' when 'capped' then 'medium_armor' else 'heavy_armor' end;
    dex_part := case armor.dex_modifier_mode when 'full' then dex_mod when 'capped' then least(dex_mod, armor.dex_cap) else 0 end;
    ac_parts := ac_parts || jsonb_build_object('source_type', 'armor', 'source_id', armor.inventory_item_id, 'item_id', armor.item_id,
                  'source_name', armor.name, 'effect', 'base_ac', 'value', armor.base_ac);
    ac_parts := ac_parts || jsonb_build_object('source_type', 'ability', 'source_id', 'dex', 'source_name', 'Dexterity',
                  'effect', 'ability_modifier', 'value', dex_part, 'modifier', dex_mod, 'mode', armor.dex_modifier_mode,
                  'cap', armor.dex_cap, 'applied', armor.dex_modifier_mode <> 'none');
    alternatives := alternatives || jsonb_build_object('formula', 'unarmored', 'value', 10 + dex_mod, 'used', false,
                                                       'reason', 'armor_worn');
    if nat is not null then
      alternatives := alternatives || jsonb_build_object('formula', 'natural_armor', 'value', nat_val, 'used', false, 'reason', 'armor_better',
                                                         'source_name', nat ->> 'trait_name');
    end if;
  else
    formula := 'unarmored';
    ac_parts := ac_parts || jsonb_build_object('source_type', 'rule', 'source_id', 'unarmored', 'source_name', 'Unarmored',
                  'effect', 'base_ac', 'value', 10);
    ac_parts := ac_parts || jsonb_build_object('source_type', 'ability', 'source_id', 'dex', 'source_name', 'Dexterity',
                  'effect', 'ability_modifier', 'value', dex_mod, 'modifier', dex_mod, 'mode', 'full', 'cap', null, 'applied', true);
    if nat is not null then
      alternatives := alternatives || jsonb_build_object('formula', 'natural_armor', 'value', nat_val, 'used', false,
                                                         'reason', 'unarmored_better', 'source_name', nat ->> 'trait_name');
    end if;
  end if;
  if armor.inventory_item_id is not null and not worn then
    warnings := warnings || jsonb_build_object('code', case when armor.visible then 'armor_stats_unknown' else 'hidden_item' end,
                  'severity', 'warning', 'source_type', 'armor', 'source_id', armor.inventory_item_id, 'item_id', armor.item_id,
                  'source_name', armor.name);
  end if;
  if shield.inventory_item_id is not null then
    if shield.is_shield then
      ac_parts := ac_parts || jsonb_build_object('source_type', 'shield', 'source_id', shield.inventory_item_id, 'item_id', shield.item_id,
                    'source_name', shield.name, 'effect', 'ac_bonus', 'value', shield.ac_bonus);
    else
      warnings := warnings || jsonb_build_object('code', case when shield.visible then 'armor_stats_unknown' else 'hidden_item' end,
                    'severity', 'warning', 'source_type', 'shield', 'source_id', shield.inventory_item_id, 'item_id', shield.item_id,
                    'source_name', shield.name);
    end if;
  end if;
  ac_parts := ac_parts || coalesce((
    select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_id', e ->> 'source_id', 'item_id', e ->> 'item_id',
             'modifier_id', e ->> 'modifier_id', 'source_name', e ->> 'source_name', 'effect', 'ac_bonus', 'value', (e ->> 'value')::int)
             order by e ->> 'source_name')
    from jsonb_array_elements(effects) e
    where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'ac_bonus' and e ->> 'scope' = 'global'), '[]'::jsonb);
  select sum((p ->> 'value')::int) into ac_calc from jsonb_array_elements(ac_parts) p;

  -- ---- proficiency consequences of armor and shield ---------------------------------------------------------------
  armor_cat := coalesce(armor.category_id, (select category_id from public.items where id = armor.base_item_id));
  select e into heavy_ignore from jsonb_array_elements(leff) e
  where (e ->> 'active')::boolean and e ->> 'effect_type' = 'ignore_heavy_armor_speed_penalty' and armor_cat = 'heavy-armor' limit 1;
  if armor.inventory_item_id is not null and armor.visible then
    select id into grp from public.proficiency_groups
    where armor_category_id = coalesce(armor.category_id, (select category_id from public.items where id = armor.base_item_id));
    armor_prof := public._proficiency_match(p_character, armor.item_id, armor.base_item_id, grp);
    nonprof_armor := not (armor_prof ->> 'proficient')::boolean;
    if nonprof_armor then
      warnings := warnings || jsonb_build_object('code', 'nonproficient_armor', 'severity', 'warning', 'source_type', 'armor',
                    'source_id', armor.inventory_item_id, 'item_id', armor.item_id, 'source_name', armor.name,
                    'missing_group_id', armor_prof ->> 'missing_group_id', 'missing_group_name', armor_prof ->> 'missing_group_name');
    end if;
    if armor.stealth_disadvantage then
      stealth_sources := stealth_sources || jsonb_build_object('source_type', 'armor', 'source_id', armor.inventory_item_id,
                           'item_id', armor.item_id, 'source_name', armor.name);
      warnings := warnings || jsonb_build_object('code', 'stealth_disadvantage', 'severity', 'info', 'source_type', 'armor',
                    'source_id', armor.inventory_item_id, 'item_id', armor.item_id, 'source_name', armor.name);
    end if;
    if armor.strength_requirement is not null and (scores ->> 'str')::int < armor.strength_requirement then
      str_unmet := true;
      warnings := warnings || jsonb_build_object('code', 'strength_requirement_unmet', 'severity', 'warning', 'source_type', 'armor',
                    'source_id', armor.inventory_item_id, 'item_id', armor.item_id, 'source_name', armor.name,
                    'required', armor.strength_requirement, 'current', (scores ->> 'str')::int,
                    'speed_penalty', case when heavy_ignore is null then 10 else 0 end, 'speed_penalty_ignored_by', heavy_ignore ->> 'trait_name');
    end if;
  end if;
  if shield.inventory_item_id is not null and shield.visible then
    select id into grp from public.proficiency_groups where armor_category_id = 'shield';
    shield_prof := public._proficiency_match(p_character, shield.item_id, shield.base_item_id, grp);
    nonprof_shield := not (shield_prof ->> 'proficient')::boolean;
    if nonprof_shield then
      warnings := warnings || jsonb_build_object('code', 'nonproficient_shield', 'severity', 'warning', 'source_type', 'shield',
                    'source_id', shield.inventory_item_id, 'item_id', shield.item_id, 'source_name', shield.name,
                    'missing_group_id', shield_prof ->> 'missing_group_id', 'missing_group_name', shield_prof ->> 'missing_group_name');
    end if;
  end if;
  if nonprof_armor or nonprof_shield then
    warnings := warnings || jsonb_build_object('code', 'spellcasting_restricted', 'severity', 'warning', 'source_type', 'rule',
                  'source_id', case when nonprof_armor then armor.inventory_item_id else shield.inventory_item_id end,
                  'source_name', case when nonprof_armor then armor.name else shield.name end);
  end if;
  stealth_sources := stealth_sources || coalesce((select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type',
                       'source_id', e ->> 'source_id', 'item_id', e ->> 'item_id', 'source_name', e ->> 'source_name'))
                     from jsonb_array_elements(effects) e
                     where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'skill_disadvantage' and e ->> 'target' = 'stealth'), '[]');

  -- ---- speed: stored base speed + permanent bonuses - equipment penalties (stored speed is never changed) ---------
  select e into walk_eff from jsonb_array_elements(leff) e
  where (e ->> 'active')::boolean and e ->> 'effect_type' = 'speed' and e ->> 'target' = 'walk' and e ->> 'value' is not null
  order by (e ->> 'value')::int desc limit 1;
  if walk_eff is not null then
    speed_parts := jsonb_build_array(jsonb_build_object('source_type', 'lineage', 'source_id', walk_eff ->> 'trait_id',
                     'source_name', walk_eff ->> 'trait_name', 'effect', 'base', 'value', (walk_eff ->> 'value')::int));
  else
    speed_parts := jsonb_build_array(jsonb_build_object('source_type', 'base', 'source_id', 'speed', 'source_name', 'Base speed',
                                                        'effect', 'base', 'value', c.speed));
  end if;
  if str_unmet and heavy_ignore is not null then
    speed_parts := speed_parts || jsonb_build_object('source_type', 'armor', 'source_id', armor.inventory_item_id, 'item_id', armor.item_id,
                     'source_name', armor.name, 'effect', 'strength_requirement', 'value', 0, 'ignored_by', heavy_ignore ->> 'trait_name',
                     'required', armor.strength_requirement, 'current', (scores ->> 'str')::int);
  elsif str_unmet then
    speed_parts := speed_parts || jsonb_build_object('source_type', 'armor', 'source_id', armor.inventory_item_id, 'item_id', armor.item_id,
                     'source_name', armor.name, 'effect', 'strength_requirement', 'value', -10,
                     'required', armor.strength_requirement, 'current', (scores ->> 'str')::int);
  end if;
  speed_parts := speed_parts || coalesce((select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_id', e ->> 'source_id',
                     'item_id', e ->> 'item_id', 'source_name', e ->> 'source_name', 'effect', e ->> 'effect_type',
                     'value', case when e ->> 'effect_type' = 'speed_penalty' then -abs((e ->> 'value')::int) else (e ->> 'value')::int end))
                   from jsonb_array_elements(effects) e
                   where (e ->> 'applied')::boolean and e ->> 'effect_type' in ('speed_bonus', 'speed_penalty')), '[]');
  select greatest(0, sum((p ->> 'value')::int)) into speed_val from jsonb_array_elements(speed_parts) p;
  movement := jsonb_build_object('walk', jsonb_build_object('value', speed_val, 'active', true));
  foreach mv in array array['climb', 'swim', 'fly', 'burrow'] loop
    best := null; any_mode := null;
    select e || jsonb_build_object('resolved', case when e ->> 'value_text' = 'walk' then speed_val else (e ->> 'value')::int end,
                                   'blocked', coalesce(e -> 'conditions' -> 'not_armor' ? armor_cat, false) and worn)
    into any_mode
    from jsonb_array_elements(leff) e
    where (e ->> 'active')::boolean and e ->> 'effect_type' = 'speed' and e ->> 'target' = mv
    order by coalesce(e -> 'conditions' -> 'not_armor' ? armor_cat, false) and worn,
             case when e ->> 'value_text' = 'walk' then speed_val else (e ->> 'value')::int end desc
    limit 1;
    if any_mode is not null then
      movement := movement || jsonb_build_object(mv, jsonb_build_object(
        'value', (any_mode ->> 'resolved')::int, 'active', not (any_mode ->> 'blocked')::boolean,
        'inactive_reason', case when (any_mode ->> 'blocked')::boolean then 'armor' end,
        'equal_to_walk', any_mode ->> 'value_text' = 'walk', 'conditions', any_mode -> 'conditions',
        'source_name', any_mode ->> 'trait_name', 'trait_id', any_mode ->> 'trait_id'));
    end if;
  end loop;

  -- ---- saving throws and skills: only what equipment adds (proficiency is still calculated on the sheet) ---------
  foreach k in array array['str', 'dex', 'con', 'int', 'wis', 'cha'] loop
    saves := saves || jsonb_build_object(k, jsonb_build_object(
      'item_bonus', public._effect_total(effects, 'save_bonus', null) + public._effect_total(effects, 'save_bonus', k),
      'item_sources', (select coalesce(jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_name', e ->> 'source_name',
                                                                    'value', (e ->> 'value')::int, 'all_saves', e ->> 'target' is null)), '[]'::jsonb)
                       from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'save_bonus'
                         and e ->> 'scope' = 'global' and (e ->> 'target' is null or e ->> 'target' = k)),
      'inactive_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                           where e ->> 'effect_type' = 'save_bonus' and (e ->> 'target' is null or e ->> 'target' = k)
                             and not (e ->> 'active')::boolean),
      'disadvantage', (nonprof_armor or nonprof_shield) and k in ('str', 'dex')));
  end loop;
  select coalesce(jsonb_object_agg(t.skill, t.v), '{}'::jsonb) into skills from (
    select s.skill, jsonb_build_object(
      'advantage', exists (select 1 from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean
                           and e ->> 'effect_type' = 'skill_advantage' and e ->> 'target' = s.skill),
      'disadvantage', (s.skill = 'stealth' and jsonb_array_length(stealth_sources) > 0)
                      or exists (select 1 from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean
                                 and e ->> 'effect_type' = 'skill_disadvantage' and e ->> 'target' = s.skill),
      'sources', case when s.skill = 'stealth' then stealth_sources else '[]'::jsonb end,
      'item_bonus', public._effect_total(effects, 'skill_bonus', s.skill),
      'item_sources', (select coalesce(jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_name', e ->> 'source_name',
                                                                    'value', (e ->> 'value')::int)), '[]'::jsonb)
                       from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'skill_bonus'
                         and e ->> 'target' = s.skill),
      'inactive_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                           where e ->> 'effect_type' = 'skill_bonus' and e ->> 'target' = s.skill and not (e ->> 'active')::boolean)) as v
    from (select distinct e ->> 'target' as skill from jsonb_array_elements(effects) e
          where e ->> 'effect_type' in ('skill_advantage', 'skill_disadvantage', 'skill_bonus') and ((e ->> 'applied')::boolean
                or (e ->> 'effect_type' = 'skill_bonus' and not (e ->> 'active')::boolean))
          union select 'stealth') s) t;

  select coalesce(jsonb_object_agg(s.k, s.src), '{}') into lin_skills from (
    select e ->> 'value_text' as k, jsonb_agg(jsonb_build_object('source_type', 'lineage', 'trait_id', e ->> 'trait_id',
                                                                   'source_name', e ->> 'trait_name')) as src
    from jsonb_array_elements(leff) e
    where (e ->> 'active')::boolean and e ->> 'effect_type' = 'proficiency' and e ->> 'target' = 'skill'
    group by 1) s;
  for k in select jsonb_object_keys(lin_skills) loop
    skills := skills || jsonb_build_object(k, coalesce(skills -> k, '{"advantage": false, "disadvantage": false, "sources": []}'::jsonb)
                                               || jsonb_build_object('lineage_proficient', true, 'proficiency_sources', lin_skills -> k));
  end loop;

  -- ---- natural weapons from the lineage (unarmed strikes: Strength, always proficient) ---------------------------
  select coalesce(jsonb_agg(jsonb_build_object(
           'trait_id', e ->> 'trait_id', 'source_name', e ->> 'trait_name', 'name', e ->> 'value_text',
           'damage_dice', e -> 'data' ->> 'damage_dice', 'damage_type', e -> 'data' ->> 'damage_type', 'ability', 'str',
           'ability_modifier', (mods ->> 'str')::int, 'proficient', true, 'proficiency_bonus', pb,
           'attack_bonus', (mods ->> 'str')::int + pb,
           'damage', (e -> 'data' ->> 'damage_dice') || case when (mods ->> 'str')::int > 0 then ' + ' || (mods ->> 'str')
                                                             when (mods ->> 'str')::int < 0 then ' - ' || abs((mods ->> 'str')::int) else '' end,
           'attack_disadvantage', nonprof_armor or nonprof_shield) order by e ->> 'trait_id', e ->> 'seq'), '[]')
  into nat_weapons
  from jsonb_array_elements(leff) e where (e ->> 'active')::boolean and e ->> 'effect_type' = 'natural_weapon';

  -- ---- equipped weapons -----------------------------------------------------------------------------------------
  for w in
    select e.slot_id, e.inventory_item_id, ii.item_id, coalesce(ii.custom_name, it.name) as name, it.base_item_id,
           ws.weapon_group, ws.damage_dice, ws.damage_type_id, ws.versatile_damage, ws.is_ranged, ws.range_normal, ws.range_max,
           exists (select 1 from public.weapon_property_links l where l.item_id = ws.item_id and l.property_id = 'finesse') as finesse,
           (select coalesce(array_agg(l.property_id order by l.property_id), '{}') from public.weapon_property_links l where l.item_id = ws.item_id) as properties
    from public.character_equipment e
    join public.inventory_items ii on ii.id = e.inventory_item_id
    join public.items it on it.id = ii.item_id
    join lateral (select s.* from public.weapon_stats s where s.item_id in (it.id, it.base_item_id)
                  order by s.item_id = it.id desc limit 1) ws on true
    where e.character_id = p_character and e.slot_id in ('main_hand', 'off_hand')
    order by e.slot_id
  loop
    if w.finesse then ab := case when (mods ->> 'dex')::int > (mods ->> 'str')::int then 'dex' else 'str' end;
    elsif w.is_ranged then ab := 'dex';
    else ab := 'str';
    end if;
    ab_mod := (mods ->> ab)::int;
    select id into grp from public.proficiency_groups where weapon_group = w.weapon_group;
    prof := public._proficiency_match(p_character, w.item_id, w.base_item_id, grp);
    atk_magic := public._effect_total(effects, 'attack_bonus', null, w.inventory_item_id) + public._effect_total(effects, 'attack_bonus', null);
    dmg_magic := public._effect_total(effects, 'damage_bonus', null, w.inventory_item_id) + public._effect_total(effects, 'damage_bonus', null);
    atk_total := ab_mod + case when (prof ->> 'proficient')::boolean then pb else 0 end + atk_magic;
    dmg_bonus := ab_mod + dmg_magic;
    atk_parts := jsonb_build_array(
      jsonb_build_object('source_type', 'ability', 'source_id', ab, 'effect', 'ability_modifier', 'value', ab_mod),
      jsonb_build_object('source_type', 'proficiency', 'source_id', 'proficiency_bonus', 'effect', 'proficiency_bonus',
                         'value', case when (prof ->> 'proficient')::boolean then pb else 0 end,
                         'applied', (prof ->> 'proficient')::boolean, 'proficiency_bonus', pb));
    atk_parts := atk_parts || coalesce((select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_id', e ->> 'source_id',
                     'modifier_id', e ->> 'modifier_id', 'source_name', e ->> 'source_name', 'effect', 'attack_bonus', 'value', (e ->> 'value')::int))
                   from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'attack_bonus'
                     and (e ->> 'scope' = 'global' or (e ->> 'source_id')::uuid = w.inventory_item_id)), '[]');
    dmg_parts := jsonb_build_array(jsonb_build_object('source_type', 'ability', 'source_id', ab, 'effect', 'ability_modifier', 'value', ab_mod))
      || coalesce((select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_id', e ->> 'source_id',
                     'modifier_id', e ->> 'modifier_id', 'source_name', e ->> 'source_name', 'effect', 'damage_bonus', 'value', (e ->> 'value')::int))
                   from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'damage_bonus'
                     and (e ->> 'scope' = 'global' or (e ->> 'source_id')::uuid = w.inventory_item_id)), '[]');
    weapons := weapons || jsonb_build_object(
      'inventory_item_id', w.inventory_item_id, 'item_id', w.item_id, 'name', w.name, 'slot_id', w.slot_id,
      'weapon_group', w.weapon_group, 'properties', to_jsonb(w.properties), 'is_ranged', w.is_ranged,
      'range_normal', w.range_normal, 'range_max', w.range_max,
      'ability', ab, 'ability_rule', case when w.finesse then 'finesse_best' when w.is_ranged then 'ranged_dex' else 'melee_str' end,
      'ability_modifier', ab_mod, 'proficient', (prof ->> 'proficient')::boolean, 'proficiency', prof,
      'proficiency_bonus', pb, 'proficiency_bonus_applied', (prof ->> 'proficient')::boolean,
      'magic_attack_bonus', atk_magic, 'attack_bonus', atk_total, 'attack_breakdown', atk_parts,
      'damage_dice', w.damage_dice, 'versatile_damage', w.versatile_damage, 'damage_type', w.damage_type_id,
      'magic_damage_bonus', dmg_magic, 'damage_bonus', dmg_bonus, 'damage_breakdown', dmg_parts,
      'damage', case when w.damage_dice is null then null
                     when w.damage_dice ~ '^[0-9]+$' then greatest(0, w.damage_dice::int + dmg_bonus)::text
                     when dmg_bonus = 0 then w.damage_dice
                     else w.damage_dice || case when dmg_bonus > 0 then ' + ' else ' - ' end || abs(dmg_bonus) end,
      'attack_disadvantage', nonprof_armor or nonprof_shield);
    if not (prof ->> 'proficient')::boolean then
      warnings := warnings || jsonb_build_object('code', 'nonproficient_weapon', 'severity', 'info', 'source_type', 'weapon',
                    'source_id', w.inventory_item_id, 'item_id', w.item_id, 'source_name', w.name,
                    'missing_group_id', prof ->> 'missing_group_id', 'missing_group_name', prof ->> 'missing_group_name');
    end if;
  end loop;

  -- ---- odds and ends --------------------------------------------------------------------------------------------
  select count(*) into legacy_eq from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_character and ii.item_id is null and ii.equipped;
  if legacy_eq > 0 then
    warnings := warnings || jsonb_build_object('code', 'legacy_equipped_ignored', 'severity', 'info', 'source_type', 'legacy',
                  'source_id', null, 'count', legacy_eq);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('code', 'hidden_item', 'severity', 'warning', 'source_type', 'equipment',
           'source_id', e.inventory_item_id, 'slot_id', e.slot_id)), '[]') into hidden
  from public.character_equipment e join public.inventory_items ii on ii.id = e.inventory_item_id
  left join public.items it on it.id = ii.item_id
  where e.character_id = p_character and it.id is null and e.slot_id not in ('armor', 'shield');
  warnings := warnings || hidden;

  return public._background_layer(p_character, jsonb_build_object(
    'character_id', c.id,
    'ruleset', 'dnd5e-2014',
    'proficiency_bonus', jsonb_build_object('value', pb, 'source', 'level', 'level', c.level),
    'abilities', abilities,
    'armor_class', jsonb_build_object(
      'value', coalesce(c.ac_override, ac_calc), 'calculated', ac_calc, 'override', c.ac_override,
      'source', case when c.ac_override is not null then 'override' else 'calculated' end,
      'legacy_stored', c.ac, 'base_formula', formula, 'breakdown', ac_parts, 'alternatives', alternatives,
      'inactive_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                           where e ->> 'effect_type' = 'ac_bonus' and not (e ->> 'active')::boolean)),
    'speed', jsonb_build_object('base', c.speed, 'value', speed_val, 'breakdown', speed_parts,
                                'base_source', case when walk_eff is not null then 'lineage' else 'character' end,
                                'movement', movement,
                                'inactive_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                                                     where e ->> 'effect_type' in ('speed_bonus', 'speed_penalty') and not (e ->> 'active')::boolean)),
    'armor', case when armor.inventory_item_id is null then null else jsonb_build_object(
      'inventory_item_id', armor.inventory_item_id, 'item_id', armor.item_id, 'name', armor.name,
      'base_ac', armor.base_ac, 'dex_modifier_mode', armor.dex_modifier_mode, 'dex_cap', armor.dex_cap,
      'strength_requirement', armor.strength_requirement, 'stealth_disadvantage', armor.stealth_disadvantage,
      'proficiency', armor_prof) end,
    'shield', case when shield.inventory_item_id is null then null else jsonb_build_object(
      'inventory_item_id', shield.inventory_item_id, 'item_id', shield.item_id, 'name', shield.name,
      'ac_bonus', shield.ac_bonus, 'proficiency', shield_prof) end,
    'armor_consequences', jsonb_build_object(
      'nonproficient_armor', nonprof_armor, 'nonproficient_shield', nonprof_shield,
      'ability_check_disadvantage', case when nonprof_armor or nonprof_shield then '["str","dex"]'::jsonb else '[]'::jsonb end,
      'saving_throw_disadvantage', case when nonprof_armor or nonprof_shield then '["str","dex"]'::jsonb else '[]'::jsonb end,
      'attack_disadvantage', case when nonprof_armor or nonprof_shield then '["str","dex"]'::jsonb else '[]'::jsonb end,
      'spellcasting_restricted', nonprof_armor or nonprof_shield,
      'stealth_disadvantage', jsonb_array_length(stealth_sources) > 0, 'stealth_sources', stealth_sources,
      'strength_requirement_unmet', str_unmet,
      'strength_requirement', armor.strength_requirement, 'strength_current', (scores ->> 'str')::int,
      'speed_penalty', case when str_unmet and heavy_ignore is null then 10 else 0 end,
      'speed_penalty_ignored_by', case when str_unmet then heavy_ignore ->> 'trait_name' end),
    'saving_throws', saves,
    'skills', skills,
    'equipped_weapon_attacks', weapons,
    'tools', (select coalesce(jsonb_agg(jsonb_build_object('inventory_item_id', ii.id, 'item_id', ii.item_id,
                'name', coalesce(ii.custom_name, it.name), 'category_id', it.category_id,
                'proficient', (public._proficiency_match(p_character, ii.item_id, it.base_item_id, null) ->> 'proficient')::boolean)
                order by it.name), '[]'::jsonb)
              from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
              join public.items it on it.id = ii.item_id
              where inv.character_id = p_character and it.kind_id = 'tool'),
    'proficiencies', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'proficiency_type', p.proficiency_type,
                        'group_id', p.group_id, 'item_id', p.item_id, 'name', coalesce(g.name, it.name, p.item_id),
                        'source_type', p.source_type, 'notes', p.notes) order by p.proficiency_type, coalesce(g.sort_order, 1000), coalesce(g.name, it.name)), '[]'::jsonb)
                      from public.character_proficiencies p
                      left join public.proficiency_groups g on g.id = p.group_id
                      left join public.items it on it.id = p.item_id
                      where p.character_id = p_character)
                     || (select coalesce(jsonb_agg(jsonb_build_object('id', null, 'proficiency_type',
                              case e ->> 'target' when 'group' then g.proficiency_type when 'armor' then
                                   case when it.category_id = 'shield' then 'shield' else 'armor' end else e ->> 'target' end,
                              'group_id', case when e ->> 'target' = 'group' then e ->> 'value_text' end,
                              'item_id', case when e ->> 'target' <> 'group' then e ->> 'value_text' end,
                              'name', coalesce(g.name, it.name, e ->> 'value_text'), 'source_type', 'lineage',
                              'notes', e ->> 'trait_name', 'trait_id', e ->> 'trait_id')
                              order by e ->> 'target', coalesce(g.name, it.name)), '[]')
                         from jsonb_array_elements(leff) e
                         left join public.proficiency_groups g on e ->> 'target' = 'group' and g.id = e ->> 'value_text'
                         left join public.items it on e ->> 'target' in ('weapon', 'armor', 'tool') and it.id = e ->> 'value_text'
                         where (e ->> 'active')::boolean and e ->> 'effect_type' = 'proficiency' and e ->> 'target' <> 'skill'),
    'other_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                      where e ->> 'effect_type' in ('resistance', 'carrying_capacity_bonus') or e ->> 'effect_type' is null),
    'effects', effects,
    'warnings', warnings,
    -- lineage layer
    'lineage', case when lsel.character_id is null then null else jsonb_build_object(
        'lineage_id', lsel.lineage_id, 'version_id', lsel.version_id, 'subversion_id', lsel.subversion_id,
        'name', (select name from public.lineages where id = lsel.lineage_id),
        'version_name', (select name from public.lineage_versions where id = lsel.version_id),
        'subversion_name', (select name from public.lineage_versions where id = lsel.subversion_id),
        'ability_bonuses_included', lsel.ability_bonuses_included) end,
    'size', (select jsonb_build_object('value', e ->> 'value_text', 'source_name', e ->> 'trait_name', 'trait_id', e ->> 'trait_id')
             from jsonb_array_elements(leff) e where (e ->> 'active')::boolean and e ->> 'effect_type' = 'size'
             order by (e ->> 'min_level')::int desc limit 1),
    'creature_type', (select coalesce(s.creature_type, v.creature_type) from public.lineage_versions v
                      left join public.lineage_versions s on s.id = lsel.subversion_id where v.id = lsel.version_id),
    'senses', (select coalesce(jsonb_object_agg(t.target, jsonb_build_object('value', t.v, 'source_name', t.src)), '{}') from (
                 select distinct on (e ->> 'target') e ->> 'target' as target, (e ->> 'value')::int as v, e ->> 'trait_name' as src
                 from jsonb_array_elements(leff) e where (e ->> 'active')::boolean and e ->> 'effect_type' = 'sense'
                 order by e ->> 'target', (e ->> 'value')::int desc) t),
    'languages', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', coalesce(lg.name, t.id), 'sources', t.src)
                                            order by coalesce(lg.sort_order, 999), t.id), '[]') from (
                    select e ->> 'value_text' as id, jsonb_agg(distinct e ->> 'trait_name') as src
                    from jsonb_array_elements(leff) e where (e ->> 'active')::boolean and e ->> 'effect_type' = 'language'
                    group by 1) t left join public.languages lg on lg.id = t.id),
    'resistances', (select coalesce(jsonb_agg(jsonb_build_object('damage_type', t.dt, 'sources', t.src) order by t.dt), '[]') from (
                      select x.dt, jsonb_agg(distinct x.src) as src from (
                        select e ->> 'value_text' as dt, e ->> 'trait_name' as src from jsonb_array_elements(leff) e
                        where (e ->> 'active')::boolean and e ->> 'effect_type' = 'resistance'
                        union all
                        select e ->> 'target', e ->> 'source_name' from jsonb_array_elements(effects) e
                        where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'resistance') x group by 1) t),
    'immunities', (select coalesce(jsonb_agg(distinct e ->> 'value_text'), '[]') from jsonb_array_elements(leff) e
                   where (e ->> 'active')::boolean and e ->> 'effect_type' = 'immunity'),
    'condition_immunities', (select coalesce(jsonb_agg(distinct e ->> 'value_text'), '[]') from jsonb_array_elements(leff) e
                             where (e ->> 'active')::boolean and e ->> 'effect_type' = 'condition_immunity'),
    'advantages', (select coalesce(jsonb_agg(jsonb_build_object('kind', e ->> 'effect_type', 'target', e ->> 'target',
                     'scope', e ->> 'value_text', 'source_name', e ->> 'trait_name', 'trait_id', e ->> 'trait_id')
                     order by e ->> 'effect_type', e ->> 'trait_id', (e ->> 'seq')::int), '[]')
                   from jsonb_array_elements(leff) e
                   where (e ->> 'active')::boolean and e ->> 'effect_type' in ('save_advantage', 'check_advantage')),
    'natural_weapons', nat_weapons,
    'lineage_spells', (select coalesce(jsonb_agg(jsonb_build_object(
                         'name', e ->> 'value_text', 'slug', e -> 'data' ->> 'slug', 'trait_id', e ->> 'trait_id',
                         'source_name', e ->> 'trait_name', 'min_level', (e ->> 'min_level')::int, 'unlocked', (e ->> 'active')::boolean,
                         'uses', e -> 'data' ->> 'uses', 'recharge', e -> 'data' ->> 'recharge', 'cast_level', e -> 'data' -> 'cast_level',
                         'ability', e -> 'data' ->> 'ability', 'ability_needed', e -> 'data' ? 'ability_choice' and not e -> 'data' ? 'ability',
                         'save_dc', case when e -> 'data' ? 'ability' then 8 + pb + (mods ->> (e -> 'data' ->> 'ability'))::int end,
                         'attack_bonus', case when e -> 'data' ? 'ability' then pb + (mods ->> (e -> 'data' ->> 'ability'))::int end,
                         'notes', e -> 'data' ->> 'notes')
                         order by (e ->> 'min_level')::int, e ->> 'trait_id', (e ->> 'seq')::int), '[]')
                       from jsonb_array_elements(leff) e where e ->> 'effect_type' = 'spell'),
    'lineage_actions', (select coalesce(jsonb_agg(jsonb_build_object(
                          'name', e ->> 'value_text', 'trait_id', e ->> 'trait_id', 'source_name', e ->> 'trait_name',
                          'min_level', (e ->> 'min_level')::int, 'unlocked', (e ->> 'active')::boolean,
                          'uses', case e -> 'data' ->> 'uses' when 'pb' then to_jsonb(pb) when null then null
                                      else to_jsonb(e -> 'data' ->> 'uses') end,
                          'recharge', e -> 'data' ->> 'recharge',
                          'save_dc', case when e -> 'data' ? 'dc_ability' then 8 + pb + (mods ->> (e -> 'data' ->> 'dc_ability'))::int end,
                          'save_ability', e -> 'data' ->> 'save_ability',
                          'dice', (select d2 ->> 1 from jsonb_array_elements(e -> 'data' -> 'dice_by_level') d2
                                   where (d2 ->> 0)::int <= c.level order by (d2 ->> 0)::int desc limit 1),
                          'damage_type', e -> 'data' ->> 'damage_type', 'notes', e -> 'data' ->> 'notes')
                          order by (e ->> 'min_level')::int, e ->> 'trait_id', (e ->> 'seq')::int), '[]')
                        from jsonb_array_elements(leff) e where e ->> 'effect_type' = 'limited_use'),
    'initiative', jsonb_build_object('bonus', coalesce((select sum(case when e ->> 'value_text' = 'pb' then pb else (e ->> 'value')::int end)
                                                       from jsonb_array_elements(leff) e
                                                       where (e ->> 'active')::boolean and e ->> 'effect_type' = 'initiative_bonus'), 0)
                                              + public._effect_total(effects, 'initiative_bonus', null),
                                     'sources', (select coalesce(jsonb_agg(e ->> 'trait_name'), '[]') from jsonb_array_elements(leff) e
                                                 where (e ->> 'active')::boolean and e ->> 'effect_type' = 'initiative_bonus')
                                                || (select coalesce(jsonb_agg(e ->> 'source_name'), '[]') from jsonb_array_elements(effects) e
                                                    where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'initiative_bonus' and e ->> 'scope' = 'global'),
                                     'item_sources', (select coalesce(jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type',
                                                        'source_name', e ->> 'source_name', 'value', (e ->> 'value')::int)), '[]')
                                                      from jsonb_array_elements(effects) e
                                                      where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'initiative_bonus' and e ->> 'scope' = 'global'),
                                     'inactive_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                                                          where e ->> 'effect_type' = 'initiative_bonus' and not (e ->> 'active')::boolean)),
    'permanent_effects', perm,
    'hit_points', jsonb_build_object('lineage_bonus', coalesce((select sum((e ->> 'value')::int) * c.level from jsonb_array_elements(leff) e
                                                               where (e ->> 'active')::boolean and e ->> 'effect_type' = 'hp_per_level'), 0),
                                     'sources', (select coalesce(jsonb_agg(e ->> 'trait_name'), '[]') from jsonb_array_elements(leff) e
                                                 where (e ->> 'active')::boolean and e ->> 'effect_type' = 'hp_per_level')),
    'carrying_capacity', jsonb_build_object('size_steps', coalesce((select max((e ->> 'value')::int) from jsonb_array_elements(leff) e
                                                                    where (e ->> 'active')::boolean and e ->> 'effect_type' = 'carrying_capacity'), 0))));
end;
$function$;

-- ------------------------------------------------------------------- 5c. spellbook grants (body of 20261017000500 + item counters)
CREATE OR REPLACE FUNCTION public._character_spell_grants(p_character uuid, mods jsonb, pb integer, lin_name text)
 RETURNS TABLE(spell_version_id text, source_key text, grant_info jsonb)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select g.spell_version_id, s.id::text, jsonb_build_object(
           'source_key', s.id::text, 'source_type', s.source_type, 'source_label', s.label, 'character_spell_id', g.id,
           'preparation_mode', s.preparation_mode,
           'known', g.known, 'prepared', g.prepared, 'always_prepared', g.always_prepared, 'innate', false,
           'counts_against_known_limit', g.counts_against_known_limit, 'counts_against_prepared_limit', g.counts_against_prepared_limit,
           'uses_spell_slot', g.uses_spell_slot and s.uses_spell_slots,
           'ritual_allowed', g.ritual_allowed or (v.is_ritual and case s.ritual_mode
                                                                     when 'prepared' then g.prepared or g.always_prepared
                                                                     when 'known' then g.known or g.prepared or g.always_prepared
                                                                     when 'spellbook' then g.known
                                                                     else false end),
           'notes', g.notes, 'unlocked', true, 'min_level', 1,
           'on_source_list', case when s.spell_list_id is null then null
                                  else exists (select 1 from public.class_spell_list_entries e
                                               where e.list_id = s.spell_list_id and e.spell_version_id = g.spell_version_id)
                                       or public._expanded_spell(s.character_class_id, g.spell_version_id) end,
           'casting_ability', coalesce(g.casting_ability, s.casting_ability), 'casting_ability_override', g.casting_ability,
           'stats', public._spell_stat(coalesce(g.casting_ability, s.casting_ability), mods, pb, s.fixed_dc, s.fixed_attack_bonus, s.dc_bonus, s.attack_bonus))
         -- 20261114000500: a spell granted by an item: how it is cast and its counter; the DM sees the true name of an unidentified item
         || case when s.item_grant_key is null then '{}'::jsonb else jsonb_build_object(
              'item_grant', true,
              'uses', case when r.id is not null then to_jsonb(r.mx) when g.uses_spell_slot then null else to_jsonb('at_will'::text) end,
              'recharge', r.recharge, 'remaining', case when r.id is not null then greatest(r.mx - r.expended, 0) end,
              'resource_key', case when r.id is not null then 'r:' || r.id end,
              'source_label', coalesce(dm.true_label, s.label)) end
  from public.character_spells g join public.character_spellcasting_sources s on s.id = g.source_id
  join public.spell_versions v on v.id = g.spell_version_id
  left join lateral (select x.id, x.recharge, x.expended, coalesce((x.max_formula ->> 'fixed')::int, 1) as mx from public.character_resources x
                     where s.item_grant_key is not null and x.character_id = p_character and x.source_type = 'item'
                       and x.source_id = s.item_grant_key and x.spell_version_id = g.spell_version_id and x.active
                     order by x.created_at limit 1) r on true
  left join lateral (select it.name || ' (unidentified)' as true_label from public.inventory_items ii
                     join public.inventory_item_knowledge k on k.inventory_item_id = ii.id and k.state <> 'identified'
                     join public.items it on it.id = ii.item_id
                     where s.item_grant_key like 'ii:%' and ii.id = substr(s.item_grant_key, 4)::uuid
                       and public._character_knows_all(p_character)) dm on true
  where g.character_id = p_character
  union all
  select te.spell_version_id, 'lineage:' || coalesce(e.data ->> 'ability', 'none'), jsonb_build_object(
           'source_key', 'lineage:' || coalesce(e.data ->> 'ability', 'none'), 'source_type', 'lineage',
           'source_label', coalesce(lin_name, 'Lineage') || ': ' || e.trait_name, 'trait_id', e.trait_id,
           'known', true, 'prepared', false, 'always_prepared', false, 'innate', true,
           'counts_against_known_limit', false, 'counts_against_prepared_limit', false, 'uses_spell_slot', false,
           'ritual_allowed', false, 'notes', e.data ->> 'notes', 'unlocked', e.active, 'min_level', e.min_level,
           'uses', e.data ->> 'uses', 'recharge', e.data ->> 'recharge', 'cast_level', e.data -> 'cast_level',
           'casting_ability', e.data ->> 'ability', 'ability_needed', e.data ? 'ability_choice' and not e.data ? 'ability',
           'stats', public._spell_stat(e.data ->> 'ability', mods, pb))
  from public._lineage_effects(p_character) e
  join public.lineage_trait_effects te on te.trait_id = e.trait_id and te.seq = e.seq
  where e.effect_type = 'spell' and te.spell_version_id is not null
  union all
  -- class feature spell grants (20261015001800): one source per class row; gone when the feature is inactive
  select f.spell_version_id, 'feature:' || f.character_class_id, jsonb_build_object(
           'source_key', 'feature:' || f.character_class_id, 'source_type', 'class_feature',
           'source_label', f.class_name || ': ' || f.feature_name, 'character_class_id', f.character_class_id,
           'unlock_id', f.unlock_id, 'feature_version_id', f.feature_version_id,
           'known', true, 'prepared', coalesce((f.data ->> 'always_prepared')::boolean, false),
           'always_prepared', coalesce((f.data ->> 'always_prepared')::boolean, false), 'innate', false,
           'counts_against_known_limit', coalesce((f.data ->> 'counts_against_known_limit')::boolean, false),
           'counts_against_prepared_limit', coalesce((f.data ->> 'counts_against_prepared_limit')::boolean, false),
           'uses_spell_slot', coalesce((f.data ->> 'uses_spell_slots')::boolean, true) and v.level > 0,
           'ritual_allowed', coalesce((f.data ->> 'ritual')::boolean, false) and v.is_ritual,
           'notes', f.data ->> 'notes', 'unlocked', f.active, 'min_level', f.min_level,
           'uses', f.data ->> 'uses', 'recharge', f.data ->> 'recharge', 'cast_level', f.data -> 'cast_level',
           'casting_ability', coalesce(f.data ->> 'ability', f.spellcasting_ability),
           'ability_needed', coalesce(f.data ->> 'ability', f.spellcasting_ability) is null,
           'stats', public._spell_stat(coalesce(f.data ->> 'ability', f.spellcasting_ability), mods, pb))
  from public._character_class_effects(p_character) f
  join public.spell_versions v on v.id = f.spell_version_id
  where f.feature_active and f.effect_type = 'spell' and f.spell_version_id is not null and f.automation <> 'informational'
    and f.inactive_reason is distinct from 'primary_class_only' and f.inactive_reason is distinct from 'multiclass_only';
$function$;

-- ------------------------------------------------------------------------------------------------- 6. spell grant materializer
-- Wanted state of one character: every grant of a held item whose activation holds (key 'ii:<inventory row>') and every
-- permanent spell of a used item (key 'pe:<permanent row>'). One spellcasting source per key, its spells, a counter per limited
-- grant. Sources of keys no longer wanted are removed (their spells with them); counters are only deactivated (expended kept:
-- unattune + attune again does not refill them). The source label is what the player may see (disguise while unidentified).
-- No-op updates are skipped (no revision rows, no cache bumps).
create or replace function public._sync_item_spell_grants(p_character uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare want jsonb; gk text; w jsonb; lbl text; src uuid; keep_src text[] := '{}'; keep_res text[] := '{}'; rk text; ab_default text;
  engine_before text := coalesce(current_setting('tavern.resource_engine', true), '');
begin
  if p_character is null then return; end if;
  select case when spellcasting_ability in ('str', 'dex', 'con', 'int', 'wis', 'cha') then spellcasting_ability end into ab_default
  from public.characters where id = p_character;
  if not found then return; end if;                                   -- the character is being deleted
  select coalesce(jsonb_agg(to_jsonb(x) order by x.gkey, x.seq), '[]') into want from (
    select 'ii:' || h.row_id as gkey, 'item-' || replace(h.row_id::text, '-', '') as rbase, h.label, gr.seq, gr.spell_version_id,
           gr.casting, gr.uses, gr.recharge, gr.ability
    from (select ii.id as row_id, ii.item_id, ii.is_attuned, e.slot_id,
                 case when kk.state is not null and kk.state <> 'identified'
                      then coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item')
                      else coalesce(nullif(ii.custom_name, ''), it.name) end as label
          from public.inventories inv
          join public.inventory_items ii on ii.inventory_id = inv.id
          join public.items it on it.id = ii.item_id
          left join public.character_equipment e on e.inventory_item_id = ii.id and e.character_id = p_character
          left join public.inventory_item_knowledge kk on kk.inventory_item_id = ii.id
          where inv.character_id = p_character
            and exists (select 1 from public.item_spell_grants x where x.item_id = ii.item_id and x.activation <> 'permanent')) h
    join public.item_spell_grants gr on gr.item_id = h.item_id and gr.activation <> 'permanent'
    where case gr.activation when 'owned' then true when 'equipped' then h.slot_id is not null when 'attuned' then h.is_attuned
                             when 'equipped_and_attuned' then h.slot_id is not null and h.is_attuned else false end
    union all
    select 'pe:' || p.id, 'itemp-' || replace(p.id::text, '-', ''), public._permanent_effect_label(p, false), p.seq, p.spell_version_id,
           p.casting, p.uses, p.recharge, p.ability
    from public.character_permanent_effects p
    where p.character_id = p_character and p.kind = 'spell' and p.reverted_at is null) x;

  if want = '[]'::jsonb and not exists (select 1 from public.character_spellcasting_sources where character_id = p_character and item_grant_key is not null)
     and not exists (select 1 from public.character_resources where character_id = p_character and source_type = 'item' and active
                     and resource_key ~ '^itemp?-[0-9a-f]{32}-') then
    return;                                                           -- nothing granted, nothing to clean up
  end if;
  perform set_config('tavern.resource_engine', 'on', true);          -- reset below (the resource guard bypass of this sync)
  for gk in select distinct x ->> 'gkey' from jsonb_array_elements(want) x loop
    keep_src := keep_src || gk;
    select x ->> 'label' into lbl from jsonb_array_elements(want) x where x ->> 'gkey' = gk limit 1;
    lbl := left(coalesce(nullif(btrim(lbl), ''), 'Magic item'), 80);
    select id into src from public.character_spellcasting_sources where character_id = p_character and item_grant_key = gk;
    if src is null then
      insert into public.character_spellcasting_sources (character_id, source_type, label, casting_ability, preparation_mode, ritual_mode,
                                                         uses_spell_slots, item_grant_key, notes, created_by)
      values (p_character, 'item', lbl,
              coalesce((select x ->> 'ability' from jsonb_array_elements(want) x where x ->> 'gkey' = gk and x ->> 'ability' is not null limit 1), ab_default),
              'innate', 'none', true, gk, 'Granted by an item; removed when the item no longer grants it.', auth.uid())
      returning id into src;
    else
      update public.character_spellcasting_sources set label = lbl where id = src and label is distinct from lbl;
    end if;
    delete from public.character_spells cs where cs.source_id = src
      and not cs.spell_version_id in (select x ->> 'spell_version_id' from jsonb_array_elements(want) x where x ->> 'gkey' = gk);
    for w in select x from jsonb_array_elements(want) x where x ->> 'gkey' = gk order by (x ->> 'seq')::int loop
      insert into public.character_spells as cs (character_id, source_id, spell_version_id, known, prepared, always_prepared,
                                                 counts_against_known_limit, counts_against_prepared_limit, uses_spell_slot, casting_ability,
                                                 acquisition, acquisition_notes)
      values (p_character, src, w ->> 'spell_version_id', true, false, false, false, false, w ->> 'casting' = 'spell_slots',
              coalesce(w ->> 'ability', ab_default), 'other', left('Granted by ' || lbl, 300))
      on conflict (source_id, spell_version_id) do update set uses_spell_slot = excluded.uses_spell_slot,
        casting_ability = excluded.casting_ability, acquisition_notes = excluded.acquisition_notes
        where (cs.uses_spell_slot, cs.casting_ability, cs.acquisition_notes)
              is distinct from (excluded.uses_spell_slot, excluded.casting_ability, excluded.acquisition_notes);
      if w ->> 'casting' = 'per_rest' then
        rk := (w ->> 'rbase') || '-' || (w ->> 'seq');
        keep_res := keep_res || rk;
        insert into public.character_resources as r (character_id, resource_key, name, source_type, source_id, max_formula, recharge,
                                                     spell_version_id, active, notes, created_by)
        values (p_character, rk, left('Free cast: ' || coalesce((select name from public.spell_versions where id = w ->> 'spell_version_id'), 'spell'), 80),
                'item', gk, jsonb_build_object('fixed', (w ->> 'uses')::int), w ->> 'recharge', w ->> 'spell_version_id', true,
                left(lbl || ': cast without a spell slot', 500), auth.uid())
        on conflict (character_id, resource_key) do update set active = true, max_formula = excluded.max_formula, recharge = excluded.recharge,
          name = excluded.name, notes = excluded.notes, source_id = excluded.source_id, spell_version_id = excluded.spell_version_id
          where (r.active, r.max_formula, r.recharge, r.name, r.notes, r.source_id, r.spell_version_id)
                is distinct from (true, excluded.max_formula, excluded.recharge, excluded.name, excluded.notes, excluded.source_id, excluded.spell_version_id);
      end if;
    end loop;
  end loop;
  delete from public.character_spellcasting_sources s where s.character_id = p_character and s.item_grant_key is not null
    and not s.item_grant_key = any (keep_src);
  update public.character_resources r set active = false
  where r.character_id = p_character and r.source_type = 'item' and r.active and r.resource_key ~ '^itemp?-[0-9a-f]{32}-'
    and not r.resource_key = any (keep_res);
  perform set_config('tavern.resource_engine', engine_before, true);
end $$;
revoke all on function public._sync_item_spell_grants(uuid) from public, anon, authenticated;

-- triggers: every write that can change the wanted state of a character (cheap guard: only items with spell grants)
create or replace function public._item_grants_on_inventory()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare ids uuid[] := '{}'; cid uuid;
begin
  if tg_op <> 'DELETE' and exists (select 1 from public.item_spell_grants g where g.item_id = new.item_id and g.activation <> 'permanent') then
    ids := ids || (select i.character_id from public.inventories i where i.id = new.inventory_id);
  end if;
  if tg_op <> 'INSERT' and exists (select 1 from public.item_spell_grants g where g.item_id = old.item_id and g.activation <> 'permanent') then
    ids := ids || (select i.character_id from public.inventories i where i.id = old.inventory_id);
  end if;
  for cid in select distinct x from unnest(ids) x where x is not null loop
    perform public._sync_item_spell_grants(cid);
  end loop;
  return null;
end $$;
drop trigger if exists inventory_items_item_grants on public.inventory_items;
create trigger inventory_items_item_grants after insert or delete or update of item_id, inventory_id, is_attuned, custom_name, name
  on public.inventory_items for each row execute function public._item_grants_on_inventory();

create or replace function public._item_grants_on_equipment()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare ids uuid[] := '{}'; cid uuid;
begin
  if tg_op <> 'DELETE' and exists (select 1 from public.inventory_items ii join public.item_spell_grants g on g.item_id = ii.item_id
                                   where ii.id = new.inventory_item_id and g.activation <> 'permanent') then
    ids := ids || new.character_id;
  end if;
  if tg_op <> 'INSERT' and exists (select 1 from public.inventory_items ii join public.item_spell_grants g on g.item_id = ii.item_id
                                   where ii.id = old.inventory_item_id and g.activation <> 'permanent') then
    ids := ids || old.character_id;
  end if;
  for cid in select distinct x from unnest(ids) x where x is not null loop
    perform public._sync_item_spell_grants(cid);
  end loop;
  return null;
end $$;
drop trigger if exists character_equipment_item_grants on public.character_equipment;
create trigger character_equipment_item_grants after insert or delete or update on public.character_equipment
  for each row execute function public._item_grants_on_equipment();

-- identification changes the label a player may see
create or replace function public._item_grants_on_knowledge()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare cid uuid; rid uuid := case when tg_op = 'DELETE' then old.inventory_item_id else new.inventory_item_id end;
begin
  select inv.character_id into cid from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where ii.id = rid and exists (select 1 from public.item_spell_grants g where g.item_id = ii.item_id and g.activation <> 'permanent');
  if cid is not null then perform public._sync_item_spell_grants(cid); end if;
  return null;
end $$;
drop trigger if exists inventory_item_knowledge_item_grants on public.inventory_item_knowledge;
create trigger inventory_item_knowledge_item_grants after insert or delete or update of state on public.inventory_item_knowledge
  for each row execute function public._item_grants_on_knowledge();

create or replace function public._item_grants_on_permanent()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (tg_op <> 'DELETE' and new.kind = 'spell') or (tg_op <> 'INSERT' and old.kind = 'spell') then
    perform public._sync_item_spell_grants(case when tg_op = 'DELETE' then old.character_id else new.character_id end);
  end if;
  return null;
end $$;
drop trigger if exists character_permanent_effects_item_grants on public.character_permanent_effects;
create trigger character_permanent_effects_item_grants after insert or delete or update on public.character_permanent_effects
  for each row execute function public._item_grants_on_permanent();
revoke all on function public._item_grants_on_inventory(), public._item_grants_on_equipment(), public._item_grants_on_knowledge(),
  public._item_grants_on_permanent() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------- 7. use_inventory_item (+ request)
-- A consumed item with permanent effects (item_effects / item_spell_grants activation 'permanent') writes them to the character
-- that used it, once per unit and per request id: a repeated request (network retry) replays without using another one. Used
-- while unidentified: the effects still apply (the source shown to the player is the disguise), the answer names none of them.
-- From a party stash (no character) nothing permanent is applied.
drop function if exists public.use_inventory_item(uuid, integer);
CREATE OR REPLACE FUNCTION public.use_inventory_item(p_item uuid, p_quantity integer DEFAULT 1, p_request uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; it public.items; consumable boolean; remaining int; gone boolean := false; fx jsonb; res jsonb;
  masked boolean; kind text; iid text;
  ch uuid; unident boolean; lbl text; req uuid; u int; perm jsonb := '[]'; rc uuid;   -- 20261114000500
begin
  -- 20261114000500: a request that already applied permanent effects is answered again, nothing is used twice
  if p_request is not null then
    select p.character_id into rc from public.character_permanent_effects p where p.use_request = p_request limit 1;
    if rc is not null then
      if not public.can_access_character(rc) then raise exception 'Not allowed' using errcode = '42501'; end if;
      return jsonb_build_object('replayed', true, 'consumed', true, 'effects', '[]'::jsonb, 'permanent', '[]'::jsonb);
    end if;
  end if;
  perform public._gov_gate_item(p_item, 'runtime.resources');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  if p_quantity is null or p_quantity < 1 then raise exception 'Quantity must be at least 1'; end if;
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id is null then raise exception 'Only catalog items can be used'; end if;
  if r.quantity < 1 then raise exception 'Nothing left to use' using errcode = '22003'; end if;
  select * into it from public.items where id = r.item_id;
  consumable := coalesce(r.consumable_override, it.is_consumable);
  -- 20261112000300
  masked := exists (select 1 from public.inventory_item_knowledge k where k.inventory_item_id = r.id and k.state <> 'identified')
            and not public._inventory_knows_all(r.inventory_id);
  kind := case when masked then (select f.kind_id from public._inventory_face(r.id) f) else it.kind_id end;
  iid := case when masked then null else r.item_id end;
  if masked then fx := '[]'::jsonb;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
             'effect_type', e.effect_type, 'dice_expression', e.dice_expression, 'flat_value', e.flat_value,
             'damage_type_id', e.damage_type_id, 'duration', e.duration, 'target_type', e.target_type, 'effect_data', e.effect_data)
             order by e.seq), '[]'::jsonb) into fx
    from public.consumable_effects e where e.item_id = r.item_id;
  end if;
  -- 20261114000500: who gets the permanent effects, and the source a player may see (before the row is gone)
  select i.character_id into ch from public.inventories i where i.id = r.inventory_id;
  unident := exists (select 1 from public.inventory_item_knowledge k where k.inventory_item_id = r.id and k.state <> 'identified');
  lbl := left(case when unident then coalesce(nullif(r.custom_name, ''), nullif(r.name, ''), 'Unidentified item')
                   else coalesce(nullif(r.custom_name, ''), it.name) end, 120);

  if not consumable then
    perform public.log_inventory_event(r.inventory_id, r.id, 'use', 0, r.item_id,
                                       jsonb_build_object('consumed', false, 'previous_quantity', r.quantity));
    res := jsonb_build_object('item_id', iid, 'kind_id', kind, 'name', coalesce(r.custom_name, r.name), 'consumed', false,
                              'quantity_used', 0, 'previous_quantity', r.quantity, 'remaining', r.quantity, 'deleted', false,
                              'state', r.state, 'effects', fx, 'unidentified', masked, 'permanent', '[]'::jsonb);
    perform public._rpc_end(); return res;
  end if;
  if r.quantity < p_quantity then raise exception 'Not enough items (have %, need %)', r.quantity, p_quantity using errcode = '22003'; end if;
  remaining := r.quantity - p_quantity;
  if remaining = 0 then
    delete from public.inventory_items where id = r.id;
    gone := true;
  else
    update public.inventory_items set quantity = remaining where id = r.id;
  end if;
  perform public.log_inventory_event(r.inventory_id, case when gone then null else r.id end, 'use', -p_quantity, r.item_id,
    jsonb_build_object('consumed', true, 'previous_quantity', r.quantity, 'remaining', remaining, 'deleted', gone,
                       'name', coalesce(r.custom_name, r.name), 'state', r.state));
  -- 20261114000500: permanent effects and spells, once per used unit
  if ch is not null and (exists (select 1 from public.item_effects e where e.item_id = r.item_id and e.activation = 'permanent')
                         or exists (select 1 from public.item_spell_grants g where g.item_id = r.item_id and g.activation = 'permanent')) then
    req := coalesce(p_request, gen_random_uuid());
    for u in 1 .. p_quantity loop
      insert into public.character_permanent_effects (character_id, kind, use_request, unit, seq, source_item_id, source_true_name, source_label,
                                                      masked, effect_type, target, value, max_score)
      select ch, 'effect', req, u, e.seq, r.item_id, left(it.name, 120), lbl, unident, e.effect_type, e.target, e.value, e.max_score
      from public.item_effects e where e.item_id = r.item_id and e.activation = 'permanent';
      insert into public.character_permanent_effects (character_id, kind, use_request, unit, seq, source_item_id, source_true_name, source_label,
                                                      masked, spell_version_id, casting, uses, recharge, ability)
      select ch, 'spell', req, u, g.seq, r.item_id, left(it.name, 120), lbl, unident, g.spell_version_id, g.casting, g.uses, g.recharge, g.ability
      from public.item_spell_grants g where g.item_id = r.item_id and g.activation = 'permanent';
    end loop;
    if not masked then
      select coalesce(jsonb_agg(jsonb_build_object('kind', p.kind, 'effect_type', p.effect_type, 'target', p.target, 'value', p.value,
                                                   'spell', sv.name, 'casting', p.casting, 'uses', p.uses, 'recharge', p.recharge)
                                order by p.unit, p.kind, p.seq), '[]') into perm
      from public.character_permanent_effects p left join public.spell_versions sv on sv.id = p.spell_version_id
      where p.character_id = ch and p.use_request = req;
    end if;
  end if;
  res := jsonb_build_object('item_id', iid, 'kind_id', kind, 'name', coalesce(r.custom_name, r.name), 'consumed', true,
                            'quantity_used', p_quantity, 'previous_quantity', r.quantity, 'remaining', remaining, 'deleted', gone,
                            'state', r.state, 'effects', fx, 'unidentified', masked, 'permanent', perm);
  perform public._rpc_end(); return res;
end;
$function$;
revoke all on function public.use_inventory_item(uuid, integer, uuid) from public, anon;
grant execute on function public.use_inventory_item(uuid, integer, uuid) to authenticated, service_role;

-- ------------------------------------------------------------------------------------------------ 8. the DM reverts a permanent effect
create or replace function public.revert_permanent_effect(p_effect uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.character_permanent_effects;
begin
  select * into p from public.character_permanent_effects where id = p_effect for update;
  if not found then
    raise exception 'Only the DM of the character''s campaign can see or change hidden information' using errcode = '42501';
  end if;
  perform public._dm_hidden_gate(p.character_id);                   -- campaign DM or admin, else 42501
  if p.reverted_at is null then
    update public.character_permanent_effects set reverted_at = now(), reverted_by = auth.uid(), revert_reason = left(nullif(btrim(p_reason), ''), 300)
    where id = p_effect;
  end if;
  return jsonb_build_object('id', p_effect, 'character_id', p.character_id, 'reverted', true, 'already', p.reverted_at is not null);
end $$;
revoke all on function public.revert_permanent_effect(uuid, text) from public, anon;
grant execute on function public.revert_permanent_effect(uuid, text) to authenticated;
grant execute on function public._character_knows_all(uuid) to authenticated;

-- ---------------------------------------------------------------- 9. homebrew writer (body of 20261107000300 + effects / spells)
CREATE OR REPLACE FUNCTION public._write_homebrew(p_id text, p_def jsonb, p_stats jsonb, p_is_new boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  allowed_def constant text[] := array['name','kind_id','category_id','description','weight_lb','cost_value','cost_unit','rarity_id',
                                       'is_magic','requires_attunement','is_consumable','stackable','campaign_id',
                                       'icon_key','details',    -- 20261107000300
                                       'effects','spells'];     -- 20261114000500: DM content items only (cc-)
  k text; prev public.items;
  v_name text; v_kind text; v_cat text; v_desc text; v_weight numeric; v_cost numeric; v_unit text; v_rarity text;
  v_magic boolean; v_att boolean; v_cons boolean; v_stack boolean; v_campaign uuid;
  s jsonb := coalesce(p_stats, '{}'::jsonb); w jsonb; a jsonb; c jsonb; e jsonb;
  dice_re constant text := '^([1-9][0-9]?d(4|6|8|10|12|20|100)([+-][0-9]{1,3})?|[0-9]{1,3})$';
  props text[]; grp text; rtype text; v_ammo text; rn int; rm int; vd text; dd text; dt text; mode text; cap int;
  is_shield boolean; base int; bonus int; v_icon text; v_details jsonb;
  -- 20261114000500
  fx jsonb; fx_type text; fx_act text; fx_target text; fx_val numeric; fx_max int; fx_list jsonb := '[]'; gs_list jsonb := '[]';
  gs_cast text; gs_uses int; gs_rech text; has_fx boolean; has_gs boolean;
  abil constant text[] := array['str', 'dex', 'con', 'int', 'wis', 'cha'];
  skl constant text[] := array['acrobatics', 'animal_handling', 'arcana', 'athletics', 'deception', 'history', 'insight',
    'intimidation', 'investigation', 'medicine', 'nature', 'perception', 'performance', 'persuasion', 'religion',
    'sleight_of_hand', 'stealth', 'survival'];
  acts constant text[] := array['owned', 'equipped', 'attuned', 'equipped_and_attuned', 'permanent'];
begin
  if p_def is null or jsonb_typeof(p_def) <> 'object' then raise exception 'Item definition is missing' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_def) loop
    if not k = any (allowed_def) then raise exception 'Field "%" cannot be set on a homebrew item', k using errcode = '22023'; end if;
  end loop;
  for k in select jsonb_object_keys(s) loop
    if not k = any (array['weapon','armor','ammunition','container','effect']) then raise exception 'Unknown stats section "%"', k using errcode = '22023'; end if;
  end loop;
  -- 20261031000100: a section without any value (an untouched part of a form, e.g. only an unchecked "Stealth disadvantage"
  -- box) is no section: it must not block a non-armor / non-weapon item. A section WITH values still has to fit the type.
  for k in select jsonb_object_keys(s) loop
    if jsonb_typeof(s -> k) = 'object' and not exists (select 1 from jsonb_each(s -> k) x
        where x.value not in ('null'::jsonb, 'false'::jsonb, '""'::jsonb, '[]'::jsonb, '{}'::jsonb)) then
      s := s - k;
    end if;
  end loop;

  if not p_is_new then select * into prev from public.items where id = p_id; end if;

  v_name := public._j_text(p_def, 'name', 120, 'Name');
  if v_name is null then raise exception 'Name is required' using errcode = '22023'; end if;
  v_kind := coalesce(public._j_text(p_def, 'kind_id', 40, 'Type'), prev.kind_id);
  if not p_is_new and v_kind is distinct from prev.kind_id then
    raise exception 'The type of a homebrew item cannot change; create a new item instead' using errcode = '22023';
  end if;
  if v_kind is null or not v_kind = any (array['weapon','armor','tool','gear','ammunition','potion','scroll','magic_item','herbs_plants']) then
    raise exception 'Type must be one of weapon, armor, tool, gear, ammunition, potion, scroll, magic item, herbs & plants' using errcode = '22023';
  end if;
  v_cat := public._j_text(p_def, 'category_id', 60, 'Category');
  if v_cat is not null and not exists (select 1 from public.item_categories where id = v_cat and kind_id = v_kind) then
    raise exception 'Category "%" does not belong to type "%"', v_cat, v_kind using errcode = '22023';
  end if;
  if v_kind = 'armor' and v_cat is null then raise exception 'Armor needs a category (light, medium, heavy armor or shield)' using errcode = '22023'; end if;
  v_desc := public._j_text(p_def, 'description', 4000, 'Description');
  v_weight := public._j_num(p_def, 'weight_lb', 0, 100000, 'Weight');
  v_cost := public._j_num(p_def, 'cost_value', 0, 100000000, 'Cost');
  v_unit := public._j_text(p_def, 'cost_unit', 2, 'Cost unit');
  if (v_cost is null) <> (v_unit is null) then raise exception 'Cost needs both an amount and a coin' using errcode = '22023'; end if;
  if v_unit is not null and not exists (select 1 from public.currencies where id = v_unit) then raise exception 'Unknown coin "%"', v_unit using errcode = '22023'; end if;
  v_rarity := public._j_text(p_def, 'rarity_id', 20, 'Rarity');
  if v_rarity is not null and not exists (select 1 from public.rarities where id = v_rarity) then raise exception 'Unknown rarity "%"', v_rarity using errcode = '22023'; end if;
  v_magic := public._j_bool(p_def, 'is_magic', false);
  if v_magic and v_rarity is null then raise exception 'A magic item needs a rarity' using errcode = '22023'; end if;
  v_att := public._j_bool(p_def, 'requires_attunement', false);
  v_cons := public._j_bool(p_def, 'is_consumable', v_kind in ('potion', 'scroll', 'ammunition'));
  if v_kind in ('potion', 'scroll') and not v_cons then raise exception 'Potions and scrolls are consumable' using errcode = '22023'; end if;
  v_stack := public._j_bool(p_def, 'stackable', v_kind in ('potion', 'scroll', 'ammunition', 'herbs_plants'));
  -- 20261107000300: an icon from the internal gallery (a registry key, never a URL, SVG or HTML) and optional typed details
  if not p_is_new and not p_def ? 'icon_key' then v_icon := prev.icon_key;
  else v_icon := public._item_icon_key(p_def ->> 'icon_key');
  end if;
  if not p_is_new and not p_def ? 'details' then v_details := coalesce(prev.details, '{}'::jsonb);
  else v_details := public._item_details(v_kind, p_def -> 'details');
  end if;
  if not p_is_new and not p_def ? 'campaign_id' then
    v_campaign := prev.campaign_id;            -- an update that does not mention visibility keeps it
  else
    begin
      v_campaign := nullif(p_def ->> 'campaign_id', '')::uuid;
    exception when others then raise exception 'Invalid campaign' using errcode = '22023';
    end;
  end if;
  if p_is_new or v_campaign is distinct from prev.campaign_id then
    if v_campaign is not null and not (public.is_admin() or public.is_campaign_member(v_campaign)) then
      raise exception 'You are not a member of that campaign' using errcode = '42501';
    end if;
    if not p_is_new and not (prev.owner_id = auth.uid() or public.is_admin()) then
      raise exception 'Only the author can change who can see this item' using errcode = '42501';
    end if;
    if not p_is_new and v_campaign is null and exists (
         select 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
         left join public.characters ch on ch.id = inv.character_id
         where ii.item_id = p_id and (inv.kind <> 'character' or ch.owner_id is distinct from prev.owner_id)) then
      raise exception 'This item is used in other characters'' inventories and cannot become private' using errcode = '22023';
    end if;
  end if;

  -- typed stats (validated before anything is written)
  w := s -> 'weapon'; a := s -> 'armor'; c := s -> 'container'; e := s -> 'effect';
  if w is not null and v_kind <> 'weapon' then raise exception 'Weapon stats only apply to weapons' using errcode = '22023'; end if;
  if a is not null and v_kind <> 'armor' then raise exception 'Armor stats only apply to armor' using errcode = '22023'; end if;
  if s ? 'ammunition' and v_kind <> 'ammunition' then raise exception 'Ammunition stats only apply to ammunition' using errcode = '22023'; end if;
  if v_kind = 'weapon' then
    w := coalesce(w, '{}'::jsonb);
    grp := coalesce(public._j_text(w, 'weapon_group', 10, 'Weapon group'), case when v_cat = 'firearm' then 'firearm' when v_cat like 'simple%' then 'simple' else 'martial' end);
    if grp not in ('simple', 'martial', 'firearm') then raise exception 'Weapon group must be simple, martial or firearm' using errcode = '22023'; end if;
    if (grp = 'firearm') <> (v_cat = 'firearm') and v_cat is not null then
      raise exception 'Firearms use the firearm category and weapon group together' using errcode = '22023';
    end if;
    dd := public._j_text(w, 'damage_dice', 12, 'Damage dice');
    if dd is null then raise exception 'A weapon needs damage dice (for example 1d8)' using errcode = '22023'; end if;   -- 20261031000100
    if dd is not null and dd !~ dice_re then raise exception 'Damage dice must look like 1d8, 2d6+1 or a flat number' using errcode = '22023'; end if;
    dt := public._j_text(w, 'damage_type_id', 20, 'Damage type');
    if dt is not null and not exists (select 1 from public.damage_types where id = dt) then raise exception 'Unknown damage type "%"', dt using errcode = '22023'; end if;
    if dt is not null and dd is null then raise exception 'A damage type needs damage dice' using errcode = '22023'; end if;
    props := coalesce(array(select jsonb_array_elements_text(coalesce(w -> 'properties', '[]'::jsonb))), '{}');
    if exists (select 1 from unnest(props) p where not exists (select 1 from public.weapon_properties wp where wp.id = p)) then
      raise exception 'Unknown weapon property' using errcode = '22023';
    end if;
    vd := public._j_text(w, 'versatile_damage', 12, 'Versatile damage');
    if vd is not null and not 'versatile' = any (props) then raise exception 'Versatile damage needs the versatile property' using errcode = '22023'; end if;
    if vd is not null and vd !~ dice_re then raise exception 'Versatile damage must look like 1d10' using errcode = '22023'; end if;
    rn := public._j_int(w, 'range_normal', 1, 10000, 'Normal range');
    rm := public._j_int(w, 'range_max', 1, 10000, 'Maximum range');
    if (rn is null) <> (rm is null) then raise exception 'Give both the normal and the maximum range' using errcode = '22023'; end if;
    if rm < rn then raise exception 'The maximum range cannot be smaller than the normal range' using errcode = '22023'; end if;
    v_ammo := public._j_text(w, 'ammo_type_id', 60, 'Ammunition type');
    if v_ammo is not null and not exists (select 1 from public.ammo_types where id = v_ammo) then raise exception 'Unknown ammunition type' using errcode = '22023'; end if;
    if v_ammo is not null and not 'ammunition' = any (props) then raise exception 'An ammunition type needs the ammunition property' using errcode = '22023'; end if;
    rtype := case when 'ammunition' = any (props) then 'ammunition' when 'thrown' = any (props) then 'thrown' end;
    if grp = 'firearm' and (public._j_int(w, 'reload', 1, 50, 'Reload') is null or public._j_int(w, 'misfire', 1, 20, 'Misfire') is null) then
      raise exception 'A firearm needs reload and misfire' using errcode = '22023';
    end if;
    if grp <> 'firearm' and (w ? 'reload' or w ? 'misfire') and (w ->> 'reload' is not null or w ->> 'misfire' is not null) then
      raise exception 'Reload and misfire only apply to firearms' using errcode = '22023';
    end if;
  end if;
  if v_kind = 'armor' then
    a := coalesce(a, '{}'::jsonb);
    is_shield := v_cat = 'shield';
    if is_shield then
      bonus := public._j_int(a, 'ac_bonus', 0, 10, 'AC bonus');
      if bonus is null then raise exception 'A shield needs an AC bonus' using errcode = '22023'; end if;
      if a ->> 'base_ac' is not null then raise exception 'A shield uses an AC bonus, not a base AC' using errcode = '22023'; end if;
      mode := 'none'; cap := null;
    else
      base := public._j_int(a, 'base_ac', 1, 30, 'Base AC');
      if base is null then raise exception 'Armor needs a base AC' using errcode = '22023'; end if;
      mode := coalesce(public._j_text(a, 'dex_modifier_mode', 10, 'Dexterity mode'),
                       case v_cat when 'light-armor' then 'full' when 'medium-armor' then 'capped' else 'none' end);
      if mode not in ('full', 'capped', 'none') then raise exception 'Dexterity mode must be full, capped or none' using errcode = '22023'; end if;
      cap := public._j_int(a, 'dex_cap', 0, 10, 'Dexterity cap');
      if mode = 'capped' then cap := coalesce(cap, 2); elsif cap is not null then raise exception 'A Dexterity cap only applies to capped mode' using errcode = '22023'; end if;
    end if;
    perform public._j_int(a, 'strength_requirement', 1, 30, 'Strength requirement');
  end if;
  if v_kind = 'ammunition' then
    if public._j_text(s -> 'ammunition', 'ammo_type_id', 60, 'Ammunition type') is null
       or not exists (select 1 from public.ammo_types where id = s -> 'ammunition' ->> 'ammo_type_id') then
      raise exception 'Ammunition needs a known ammunition type' using errcode = '22023';
    end if;
    perform public._j_int(s -> 'ammunition', 'pack_size', 1, 1000, 'Pack size');
  end if;
  if c is not null then
    perform public._j_num(c, 'capacity_weight_lb', 0, 100000, 'Capacity (weight)');
    perform public._j_num(c, 'capacity_volume_cuft', 0, 100000, 'Capacity (volume)');
    perform public._j_bool(c, 'weightless_contents', false);
    perform public._j_bool(c, 'extradimensional', false);
  end if;
  if e is not null then
    if not v_cons then raise exception 'Only consumable items can have a use effect' using errcode = '22023'; end if;
    if coalesce(e ->> 'effect_type', '') not in ('healing', 'damage', 'buff', 'condition', 'cast_spell', 'other') then
      raise exception 'Unknown effect type' using errcode = '22023';
    end if;
    if public._j_text(e, 'dice_expression', 12, 'Effect dice') !~ '^[1-9][0-9]?d[0-9]{1,3}$' then
      raise exception 'Effect dice must look like 2d4 (put the bonus in the flat value)' using errcode = '22023';
    end if;
    perform public._j_int(e, 'flat_value', -1000, 1000, 'Flat value');
    if e ->> 'effect_type' in ('healing', 'damage') and e ->> 'dice_expression' is null and e ->> 'flat_value' is null then
      raise exception 'Healing and damage need dice or a flat value' using errcode = '22023';
    end if;
    if e ->> 'damage_type_id' is not null and (e ->> 'effect_type' <> 'damage' or not exists (select 1 from public.damage_types where id = e ->> 'damage_type_id')) then
      raise exception 'A damage type only applies to a damage effect' using errcode = '22023';
    end if;
    perform public._j_text(e, 'duration', 100, 'Duration');
    if e ->> 'target_type' is not null and e ->> 'target_type' not in ('self', 'creature', 'area', 'object') then
      raise exception 'Unknown target type' using errcode = '22023';
    end if;
  end if;

  -- 20261114000500: automated effects and granted spells. Only DM content items (cc-...) may have them: player homebrew
  -- (create / update homebrew item) cannot author a +2 item. Validated here, so a DM sees a readable message on Validate.
  has_fx := p_def ? 'effects' and jsonb_typeof(p_def -> 'effects') <> 'null';
  has_gs := p_def ? 'spells' and jsonb_typeof(p_def -> 'spells') <> 'null';
  if (has_fx or has_gs) and p_id !~ '^cc-' then
    raise exception 'Only items made in DM Space can have automated effects or granted spells' using errcode = '42501';
  end if;
  if has_fx then
    if jsonb_typeof(p_def -> 'effects') <> 'array' or jsonb_array_length(p_def -> 'effects') > 20 then
      raise exception 'Effects are a list of at most 20 effects' using errcode = '22023';
    end if;
    for fx in select x from jsonb_array_elements(p_def -> 'effects') x loop
      if jsonb_typeof(fx) <> 'object' then raise exception 'An effect must be an object' using errcode = '22023'; end if;
      fx_type := nullif(fx ->> 'type', '');
      if fx_type is null or not fx_type = any (array['ability_bonus', 'ability_override', 'skill_bonus', 'save_bonus', 'ac_bonus',
           'initiative_bonus', 'speed_bonus', 'speed_penalty', 'resistance', 'skill_advantage', 'skill_disadvantage']) then
        raise exception 'Choose what each effect changes (unknown effect "%")', coalesce(fx_type, '') using errcode = '22023';
      end if;
      fx_act := coalesce(nullif(fx ->> 'activation', ''), case when v_att then 'attuned' else 'equipped' end);
      if not fx_act = any (acts) then
        raise exception 'Choose when the effect applies: while carried, equipped, attuned, equipped and attuned, or permanently when used' using errcode = '22023';
      end if;
      if v_att and fx_act in ('owned', 'equipped') then
        raise exception 'This item requires attunement: its effects apply while attuned (or permanently when it is used)' using errcode = '22023';
      end if;
      if fx_act = 'permanent' and not v_cons then
        raise exception 'A permanent effect applies when the item is used up: make the item consumable' using errcode = '22023';
      end if;
      if fx_act = 'permanent' and not fx_type = any (array['ability_bonus', 'ac_bonus', 'save_bonus', 'skill_bonus', 'initiative_bonus', 'speed_bonus']) then
        raise exception 'A permanent effect is an ability, AC, saving throw, skill, initiative or speed bonus' using errcode = '22023';
      end if;
      fx_target := nullif(btrim(coalesce(fx ->> 'target', '')), '');
      if fx_type in ('ability_bonus', 'ability_override') then
        if fx_target is null or not fx_target = any (abil) then raise exception 'Choose the ability the effect changes' using errcode = '22023'; end if;
      elsif fx_type in ('skill_bonus', 'skill_advantage', 'skill_disadvantage') then
        if fx_target is null or not fx_target = any (skl) then raise exception 'Choose the skill the effect changes' using errcode = '22023'; end if;
      elsif fx_type = 'save_bonus' then
        if fx_target is not null and not fx_target = any (abil) then
          raise exception 'A saving throw bonus applies to one ability''s save, or to all saves (no target)' using errcode = '22023';
        end if;
      elsif fx_type = 'resistance' then
        if fx_target is null or not exists (select 1 from public.damage_types where id = fx_target) then
          raise exception 'Choose the damage type of the resistance' using errcode = '22023';
        end if;
      else
        fx_target := null;                                             -- AC, initiative, speed: no target
      end if;
      begin
        fx_val := nullif(fx ->> 'value', '')::numeric;
      exception when others then raise exception 'The value of an effect must be a number' using errcode = '22023';
      end;
      if fx_type in ('resistance', 'skill_advantage', 'skill_disadvantage') then fx_val := null;
      elsif fx_val is null or fx_val <> trunc(fx_val) then raise exception 'Give each effect a whole number value' using errcode = '22023';
      elsif fx_type = 'ability_override' and fx_val not between 1 and 30 then raise exception 'An ability score is set to a value from 1 to 30' using errcode = '22023';
      elsif fx_type in ('speed_bonus', 'speed_penalty') and fx_val not between -120 and 120 then raise exception 'A speed change is at most 120 ft' using errcode = '22023';
      elsif fx_type not in ('ability_override', 'speed_bonus', 'speed_penalty') and fx_val not between -10 and 10 then
        raise exception 'A bonus is a number from -10 to +10' using errcode = '22023';
      end if;
      fx_max := public._j_int(fx, 'max', 1, 30, 'Maximum score');
      if fx_max is not null and not (fx_type = 'ability_bonus' and fx_act = 'permanent') then
        raise exception 'A maximum score only applies to a permanent ability increase' using errcode = '22023';
      end if;
      fx_list := fx_list || jsonb_build_array(jsonb_build_object('type', fx_type, 'target', fx_target, 'value', fx_val, 'activation', fx_act,
                                                                 'max', fx_max));
    end loop;
  end if;
  if has_gs then
    if jsonb_typeof(p_def -> 'spells') <> 'array' or jsonb_array_length(p_def -> 'spells') > 10 then
      raise exception 'Granted spells are a list of at most 10 spells' using errcode = '22023';
    end if;
    for fx in select x from jsonb_array_elements(p_def -> 'spells') x loop
      if jsonb_typeof(fx) <> 'object' then raise exception 'A granted spell must be an object' using errcode = '22023'; end if;
      if nullif(fx ->> 'spell', '') is null or not exists (select 1 from public.spell_versions where id = fx ->> 'spell') then
        raise exception 'Choose a spell from the list for each granted spell (unknown "%")', coalesce(fx ->> 'spell', '') using errcode = '22023';
      end if;
      gs_cast := coalesce(nullif(fx ->> 'casting', ''), 'per_rest');
      if gs_cast not in ('at_will', 'spell_slots', 'per_rest') then
        raise exception 'A granted spell is cast at will, with the character''s spell slots, or a number of times per rest' using errcode = '22023';
      end if;
      gs_uses := public._j_int(fx, 'uses', 1, 20, 'Uses');
      gs_rech := nullif(fx ->> 'recharge', '');
      if gs_cast = 'per_rest' then
        gs_uses := coalesce(gs_uses, 1); gs_rech := coalesce(gs_rech, 'long_rest');
        if gs_rech not in ('short_rest', 'long_rest') then raise exception 'The uses come back after a short or a long rest' using errcode = '22023'; end if;
      else
        gs_uses := null; gs_rech := null;
      end if;
      fx_act := coalesce(nullif(fx ->> 'activation', ''), case when v_att then 'attuned' else 'equipped' end);
      if not fx_act = any (acts) then
        raise exception 'Choose when the spell is granted: while carried, equipped, attuned, equipped and attuned, or permanently when used' using errcode = '22023';
      end if;
      if v_att and fx_act in ('owned', 'equipped') then
        raise exception 'This item requires attunement: its spells are granted while attuned (or permanently when it is used)' using errcode = '22023';
      end if;
      if fx_act = 'permanent' and not v_cons then
        raise exception 'A permanent spell is granted when the item is used up: make the item consumable' using errcode = '22023';
      end if;
      if nullif(fx ->> 'ability', '') is not null and not (fx ->> 'ability') = any (abil) then
        raise exception 'Unknown spellcasting ability' using errcode = '22023';
      end if;
      gs_list := gs_list || jsonb_build_array(jsonb_build_object('spell', fx ->> 'spell', 'casting', gs_cast, 'uses', gs_uses, 'recharge', gs_rech,
                                                                 'activation', fx_act, 'ability', nullif(fx ->> 'ability', '')));
    end loop;
  end if;

  -- write the item
  if p_is_new then
    insert into public.items (id, kind_id, category_id, name, description, weight_lb, cost_value, cost_unit, rarity_id, is_magic,
                              requires_attunement, is_consumable, stackable, owner_id, campaign_id, data_source_id, source_label, updated_by,
                              icon_key, details)
    values (p_id, v_kind, v_cat, v_name, v_desc, v_weight, v_cost, v_unit, v_rarity, v_magic, v_att, v_cons, v_stack,
            auth.uid(), v_campaign, 'homebrew', 'Homebrew', auth.uid(), v_icon, v_details);
  else
    update public.items set category_id = v_cat, name = v_name, description = v_desc, weight_lb = v_weight, cost_value = v_cost,
           cost_unit = v_unit, rarity_id = v_rarity, is_magic = v_magic, requires_attunement = v_att, is_consumable = v_cons,
           stackable = v_stack, campaign_id = v_campaign, updated_by = auth.uid(), icon_key = v_icon, details = v_details
    where id = p_id;
    delete from public.weapon_stats where item_id = p_id;          -- cascades property links and firearm stats
    delete from public.armor_stats where item_id = p_id;
    delete from public.ammunition_stats where item_id = p_id;
    delete from public.container_stats where item_id = p_id;
    delete from public.consumable_effects where item_id = p_id;
    if has_fx then delete from public.item_effects where item_id = p_id; end if;          -- 20261114000500
    if has_gs then delete from public.item_spell_grants where item_id = p_id; end if;
  end if;

  -- write the typed stats
  if v_kind = 'weapon' then
    insert into public.weapon_stats (item_id, weapon_group, damage_dice, damage_type_id, versatile_damage, is_ranged, range_type,
                                     range_normal, range_max, ammo_type_id)
    values (p_id, grp, dd, dt, vd, grp = 'firearm' or coalesce(v_cat, '') like '%ranged' or 'ammunition' = any (props), rtype, rn, rm, v_ammo);
    insert into public.weapon_property_links (item_id, property_id) select p_id, p from unnest(props) p on conflict do nothing;
    if grp = 'firearm' then
      insert into public.firearm_stats (item_id, reload, misfire) values (p_id, (w ->> 'reload')::int, (w ->> 'misfire')::int);
    end if;
  elsif v_kind = 'armor' then
    insert into public.armor_stats (item_id, base_ac, ac_bonus, dex_modifier_mode, dex_cap, strength_requirement, stealth_disadvantage, is_shield)
    values (p_id, case when is_shield then null else base end, case when is_shield then bonus end, mode, cap,
            public._j_int(a, 'strength_requirement', 1, 30, 'Strength requirement'), public._j_bool(a, 'stealth_disadvantage', false), is_shield);
  elsif v_kind = 'ammunition' then
    insert into public.ammunition_stats (item_id, ammo_type_id, pack_size, pack_cost_cp)
    values (p_id, s -> 'ammunition' ->> 'ammo_type_id', coalesce(public._j_int(s -> 'ammunition', 'pack_size', 1, 1000, 'Pack size'), 1),
            (select cost_cp from public.items where id = p_id));
  end if;
  if c is not null then
    insert into public.container_stats (item_id, capacity_weight_lb, capacity_volume_cuft, weightless_contents, extradimensional)
    values (p_id, public._j_num(c, 'capacity_weight_lb', 0, 100000, 'Capacity (weight)'), public._j_num(c, 'capacity_volume_cuft', 0, 100000, 'Capacity (volume)'),
            public._j_bool(c, 'weightless_contents', false), public._j_bool(c, 'extradimensional', false));
  end if;
  if e is not null then
    insert into public.consumable_effects (item_id, seq, effect_type, dice_expression, flat_value, damage_type_id, duration, target_type)
    values (p_id, 1, e ->> 'effect_type', public._j_text(e, 'dice_expression', 12, 'Effect dice'), public._j_int(e, 'flat_value', -1000, 1000, 'Flat value'),
            public._j_text(e, 'damage_type_id', 20, 'Damage type'), public._j_text(e, 'duration', 100, 'Duration'), public._j_text(e, 'target_type', 10, 'Target'));
  end if;
  -- 20261114000500: effects and granted spells (validated above; item_effects_before_write checks again)
  insert into public.item_effects (item_id, seq, effect_type, value, target, activation, stacking, max_score)
  select p_id, o::int, x ->> 'type', (x ->> 'value')::numeric, x ->> 'target', x ->> 'activation',
         case when x ->> 'type' = 'ability_override' then 'override' else 'additive' end, (x ->> 'max')::int
  from jsonb_array_elements(fx_list) with ordinality t(x, o);
  insert into public.item_spell_grants (item_id, seq, spell_version_id, casting, uses, recharge, activation, ability)
  select p_id, o::int, x ->> 'spell', x ->> 'casting', (x ->> 'uses')::int, x ->> 'recharge', x ->> 'activation', x ->> 'ability'
  from jsonb_array_elements(gs_list) with ordinality t(x, o);
end;
$function$;

-- materialize the grants of items already held (none exist before this release; harmless no-op otherwise)
do $$
declare c uuid;
begin
  for c in select distinct inv.character_id from public.inventories inv join public.inventory_items ii on ii.inventory_id = inv.id
           join public.item_spell_grants g on g.item_id = ii.item_id where inv.character_id is not null loop
    perform public._sync_item_spell_grants(c);
  end loop;
end $$;

update tl_cache.global_rev set rev = rev + 1 where id = 1;
reset lock_timeout;
notify pgrst, 'reload schema';
