-- =============================================================================
-- Derived character stats: proficiencies, permanent item effects, derived AC / speed / weapon attacks.
-- Ruleset: D&D 5e (2014 PHB / SRD 5.1), as used by the catalog. See docs/DERIVED_CHARACTER_STATS.md.
--
-- Nothing here changes stored character statistics when equipment changes. get_character_derived_stats()
-- reads   characters (base data) + character_equipment (authoritative equipment) + armor/weapon stats
--       + item_effects / item_modifier_effects (activation: owned / equipped / attuned / equipped_and_attuned)
--       + character_proficiencies
-- and returns the derived state. It is SECURITY INVOKER, so every read goes through the existing RLS.
--
-- characters.equipment_proficiencies (jsonb flags) is kept as a mirror of character_proficiencies:
-- old clients and JSON import/export keep working; character_proficiencies is the source of truth.
-- =============================================================================

-- ---- proficiency groups (system lookup) -------------------------------------------------------------------
create table public.proficiency_groups (
  id                text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name              text not null,
  proficiency_type  text not null check (proficiency_type in ('weapon', 'armor', 'shield', 'tool')),
  weapon_group      text unique check (weapon_group in ('simple', 'martial', 'firearm')),   -- weapon_stats.weapon_group
  armor_category_id text unique references public.item_categories (id),                    -- items.category_id of armor
  legacy_flag       text unique,                                                           -- key in characters.equipment_proficiencies
  sort_order        int not null default 0,
  constraint proficiency_group_shape check (
       (proficiency_type = 'weapon' and weapon_group is not null and armor_category_id is null)
    or (proficiency_type in ('armor', 'shield') and armor_category_id is not null and weapon_group is null)
    or (proficiency_type = 'tool' and weapon_group is null and armor_category_id is null))
);

-- Migrations run before the reference seed, so on a fresh database the armor categories don't exist yet. Insert the
-- ones referenced below with the seed's exact values; the seed upserts them again later.
insert into public.item_kinds (id, name, sort_order) values ('armor', 'Armor', 20) on conflict (id) do nothing;
insert into public.item_categories (id, kind_id, name, sort_order) values
  ('light-armor', 'armor', 'Light Armor', 60),
  ('medium-armor', 'armor', 'Medium Armor', 70),
  ('heavy-armor', 'armor', 'Heavy Armor', 80),
  ('shield', 'armor', 'Shields', 90)
on conflict (id) do nothing;

insert into public.proficiency_groups (id, name, proficiency_type, weapon_group, armor_category_id, legacy_flag, sort_order) values
  ('simple-weapons',  'Simple Weapons',  'weapon', 'simple',  null,           'simple',   10),
  ('martial-weapons', 'Martial Weapons', 'weapon', 'martial', null,           'martial',  20),
  ('firearms',        'Firearms',        'weapon', 'firearm', null,           'firearms', 30),
  ('light-armor',     'Light Armor',     'armor',  null,      'light-armor',  'light',    40),
  ('medium-armor',    'Medium Armor',    'armor',  null,      'medium-armor', 'medium',   50),
  ('heavy-armor',     'Heavy Armor',     'armor',  null,      'heavy-armor',  'heavy',    60),
  ('shields',         'Shields',         'shield', null,      'shield',       'shields',  70);

-- ---- character proficiencies ------------------------------------------------------------------------------
create table public.character_proficiencies (
  id               uuid primary key default gen_random_uuid(),
  character_id     uuid not null references public.characters (id) on delete cascade,
  proficiency_type text not null check (proficiency_type in ('weapon', 'armor', 'shield', 'tool')),
  group_id         text references public.proficiency_groups (id),
  item_id          text references public.items (id) on delete cascade,     -- a specific weapon, armor, shield or tool
  source_type      text not null default 'manual'
                   check (source_type in ('manual', 'sheet', 'import', 'class', 'race', 'background', 'feat', 'item')),
  source_id        text,
  notes            text check (length(notes) <= 500),
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  constraint character_proficiency_target check ((group_id is null) <> (item_id is null))
);
-- the two unique indexes also serve every lookup by character
create unique index character_proficiencies_group_uniq on public.character_proficiencies (character_id, group_id) where group_id is not null;
create unique index character_proficiencies_item_uniq  on public.character_proficiencies (character_id, item_id)  where item_id is not null;

-- the proficiency type must match the group / the item (a weapon is a 'weapon', a shield a 'shield' ...)
create function public._proficiency_type_of_item(p_item text)
returns text
language sql stable security definer
set search_path = public, pg_temp
as $$
  select case when kind_id = 'weapon' then 'weapon'
              when kind_id = 'armor' and category_id = 'shield' then 'shield'
              when kind_id = 'armor' then 'armor'
              when kind_id = 'tool' then 'tool' end
  from public.items where id = p_item;
$$;

create function public.character_proficiencies_before_write()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare expected text;
begin
  if new.group_id is not null then
    select proficiency_type into expected from public.proficiency_groups where id = new.group_id;
  else
    expected := public._proficiency_type_of_item(new.item_id);
    if expected is null then
      raise exception 'Proficiency only applies to weapons, armor, shields and tools' using errcode = '22023';
    end if;
  end if;
  if expected is distinct from new.proficiency_type then
    raise exception 'Proficiency type % does not match % (expected %)', new.proficiency_type, coalesce(new.group_id, new.item_id), expected
      using errcode = '22023';
  end if;
  return new;
end;
$$;

create trigger character_proficiencies_before_write before insert or update on public.character_proficiencies
  for each row execute function public.character_proficiencies_before_write();

-- existing sheet checkboxes are explicit user data: carry them over (before the mirror triggers exist)
insert into public.character_proficiencies (character_id, proficiency_type, group_id, source_type, created_by)
select c.id, g.proficiency_type, g.id, 'sheet', null
from public.characters c
join public.proficiency_groups g on g.legacy_flag is not null and c.equipment_proficiencies ->> g.legacy_flag = 'true';

-- ---- mirror: character_proficiencies  ->  characters.equipment_proficiencies --------------------------------
create function public._equipment_proficiency_flags(p_character uuid)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_object_agg(g.legacy_flag, true), '{}'::jsonb)
  from public.character_proficiencies p
  join public.proficiency_groups g on g.id = p.group_id
  where p.character_id = p_character and g.legacy_flag is not null;
$$;

create function public.character_proficiencies_sync_flags()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cid uuid := coalesce(new.character_id, old.character_id); flags text[]; v jsonb;
begin
  if not exists (select 1 from public.characters where id = cid) then return null; end if;   -- character being deleted
  select array_agg(legacy_flag) into flags from public.proficiency_groups where legacy_flag is not null;
  update public.characters c
  set equipment_proficiencies = (c.equipment_proficiencies - flags) || public._equipment_proficiency_flags(cid)
  where c.id = cid
    and c.equipment_proficiencies is distinct from (c.equipment_proficiencies - flags) || public._equipment_proficiency_flags(cid);
  return null;
end;
$$;

create trigger character_proficiencies_sync_flags after insert or delete or update of group_id on public.character_proficiencies
  for each row execute function public.character_proficiencies_sync_flags();

-- ---- mirror: characters.equipment_proficiencies (old clients, JSON import)  ->  character_proficiencies -------
-- Only flags whose truth value changed are applied, so the round trip through the mirror above ends immediately.
create function public.characters_sync_proficiency_rows()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare g record; was boolean; now_on boolean;
begin
  for g in select * from public.proficiency_groups where legacy_flag is not null loop
    now_on := coalesce(new.equipment_proficiencies ->> g.legacy_flag = 'true', false);
    was := tg_op = 'UPDATE' and coalesce(old.equipment_proficiencies ->> g.legacy_flag = 'true', false);
    if now_on and not was then
      insert into public.character_proficiencies (character_id, proficiency_type, group_id, source_type)
      values (new.id, g.proficiency_type, g.id, case when tg_op = 'INSERT' then 'import' else 'sheet' end)
      on conflict (character_id, group_id) where group_id is not null do nothing;
    elsif was and not now_on then
      delete from public.character_proficiencies where character_id = new.id and group_id = g.id;
    end if;
  end loop;
  return null;
end;
$$;

create trigger characters_sync_proficiency_rows after insert or update of equipment_proficiencies on public.characters
  for each row execute function public.characters_sync_proficiency_rows();

-- ---- permanent item effects (catalog level) -----------------------------------------------------------------
-- Instance-level magic (Armor +1, Weapon +2 ...) stays in item_modifier_effects. These are effects of the item itself.
create table public.item_effects (
  item_id     text not null references public.items (id) on delete cascade,
  seq         int  not null default 1 check (seq > 0),
  effect_type text not null check (effect_type in (
                'ac_bonus', 'attack_bonus', 'damage_bonus', 'save_bonus', 'ability_bonus', 'ability_override',
                'speed_bonus', 'speed_penalty', 'resistance', 'carrying_capacity_bonus', 'skill_advantage', 'skill_disadvantage')),
  value       numeric,
  target      text,                                    -- ability / skill / damage type, depending on effect_type
  activation  text not null check (activation in ('owned', 'equipped', 'attuned', 'equipped_and_attuned')),
  stacking    text not null default 'additive' check (stacking in ('additive', 'highest_only', 'override', 'non_stacking_group')),
  stack_group text,
  priority    int  not null default 0,
  conditions  jsonb not null default '{}'::jsonb,      -- {"no_armor": true, "no_shield": true}
  primary key (item_id, seq),
  constraint item_effect_stack_group check ((stacking = 'non_stacking_group') = (stack_group is not null))
);

create function public.item_effects_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare abilities constant text[] := array['str', 'dex', 'con', 'int', 'wis', 'cha'];
        skills constant text[] := array['acrobatics', 'animal_handling', 'arcana', 'athletics', 'deception', 'history', 'insight',
          'intimidation', 'investigation', 'medicine', 'nature', 'perception', 'performance', 'persuasion', 'religion',
          'sleight_of_hand', 'stealth', 'survival'];
        k text; attune boolean;
begin
  if new.effect_type in ('ac_bonus', 'attack_bonus', 'damage_bonus', 'speed_bonus', 'speed_penalty', 'carrying_capacity_bonus') then
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
  elsif new.effect_type in ('skill_advantage', 'skill_disadvantage') then
    if new.target is null or not new.target = any (skills) then raise exception 'Unknown skill "%"', new.target using errcode = '22023'; end if;
  end if;
  if (new.stacking = 'override') <> (new.effect_type = 'ability_override') then
    raise exception 'Only ability_override uses the override stacking rule' using errcode = '22023';
  end if;
  for k in select jsonb_object_keys(new.conditions) loop
    if not k = any (array['no_armor', 'no_shield']) or jsonb_typeof(new.conditions -> k) <> 'boolean' then
      raise exception 'Unknown effect condition "%"', k using errcode = '22023';
    end if;
  end loop;
  -- an item that needs attunement never works merely because it is owned or equipped
  select requires_attunement into attune from public.items where id = new.item_id;
  if attune and new.activation not in ('attuned', 'equipped_and_attuned') then
    raise exception 'This item requires attunement: use activation attuned or equipped_and_attuned' using errcode = '22023';
  end if;
  return new;
end;
$$;

create trigger item_effects_before_write before insert or update on public.item_effects
  for each row execute function public.item_effects_before_write();

-- ---- manual AC override (for AC sources the app does not model yet: Unarmored Defense, natural armor ...) ----
alter table public.characters add column ac_override int check (ac_override between 0 and 50);
comment on column public.characters.ac is 'Legacy manual AC. Not used for the active AC; see get_character_derived_stats().';
comment on column public.characters.ac_override is 'Explicit manual AC override. null = use the calculated AC.';

-- ---- RLS and grants -----------------------------------------------------------------------------------------
alter table public.proficiency_groups enable row level security;
alter table public.character_proficiencies enable row level security;
alter table public.item_effects enable row level security;

create policy "proficiency_groups_read" on public.proficiency_groups for select to anon, authenticated using (true);
create policy "character_proficiencies_read" on public.character_proficiencies for select to authenticated
  using (public.can_access_character(character_id));
create policy "item_effects_read" on public.item_effects for select to anon, authenticated using (public.can_view_item(item_id));

revoke all on public.proficiency_groups, public.character_proficiencies, public.item_effects from anon, authenticated;
grant select on public.proficiency_groups, public.item_effects to anon, authenticated;
grant select on public.character_proficiencies to authenticated;     -- writes: set_character_proficiency() only

-- ---- set_character_proficiency: the only client write path ---------------------------------------------------
create function public.set_character_proficiency(p_character uuid, p_group text default null, p_item text default null,
                                                 p_enabled boolean default true, p_notes text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_type text; v_id uuid; changed boolean;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if (p_group is null) = (p_item is null) then
    raise exception 'Choose either a proficiency group or one item' using errcode = '22023';
  end if;
  if p_group is not null then
    select proficiency_type into v_type from public.proficiency_groups where id = p_group;
    if v_type is null then raise exception 'Unknown proficiency group "%"', p_group using errcode = '22023'; end if;
  else
    if not public.can_view_item(p_item) then raise exception 'Unknown item "%"', p_item using errcode = '22023'; end if;
    v_type := public._proficiency_type_of_item(p_item);
    if v_type is null then raise exception 'Proficiency only applies to weapons, armor, shields and tools' using errcode = '22023'; end if;
  end if;
  if length(p_notes) > 500 then raise exception 'Notes are too long' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtext('proficiency:' || p_character::text));

  if p_enabled then
    if p_group is not null then
      insert into public.character_proficiencies (character_id, proficiency_type, group_id, notes)
      values (p_character, v_type, p_group, nullif(btrim(p_notes), ''))
      on conflict (character_id, group_id) where group_id is not null do nothing returning id into v_id;
    else
      insert into public.character_proficiencies (character_id, proficiency_type, item_id, notes)
      values (p_character, v_type, p_item, nullif(btrim(p_notes), ''))
      on conflict (character_id, item_id) where item_id is not null do nothing returning id into v_id;
    end if;
    changed := v_id is not null;
  else
    delete from public.character_proficiencies
    where character_id = p_character and (group_id = p_group or item_id = p_item);
    changed := found;
  end if;
  return jsonb_build_object('character_id', p_character, 'group_id', p_group, 'item_id', p_item,
                            'proficiency_type', v_type, 'enabled', p_enabled, 'changed', changed);
end;
$$;

-- ---- derived state ------------------------------------------------------------------------------------------
-- Every permanent effect of the character's own items, with its activation state and whether it is applied after
-- stacking. Instance modifiers (Armor +1 ...) work while the item is equipped (and attuned if the item or the
-- modifier requires attunement). Attack / damage bonuses of a weapon apply to that weapon only (scope 'self').
-- Stacking: additive = every effect counts; highest_only = the best of that type/target; non_stacking_group = the
-- best per stack_group; override = the highest override (ability scores only, never below the base score).
create function public._character_effects(p_character uuid)
returns table (source_type text, source_id uuid, item_id text, source_name text, modifier_id text, seq int,
               effect_type text, value numeric, target text, activation text, stacking text, stack_group text,
               scope text, active boolean, inactive_reason text, applied boolean)
language sql stable
set search_path = public, pg_temp
as $$
  with owned as (
    select ii.id, ii.item_id, ii.is_attuned, coalesce(ii.custom_name, it.name) as name, it.kind_id, it.requires_attunement, e.slot_id
    from public.inventories inv
    join public.inventory_items ii on ii.inventory_id = inv.id
    join public.items it on it.id = ii.item_id                       -- RLS: effects of invisible items do not exist
    left join public.character_equipment e on e.inventory_item_id = ii.id and e.character_id = p_character
    where inv.character_id = p_character
  ),
  worn as (
    select coalesce(bool_or(slot_id = 'armor'), false) as has_armor, coalesce(bool_or(slot_id = 'shield'), false) as has_shield
    from public.character_equipment where character_id = p_character
  ),
  raw as (
    select 'item_effect'::text as source_type, o.id as source_id, o.item_id, o.name as source_name, null::text as modifier_id, ie.seq,
           ie.effect_type, ie.value, ie.target, ie.activation, ie.stacking, ie.stack_group, ie.priority,
           case when ie.effect_type in ('attack_bonus', 'damage_bonus') and o.kind_id = 'weapon' then 'self' else 'global' end as scope,
           coalesce(
             case ie.activation
               when 'equipped' then case when o.slot_id is null then 'not_equipped' end
               when 'attuned' then case when not o.is_attuned then 'not_attuned' end
               when 'equipped_and_attuned' then case when o.slot_id is null then 'not_equipped' when not o.is_attuned then 'not_attuned' end
             end,
             case when ie.conditions ->> 'no_armor' = 'true' and w.has_armor then 'wearing_armor'
                  when ie.conditions ->> 'no_shield' = 'true' and w.has_shield then 'using_shield' end) as inactive_reason
    from owned o
    join public.item_effects ie on ie.item_id = o.item_id
    cross join worn w
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
$$;

-- Is the character proficient with this item? Specific item (or its base item) first, then the group.
create function public._proficiency_match(p_character uuid, p_item text, p_base_item text, p_group text)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select coalesce(
    (select jsonb_build_object('proficient', true, 'matched_by', 'item', 'proficiency_id', p.id, 'item_id', p.item_id,
                               'source_type', p.source_type)
     from public.character_proficiencies p
     where p.character_id = p_character and p.item_id is not null and p.item_id in (p_item, p_base_item) limit 1),
    (select jsonb_build_object('proficient', true, 'matched_by', 'group', 'proficiency_id', p.id, 'group_id', g.id,
                               'group_name', g.name, 'source_type', p.source_type)
     from public.character_proficiencies p join public.proficiency_groups g on g.id = p.group_id
     where p.character_id = p_character and p.group_id = p_group limit 1),
    jsonb_build_object('proficient', false, 'missing_group_id', p_group,
                       'missing_group_name', (select name from public.proficiency_groups where id = p_group)));
$$;

-- Sum of applied effects of one type (global scope unless p_source is given).
create function public._effect_total(p_effects jsonb, p_type text, p_target text default null, p_source uuid default null)
returns int
language sql immutable
set search_path = public, pg_temp
as $$
  select coalesce(sum((e ->> 'value')::numeric), 0)::int
  from jsonb_array_elements(p_effects) e
  where (e ->> 'applied')::boolean and e ->> 'effect_type' = p_type
    and (e ->> 'target') is not distinct from p_target
    and case when p_source is null then e ->> 'scope' = 'global' else e ->> 'scope' = 'self' and (e ->> 'source_id')::uuid = p_source end;
$$;

create function public._ability_mod(p_score int) returns int language sql immutable as $$ select floor((p_score - 10) / 2.0)::int $$;

create function public.get_character_derived_stats(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
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
begin
  select * into c from public.characters where id = p_character;                 -- RLS: owner, campaign DM, admin
  if not found then raise exception 'Character not found' using errcode = '42501'; end if;

  pb := (greatest(c.level, 1) - 1) / 4 + 2;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.effect_type, e.source_name, e.seq), '[]'::jsonb) into effects
  from public._character_effects(p_character) e;

  -- abilities: base score, highest active override (never lowers the score), plus additive bonuses (max 30)
  foreach k in array array['str', 'dex', 'con', 'int', 'wis', 'cha'] loop
    base_score := (to_jsonb(c) ->> (case k when 'str' then 'strength' when 'dex' then 'dexterity' when 'con' then 'constitution'
                                          when 'int' then 'intelligence' when 'wis' then 'wisdom' else 'charisma' end))::int;
    select max((e ->> 'value')::int) into override_score from jsonb_array_elements(effects) e
    where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'ability_override' and e ->> 'target' = k;
    bonus := public._effect_total(effects, 'ability_bonus', k);
    score := least(30, greatest(base_score, coalesce(override_score, 0)) + bonus);
    scores := scores || jsonb_build_object(k, score);
    mods := mods || jsonb_build_object(k, public._ability_mod(score));
    abilities := abilities || jsonb_build_object(k, jsonb_build_object('base', base_score, 'score', score,
      'modifier', public._ability_mod(score), 'override', override_score, 'bonus', bonus,
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
  if armor.inventory_item_id is not null and armor.base_ac is not null and not armor.is_shield then
    formula := case armor.dex_modifier_mode when 'full' then 'light_armor' when 'capped' then 'medium_armor' else 'heavy_armor' end;
    dex_part := case armor.dex_modifier_mode when 'full' then dex_mod when 'capped' then least(dex_mod, armor.dex_cap) else 0 end;
    ac_parts := ac_parts || jsonb_build_object('source_type', 'armor', 'source_id', armor.inventory_item_id, 'item_id', armor.item_id,
                  'source_name', armor.name, 'effect', 'base_ac', 'value', armor.base_ac);
    ac_parts := ac_parts || jsonb_build_object('source_type', 'ability', 'source_id', 'dex', 'source_name', 'Dexterity',
                  'effect', 'ability_modifier', 'value', dex_part, 'modifier', dex_mod, 'mode', armor.dex_modifier_mode,
                  'cap', armor.dex_cap, 'applied', armor.dex_modifier_mode <> 'none');
    alternatives := alternatives || jsonb_build_object('formula', 'unarmored', 'value', 10 + dex_mod, 'used', false,
                                                       'reason', 'armor_worn');
  else
    formula := 'unarmored';
    ac_parts := ac_parts || jsonb_build_object('source_type', 'rule', 'source_id', 'unarmored', 'source_name', 'Unarmored',
                  'effect', 'base_ac', 'value', 10);
    ac_parts := ac_parts || jsonb_build_object('source_type', 'ability', 'source_id', 'dex', 'source_name', 'Dexterity',
                  'effect', 'ability_modifier', 'value', dex_mod, 'modifier', dex_mod, 'mode', 'full', 'cap', null, 'applied', true);
    if armor.inventory_item_id is not null then
      warnings := warnings || jsonb_build_object('code', case when armor.visible then 'armor_stats_unknown' else 'hidden_item' end,
                    'severity', 'warning', 'source_type', 'armor', 'source_id', armor.inventory_item_id, 'item_id', armor.item_id,
                    'source_name', armor.name);
    end if;
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
                    'required', armor.strength_requirement, 'current', (scores ->> 'str')::int, 'speed_penalty', 10);
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
  speed_parts := jsonb_build_array(jsonb_build_object('source_type', 'base', 'source_id', 'speed', 'source_name', 'Base speed',
                                                      'effect', 'base', 'value', c.speed));
  if str_unmet then
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

  -- ---- saving throws and skills: only what equipment adds (proficiency is still calculated on the sheet) ---------
  foreach k in array array['str', 'dex', 'con', 'int', 'wis', 'cha'] loop
    saves := saves || jsonb_build_object(k, jsonb_build_object(
      'item_bonus', public._effect_total(effects, 'save_bonus', null) + public._effect_total(effects, 'save_bonus', k),
      'disadvantage', (nonprof_armor or nonprof_shield) and k in ('str', 'dex')));
  end loop;
  select coalesce(jsonb_object_agg(t.skill, t.v), '{}'::jsonb) into skills from (
    select s.skill, jsonb_build_object(
      'advantage', exists (select 1 from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean
                           and e ->> 'effect_type' = 'skill_advantage' and e ->> 'target' = s.skill),
      'disadvantage', (s.skill = 'stealth' and jsonb_array_length(stealth_sources) > 0)
                      or exists (select 1 from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean
                                 and e ->> 'effect_type' = 'skill_disadvantage' and e ->> 'target' = s.skill),
      'sources', case when s.skill = 'stealth' then stealth_sources else '[]'::jsonb end) as v
    from (select distinct e ->> 'target' as skill from jsonb_array_elements(effects) e
          where e ->> 'effect_type' in ('skill_advantage', 'skill_disadvantage') and (e ->> 'applied')::boolean
          union select 'stealth') s) t;

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

  return jsonb_build_object(
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
    'speed', jsonb_build_object('base', c.speed, 'value', speed_val, 'breakdown', speed_parts),
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
      'speed_penalty', case when str_unmet then 10 else 0 end),
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
                      where p.character_id = p_character),
    'other_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                      where e ->> 'effect_type' in ('resistance', 'carrying_capacity_bonus') or e ->> 'effect_type' is null),
    'effects', effects,
    'warnings', warnings);
end;
$$;

-- ---- function privileges ------------------------------------------------------------------------------------
revoke all on function public._proficiency_type_of_item(text), public.character_proficiencies_before_write(),
  public._equipment_proficiency_flags(uuid), public.character_proficiencies_sync_flags(), public.characters_sync_proficiency_rows(),
  public.item_effects_before_write() from public, anon, authenticated;
revoke all on function public.set_character_proficiency(uuid, text, text, boolean, text), public.get_character_derived_stats(uuid),
  public._character_effects(uuid), public._proficiency_match(uuid, text, text, text), public._effect_total(jsonb, text, text, uuid),
  public._ability_mod(int) from public, anon;
grant execute on function public.set_character_proficiency(uuid, text, text, boolean, text), public.get_character_derived_stats(uuid),
  public._character_effects(uuid), public._proficiency_match(uuid, text, text, text), public._effect_total(jsonb, text, text, uuid),
  public._ability_mod(int) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.character_proficiencies;
  end if;
end $$;
