-- =============================================================================
-- Wild Shape gameplay engine (2014 Druid and Circle of the Moon; docs/TRANSFORMATION_ENGINE.md, docs/WILD_SHAPE_RULES.md).
--   * creatures: mechanics_status / mechanics_notes (complete structured mechanics come from creatures.sql)
--   * character_transformations: form temporary HP, normal-HP snapshot, duration and expiry, elemental flag, equipment
--     modes (merge / drop / wear per item), per-form ability state (recharge, once per rest), seen status, notes
--   * character_wild_shape_settings (seen mode enforce / warn / unrestricted, default equipment, lethal confirmation),
--     character_seen_forms (seen, DM grant), character_form_favorites, character_transformation_events (history)
--   * eligibility: _form_options returns every reason (CR, fly, swim, seen) by Druid class level; DM grants override
--   * stats: physical scores from the form in _derived_stats_core; equipment of a form only when worn (_character_effects);
--     _wild_shape_layer on the derived stats (form AC with alternatives, speed, senses, saves / skills with the higher of your
--     proficiency and the form's, resistances); _wild_shape_sheet is the authoritative transformed sheet
--   * RPCs: get_character_transformation, start_transformation, damage / heal_active_transformation, set_transformation_hp,
--     end_transformation, combat_wild_shape_heal, use_form_ability, set_seen_forms, set_form_favorite,
--     set_wild_shape_settings, set_transformation_equipment (and change_transformation_hp for the earlier API)
-- =============================================================================

drop function public.start_transformation(uuid, text);
drop function public.end_transformation(uuid);
drop function public.change_transformation_hp(uuid, int);
drop function public.get_character_transformation(uuid);

-- =============================================================================
-- Schema
-- =============================================================================
alter table public.creatures add column mechanics_status text not null default 'partial'
  check (mechanics_status in ('complete', 'partial', 'informational'));
alter table public.creatures add column mechanics_notes text;

alter table public.character_transformations
  add column hp_temp int not null default 0 check (hp_temp >= 0),
  add column normal_hp_current int,                           -- snapshot at the start (the character row stays authoritative)
  add column normal_hp_temp int,
  add column max_duration_minutes int check (max_duration_minutes > 0),
  add column expires_at timestamptz,
  add column elemental boolean not null default false,
  add column equipment jsonb not null default '{"mode": "merge", "items": {}}'::jsonb check (jsonb_typeof(equipment) = 'object'),
  add column action_state jsonb not null default '{}'::jsonb check (jsonb_typeof(action_state) = 'object'),
  add column seen_status text,                                -- seen | dm_grant | unseen_warned | unrestricted (at the start)
  add column notes text check (length(notes) <= 2000);

create table public.character_wild_shape_settings (
  character_id      uuid primary key references public.characters (id) on delete cascade,
  seen_mode         text not null default 'warn' check (seen_mode in ('enforce', 'warn', 'unrestricted')),
  default_equipment text not null default 'merge' check (default_equipment in ('merge', 'drop', 'wear')),
  confirm_lethal    boolean not null default true,
  updated_at        timestamptz not null default now(),
  updated_by        uuid
);

create table public.character_seen_forms (
  character_id uuid not null references public.characters (id) on delete cascade,
  creature_id  text not null references public.creatures (id) on delete cascade,
  source       text not null default 'seen' check (source in ('seen', 'dm_grant', 'fixture', 'import')),
  note         text check (length(note) <= 300),
  created_at   timestamptz not null default now(),
  created_by   uuid,
  primary key (character_id, creature_id)
);

create table public.character_form_favorites (
  character_id uuid not null references public.characters (id) on delete cascade,
  creature_id  text not null references public.creatures (id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (character_id, creature_id)
);

create table public.character_transformation_events (
  id           uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters (id) on delete cascade,
  actor        uuid,
  event_type   text not null check (event_type in ('transformed', 'damaged', 'healed', 'combat_healing', 'temp_hp', 'manual_set',
                 'ability_used', 'ability_recharged', 'equipment', 'reverted_manual', 'reverted_zero_hp', 'reverted_expired',
                 'excess_damage', 'seen_added', 'seen_removed', 'settings')),
  creature_id  text,
  before       jsonb,
  after        jsonb,
  metadata     jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);
create index character_transformation_events_character on public.character_transformation_events (character_id, created_at desc);

do $$
declare t text;
begin
  foreach t in array array['character_wild_shape_settings', 'character_seen_forms', 'character_form_favorites',
                           'character_transformation_events'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.can_access_character(character_id))', t || '_read', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.character_transformations;
  end if;
exception when duplicate_object then null;
end $$;

-- =============================================================================
-- Helpers
-- =============================================================================

-- the active form of a character (null when not transformed)
create function public._active_form(p_character uuid)
returns table (creature_id text, abilities jsonb, name text, equipment jsonb)
language sql stable
set search_path = public, pg_temp
as $$
  select t.creature_id, c.abilities, c.name, t.equipment
  from public.character_transformations t join public.creatures c on c.id = t.creature_id
  where t.character_id = p_character;
$$;

-- whether an owned item keeps working: always when not transformed; in a form only when worn by it
create function public._item_active_in_form(p_character uuid, p_item uuid)
returns boolean
language sql stable
set search_path = public, pg_temp
as $$
  select coalesce((select coalesce(t.equipment -> 'items' ->> p_item::text, t.equipment ->> 'mode') = 'wear'
                   from public.character_transformations t where t.character_id = p_character), true);
$$;

create function public._wild_shape_event(p_character uuid, p_type text, p_creature text, p_before jsonb, p_after jsonb,
                                         p_meta jsonb default '{}'::jsonb)
returns void
language sql
set search_path = public, pg_temp
as $$
  insert into public.character_transformation_events (character_id, actor, event_type, creature_id, before, after, metadata)
  values (p_character, auth.uid(), p_type, p_creature, p_before, p_after, coalesce(p_meta, '{}'));
$$;

create function public._wild_shape_settings(p_character uuid)
returns public.character_wild_shape_settings
language sql stable
set search_path = public, pg_temp
as $$
  select coalesce((select s from public.character_wild_shape_settings s where s.character_id = p_character),
                  row(p_character, 'warn', 'merge', true, now(), null)::public.character_wild_shape_settings);
$$;

-- may the current user decide as the DM for this character (campaign DM or admin; a character outside a campaign: its owner)
create function public._acts_as_dm(p_character uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public.is_admin() or exists (select 1 from public.characters c where c.id = p_character
           and ((c.campaign_id is not null and public.is_campaign_dm(c.campaign_id)) or (c.campaign_id is null and c.owner_id = auth.uid())));
$$;

create function public._cr_text(p numeric)
returns text
language sql immutable
set search_path = public, pg_temp
as $$
  select case p when 0.125 then '1/8' when 0.25 then '1/4' when 0.5 then '1/2' else coalesce(trim(trailing '.' from trim(trailing '0' from p::text)), '—') end;
$$;

-- every form a character's Wild Shape rules know, with all reasons it is refused, the seen state and the cost
create function public._form_options(p_character uuid)
returns table (creature_id text, rule_resource text, character_class_id uuid, class_level int, cost int, elemental boolean,
               max_cr numeric, type_ok boolean, cr_ok boolean, fly_ok boolean, swim_ok boolean, mechanical boolean,
               seen text, allowed boolean, status text, reasons text[], duration_minutes int)
language sql stable
set search_path = public, pg_temp
as $$
  with rules as (
    select tr.*, (tr.rule ->> 'cost')::int as rcost,
           (select (e ->> 1)::numeric from jsonb_array_elements(tr.rule -> 'max_cr_by_level') e
            where (e ->> 0)::int <= tr.class_level order by (e ->> 0)::int desc limit 1) as rmax,
           tr.rule ? 'creature_ids' as relemental
    from public._character_transform_rules(p_character) tr),
  pairs as (
    select c.id, c.challenge_rating, c.speed, r.*,
           coalesce(r.rule -> 'creature_types' ? c.creature_type, false) or coalesce(r.rule -> 'creature_ids' ? c.id, false) as t_ok,
           not (r.rule ? 'max_cr_by_level') or c.challenge_rating <= coalesce(r.rmax, -1) as c_ok,
           coalesce((c.speed ->> 'fly')::int, 0) = 0 or r.class_level >= coalesce((r.rule ->> 'no_fly_below')::int, 0) as f_ok,
           coalesce((c.speed ->> 'swim')::int, 0) = 0 or r.class_level >= coalesce((r.rule ->> 'no_swim_below')::int, 0) as s_ok
    from public.creatures c join rules r
      on coalesce(r.rule -> 'creature_types' ? c.creature_type, false) or coalesce(r.rule -> 'creature_ids' ? c.id, false)
    where c.content_scope = 'official' or c.content_scope = 'test'),
  best as (   -- per creature: the allowed rule with the lowest cost, else the closest refusal (fewest reasons)
    select distinct on (p.id) p.*, (p.t_ok and p.c_ok and p.f_ok and p.s_ok) as mech
    from pairs p
    order by p.id, (p.t_ok and p.c_ok and p.f_ok and p.s_ok) desc, p.rcost,
             (not p.c_ok)::int + (not p.f_ok)::int + (not p.s_ok)::int),
  st as (select public._wild_shape_settings(p_character) as s)
  select b.id, b.resource_key, b.character_class_id, b.class_level, b.rcost, b.relemental, b.rmax, b.t_ok, b.c_ok, b.f_ok, b.s_ok, b.mech,
         sf.source,
         (b.mech and (sf.source is not null or (st.s).seen_mode <> 'enforce')) or coalesce(sf.source = 'dm_grant', false),
         case when sf.source = 'dm_grant' and not b.mech then 'dm_granted'
              when not b.mech then 'ineligible'
              when sf.source is not null then 'eligible_seen'
              when (st.s).seen_mode = 'unrestricted' then 'eligible_unrestricted'
              when (st.s).seen_mode = 'warn' then 'eligible_unseen'
              else 'unseen_locked' end,
         array_remove(array[
           case when not b.c_ok then format('challenge rating %s is above your maximum %s (Druid level %s)',
                                            public._cr_text(b.challenge_rating), public._cr_text(b.rmax), b.class_level) end,
           case when not b.f_ok then format('flying forms need Druid level %s', b.rule ->> 'no_fly_below') end,
           case when not b.s_ok then format('swimming forms need Druid level %s', b.rule ->> 'no_swim_below') end,
           case when b.mech and sf.source is null and (st.s).seen_mode = 'enforce' then 'you have not seen this beast (mark it as seen)' end], null),
         case when b.rule ? 'duration_hours' then greatest(1, b.class_level / 2) * 60 end
  from best b cross join st
  left join public.character_seen_forms sf on sf.character_id = p_character and sf.creature_id = b.id;
$$;



-- =============================================================================
-- The transformed sheet: authoritative values while in a form
-- =============================================================================
create function public._wild_shape_sheet(p_character uuid, d jsonb)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare t public.character_transformations; c public.creatures; ch public.characters; pb int; k text; ab text; mods jsonb := '{}';
  saves jsonb := '{}'; skills jsonb := '{}'; lvl int; char_total int; cand jsonb; best jsonb; pub int; m int; druid int;
  ac_opts jsonb := '[]'; e record; eq jsonb := '[]'; dur jsonb; spell jsonb; sz jsonb; retained jsonb := '[]'; acts jsonb;
  sens jsonb; conc jsonb; half int;
begin
  select * into t from public.character_transformations where character_id = p_character;
  if not found then return null; end if;
  select * into c from public.creatures where id = t.creature_id;
  select * into ch from public.characters where id = p_character;
  pb := coalesce((d -> 'proficiency_bonus' ->> 'value')::int, 2);
  select max(cc.level) into druid from public.character_classes cc where cc.character_id = p_character and cc.class_id = 'druid';

  -- abilities: STR, DEX, CON from the form; INT, WIS, CHA retained (the derived core already substituted the physical ones)
  for k in select unnest(array['str', 'dex', 'con', 'int', 'wis', 'cha']) loop
    m := floor(((case when k in ('str', 'dex', 'con') then (c.abilities ->> k)::int else (d -> 'abilities' -> k ->> 'score')::int end) - 10) / 2.0);
    mods := mods || jsonb_build_object(k, m);
  end loop;

  -- saving throws: your proficiency (your PB) or the form's; the form's printed bonus when it is higher
  for k in select unnest(array['str', 'dex', 'con', 'int', 'wis', 'cha']) loop
    m := (mods ->> k)::int;
    cand := '[]';
    if coalesce((ch.save_proficiencies ->> k)::boolean, false) or coalesce((d -> 'saving_throws' -> k ->> 'class_proficient')::boolean, false) then
      cand := cand || jsonb_build_object('kind', 'character', 'value', m + pb, 'label', format('your proficiency: %s + PB %s', m, pb));
    end if;
    if c.saving_throws ? k then
      pub := (c.saving_throws ->> k)::int;
      cand := cand || jsonb_build_object('kind', 'form_gained', 'value', m + pb, 'label', format('%s proficiency (gained): %s + PB %s', c.name, m, pb))
                   || jsonb_build_object('kind', 'form_printed', 'value', pub, 'label', format('%s stat block: %s', c.name, pub));
    end if;
    select x into best from jsonb_array_elements(cand) x order by (x ->> 'value')::int desc limit 1;
    saves := saves || jsonb_build_object(k, jsonb_build_object('ability', k, 'score', case when k in ('str', 'dex', 'con') then (c.abilities ->> k)::int
                                                                                     else (d -> 'abilities' -> k ->> 'score')::int end,
      'modifier', m, 'character_proficient', exists (select 1 from jsonb_array_elements(cand) x where x ->> 'kind' = 'character'),
      'creature_proficient', c.saving_throws ? k, 'creature_printed', c.saving_throws -> k, 'proficiency_bonus', pb,
      'other_bonus', coalesce((d -> 'saving_throws' -> k ->> 'class_bonus')::int, 0) + coalesce((d -> 'saving_throws' -> k ->> 'item_bonus')::int, 0),
      'total', coalesce((best ->> 'value')::int, m) + coalesce((d -> 'saving_throws' -> k ->> 'class_bonus')::int, 0)
               + coalesce((d -> 'saving_throws' -> k ->> 'item_bonus')::int, 0),
      'chosen', coalesce(best ->> 'kind', 'ability'), 'candidates', cand));
    best := null;
  end loop;

  -- skills: your proficiency / expertise (your PB) or the form's; its printed bonus when higher; half proficiency only without one
  for e in select s.id, s.ability from public.skills s loop
    m := (mods ->> e.ability)::int;
    lvl := greatest(public._skill_level(ch.skill_proficiencies -> e.id),
                    case when coalesce((d -> 'skills' -> e.id ->> 'class_expertise')::boolean, false) then 2
                         when coalesce((d -> 'skills' -> e.id ->> 'class_proficient')::boolean, false)
                           or coalesce((d -> 'skills' -> e.id ->> 'lineage_proficient')::boolean, false)
                           or coalesce((d -> 'skills' -> e.id ->> 'background_proficient')::boolean, false) then 1 else 0 end);
    cand := '[]';
    if lvl > 0 then
      cand := cand || jsonb_build_object('kind', 'character', 'value', m + lvl * pb,
        'label', format('your %s: %s + %s', case when lvl = 2 then 'expertise' else 'proficiency' end, m, lvl * pb));
    end if;
    if c.skills ? e.id then
      pub := (c.skills ->> e.id)::int;
      cand := cand || jsonb_build_object('kind', 'form_gained', 'value', m + pb, 'label', format('%s proficiency (gained): %s + PB %s', c.name, m, pb))
                   || jsonb_build_object('kind', 'form_printed', 'value', pub, 'label', format('%s stat block: %s', c.name, pub));
    end if;
    half := case when lvl = 0 and not c.skills ? e.id then coalesce((d -> 'skills' -> e.id -> 'half_proficiency' ->> 'value')::int, 0) else 0 end;
    select x into best from jsonb_array_elements(cand) x order by (x ->> 'value')::int desc limit 1;
    skills := skills || jsonb_build_object(e.id, jsonb_build_object('ability', e.ability, 'modifier', m, 'character_level', lvl,
      'creature_proficient', c.skills ? e.id, 'creature_printed', c.skills -> e.id, 'half_proficiency', half,
      'total', coalesce((best ->> 'value')::int, m + half), 'chosen', coalesce(best ->> 'kind', 'ability'), 'candidates', cand,
      'advantage_traits', (select coalesce(jsonb_agg(tr ->> 'name'), '[]') from jsonb_array_elements(c.traits) tr
                           where e.id = 'perception' and tr ->> 'name' like 'Keen%'
                              or e.id = 'stealth' and tr ->> 'name' = 'Underwater Camouflage')));
    best := null;
  end loop;

  -- armor class: the form's natural AC; Unarmored-Defense-style class formulas with the form's modifiers; worn armor / shield
  -- only when the player set them to "worn by the form" (DM confirmation)
  ac_opts := jsonb_build_array(jsonb_build_object('kind', 'form', 'value', c.armor_class,
    'label', format('%s %s', c.name, coalesce(c.armor_type, 'natural armor')), 'parts', jsonb_build_array(jsonb_build_object('label', c.name, 'value', c.armor_class))));
  for e in select x.feature_name, x.value, x.data, x.conditions from public._character_class_effects(p_character) x
           where x.active and x.effect_type = 'ac_formula' loop
    ac_opts := ac_opts || jsonb_build_object('kind', 'class_formula', 'value', e.value::int
        + (select coalesce(sum((mods ->> a)::int), 0) from jsonb_array_elements_text(e.data -> 'abilities') a),
      'label', format('%s: %s + %s', e.feature_name, e.value::int,
                      (select string_agg(upper(a), ' + ') from jsonb_array_elements_text(e.data -> 'abilities') a)),
      'note', 'retained class feature (your form must be able to use it)');
  end loop;
  for e in select ii.id, ii.item_id, coalesce(ii.custom_name, it.name) as name, ce.slot_id, st.base_ac, st.ac_bonus, st.dex_modifier_mode, st.dex_cap, st.is_shield
           from public.character_equipment ce join public.inventory_items ii on ii.id = ce.inventory_item_id
           join public.items it on it.id = ii.item_id
           left join public.armor_stats st on st.item_id in (it.id, it.base_item_id)
           where ce.character_id = p_character and ce.slot_id in ('armor', 'shield') and public._item_active_in_form(p_character, ii.id) loop
    if e.slot_id = 'armor' and e.base_ac is not null then
      ac_opts := ac_opts || jsonb_build_object('kind', 'worn_armor', 'value', e.base_ac + case e.dex_modifier_mode when 'full' then (mods ->> 'dex')::int
                                                                                          when 'capped' then least((mods ->> 'dex')::int, coalesce(e.dex_cap, 2)) else 0 end,
        'label', format('%s worn by the form (DM confirmed)', e.name), 'note', 'equipment does not resize to fit the form');
    end if;
  end loop;
  select x into best from jsonb_array_elements(ac_opts) x order by (x ->> 'value')::int desc limit 1;
  if exists (select 1 from public.character_equipment ce where ce.character_id = p_character and ce.slot_id = 'shield'
             and public._item_active_in_form(p_character, ce.inventory_item_id)) then
    best := best || jsonb_build_object('value', (best ->> 'value')::int + 2, 'shield', 2);
  end if;

  -- actions with the per-form ability state (recharge rolls, once per rest abilities)
  select coalesce(jsonb_agg(a || jsonb_build_object('available', coalesce((t.action_state -> (a ->> 'name') ->> 'available')::boolean, true))), '[]')
  into acts from jsonb_array_elements(c.actions || c.reactions) a;

  -- senses: only the form's (your darkvision does not carry over unless the form has it)
  sens := (select coalesce(jsonb_object_agg(key, value), '{}') from jsonb_each(c.senses) where key <> 'passive_perception')
          || jsonb_build_object('passive_perception', 10 + (skills -> 'perception' ->> 'total')::int);

  -- equipment while transformed
  select coalesce(jsonb_agg(jsonb_build_object('inventory_item_id', ii.id, 'name', coalesce(ii.custom_name, it.name), 'slot', ce.slot_id,
           'mode', coalesce(t.equipment -> 'items' ->> ii.id::text, t.equipment ->> 'mode'),
           'effects_active', public._item_active_in_form(p_character, ii.id)) order by ce.slot_id), '[]')
  into eq
  from public.character_equipment ce join public.inventory_items ii on ii.id = ce.inventory_item_id join public.items it on it.id = ii.item_id
  where ce.character_id = p_character;
  eq := eq || coalesce((select jsonb_agg(jsonb_build_object('inventory_item_id', x.key, 'mode', 'drop', 'dropped', true,
                                 'name', (select coalesce(ii.custom_name, it.name) from public.inventory_items ii join public.items it on it.id = ii.item_id
                                          where ii.id = x.key::uuid)))
                        from jsonb_each_text(coalesce(t.equipment -> 'dropped', '{}')) x), '[]');

  -- retained features: what the form keeps, applies automatically, or needs your DM to confirm
  select coalesce(jsonb_agg(distinct jsonb_build_object('feature', x.feature_name, 'class', x.class_name,
           'status', case when x.effect_type in ('proficiency', 'expertise', 'skill_half_proficiency', 'save_bonus_ability', 'save_dc', 'spell',
                                                  'spellcasting_source', 'resistance', 'immunity', 'condition_immunity', 'save_advantage', 'check_advantage')
                          then 'retained' when x.effect_type = 'ac_formula' then 'retained_if_capable'
                          when x.effect_type = 'sense' then 'not_retained'
                          when x.effect_type in ('attack', 'extra_attack', 'attack_bonus', 'damage_bonus', 'attack_rider', 'critical_range', 'speed_bonus',
                                                 'ac_bonus') then 'needs_dm' else 'informational' end,
           'applied', x.effect_type in ('proficiency', 'expertise', 'skill_half_proficiency', 'save_bonus_ability', 'resistance', 'immunity',
                                        'condition_immunity', 'ac_formula'))), '[]')
  into retained
  from public._character_class_effects(p_character) x
  where x.active and x.feature_active and x.effect_type not in ('transform_form', 'informational', 'resource_modifier');

  -- spellcasting while transformed (2014 Druid): no spells before Beast Spells (18); Archdruid (20) ignores V, S and costless M
  spell := case when coalesce(druid, 0) >= 20 then jsonb_build_object('can_cast', true, 'feature', 'Archdruid',
                  'rule', 'Beast Spells: verbal and somatic components in this form. Archdruid: ignore verbal and somatic components and material components without a cost or that are not consumed, for druid spells.')
                when coalesce(druid, 0) >= 18 then jsonb_build_object('can_cast', true, 'feature', 'Beast Spells',
                  'rule', 'You can perform the verbal and somatic components of a druid spell in this form, but not provide material components.')
                else jsonb_build_object('can_cast', false, 'feature', null,
                  'rule', 'You cannot cast spells in Wild Shape. Concentration on a spell you already cast continues.') end;
  conc := jsonb_build_object('active', exists (select 1 from jsonb_array_elements(coalesce(ch.conditions, '[]')) x
                                               where coalesce(x ->> 'name', x #>> '{}') ilike 'concentrat%'),
                             'note', (select coalesce(x ->> 'note', x ->> 'detail') from jsonb_array_elements(coalesce(ch.conditions, '[]')) x
                                      where coalesce(x ->> 'name', x #>> '{}') ilike 'concentrat%' limit 1),
                             'reminder', 'Taking damage: CON save DC 10 or half the damage (whichever is higher) or the spell ends.');
  sz := jsonb_build_object('size', c.size, 'space_ft', case c.size when 'Tiny' then 2.5 when 'Small' then 5 when 'Medium' then 5 when 'Large' then 10
                                                                  when 'Huge' then 15 else 20 end,
    'notes', case when c.size in ('Large', 'Huge', 'Gargantuan') then 'Large or bigger: squeeze through spaces one size smaller; carrying capacity scales with size. A mount only if your DM agrees.'
                  when c.size = 'Tiny' then 'Tiny: fits in a 2.5 ft. space; carrying capacity is halved.' else null end);
  dur := jsonb_build_object('started_at', t.started_at, 'max_minutes', t.max_duration_minutes, 'expires_at', t.expires_at,
    'expired', t.expires_at is not null and t.expires_at <= now(),
    'remaining_minutes', case when t.expires_at is not null then greatest(0, floor(extract(epoch from (t.expires_at - now())) / 60))::int end);

  return jsonb_build_object(
    'creature', jsonb_build_object('id', c.id, 'name', c.name, 'cr', c.challenge_rating, 'cr_text', public._cr_text(c.challenge_rating),
      'type', c.creature_type, 'size', c.size, 'hit_dice', c.hit_dice, 'source', c.source_label, 'source_url', c.source_url, 'license', c.license,
      'elemental', t.elemental, 'mechanics_status', c.mechanics_status, 'languages', c.languages),
    'hp', jsonb_build_object('current', t.hp_current, 'max', t.hp_max, 'temp', t.hp_temp, 'normal_current', ch.hp_current, 'normal_max', ch.hp_max,
      'normal_temp', ch.hp_temp, 'state', case when t.hp_current * 4 <= t.hp_max then 'critical' when t.hp_current * 2 <= t.hp_max then 'wounded' else 'healthy' end),
    'duration', dur, 'cost', t.cost, 'resource_key', t.resource_key, 'started_at', t.started_at,
    'abilities', (select jsonb_object_agg(k2, jsonb_build_object('score', case when k2 in ('str', 'dex', 'con') then (c.abilities ->> k2)::int
                                                                              else (d -> 'abilities' -> k2 ->> 'score')::int end,
                     'modifier', (mods ->> k2)::int,
                     'source', case when k2 in ('str', 'dex', 'con') then 'form' else 'retained' end,
                     'source_name', case when k2 in ('str', 'dex', 'con') then c.name else ch.name end))
                  from unnest(array['str', 'dex', 'con', 'int', 'wis', 'cha']) k2),
    'saving_throws', saves, 'skills', skills,
    'armor_class', jsonb_build_object('value', (best ->> 'value')::int, 'selected', best, 'options', ac_opts),
    'speed', c.speed, 'senses', sens, 'size', sz,
    'resistances', to_jsonb(c.damage_resistances), 'immunities', to_jsonb(c.damage_immunities), 'vulnerabilities', to_jsonb(c.damage_vulnerabilities),
    'condition_immunities', to_jsonb(c.condition_immunities),
    'actions', acts,
    'traits', c.traits, 'retained_features', retained, 'equipment', eq, 'spellcasting', spell, 'concentration', conc,
    'primal_strike', exists (select 1 from public.character_classes cc where cc.character_id = p_character and cc.class_id = 'druid'
                             and cc.subclass_version_id = 'druid-moon-phb' and cc.level >= 6),
    'notes', t.notes);
end;
$$;

-- the derived stats while transformed: the form's AC, speed, senses, resistances; saves and skills carry form totals
create function public._wild_shape_layer(p_character uuid, d jsonb)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare ws jsonb; k text; saves jsonb; skills jsonb;
begin
  if not exists (select 1 from public.character_transformations where character_id = p_character) then
    return d || jsonb_build_object('wild_shape', null);
  end if;
  ws := public._wild_shape_sheet(p_character, d);
  saves := coalesce(d -> 'saving_throws', '{}');
  for k in select jsonb_object_keys(ws -> 'saving_throws') loop
    saves := saves || jsonb_build_object(k, coalesce(saves -> k, '{}') || jsonb_build_object('form_total', ws -> 'saving_throws' -> k -> 'total'));
  end loop;
  skills := coalesce(d -> 'skills', '{}');
  for k in select jsonb_object_keys(ws -> 'skills') loop
    skills := skills || jsonb_build_object(k, coalesce(skills -> k, '{}') || jsonb_build_object('form_total', ws -> 'skills' -> k -> 'total'));
  end loop;
  return d || jsonb_build_object(
    'wild_shape', ws,
    'armor_class', coalesce(d -> 'armor_class', '{}') || jsonb_build_object('value', ws -> 'armor_class' -> 'value', 'base_formula', 'wild_shape',
       'breakdown', jsonb_build_array(ws -> 'armor_class' -> 'selected'), 'alternatives', ws -> 'armor_class' -> 'options'),
    'speed', coalesce(d -> 'speed', '{}') || jsonb_build_object('value', coalesce((ws -> 'speed' ->> 'walk')::int, 0), 'base', coalesce((ws -> 'speed' ->> 'walk')::int, 0),
       'movement', (select coalesce(jsonb_object_agg(key, jsonb_build_object('value', value, 'active', true)), '{}') from jsonb_each(ws -> 'speed')
                    where jsonb_typeof(value) = 'number'),
       'breakdown', jsonb_build_array(jsonb_build_object('source_type', 'wild_shape', 'source_name', ws -> 'creature' ->> 'name', 'value', ws -> 'speed' -> 'walk'))),
    'senses', (select coalesce(jsonb_object_agg(key, jsonb_build_object('value', value, 'source_name', ws -> 'creature' ->> 'name')), '{}')
               from jsonb_each(ws -> 'senses') where key <> 'passive_perception'),
    'saving_throws', saves, 'skills', skills,
    'equipped_weapon_attacks', (select coalesce(jsonb_agg(w), '[]') from jsonb_array_elements(coalesce(d -> 'equipped_weapon_attacks', '[]')) w
                                where public._item_active_in_form(p_character, (w ->> 'inventory_item_id')::uuid)),
    'resistances', coalesce(d -> 'resistances', '[]') || coalesce((select jsonb_agg(jsonb_build_object('damage_type', x, 'sources', jsonb_build_array(ws -> 'creature' ->> 'name')))
                                                                    from jsonb_array_elements_text(ws -> 'resistances') x), '[]'));
end;
$$;

-- =============================================================================
-- Read model
-- =============================================================================
create function public.get_character_transformation(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare res jsonb; act jsonb; d jsonb; st public.character_wild_shape_settings; druid record;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  res := coalesce(public.get_character_resources(p_character) -> 'resources', '[]');
  st := public._wild_shape_settings(p_character);
  select cc.level, cc.subclass_version_id into druid from public.character_classes cc where cc.character_id = p_character and cc.class_id = 'druid';
  if exists (select 1 from public.character_transformations where character_id = p_character) then
    d := public.get_character_derived_stats(p_character);
    select jsonb_build_object('creature_id', t.creature_id, 'name', c.name, 'hp_current', t.hp_current, 'hp_max', t.hp_max, 'hp_temp', t.hp_temp,
             'resource_key', t.resource_key, 'cost', t.cost, 'started_at', t.started_at, 'expires_at', t.expires_at, 'elemental', t.elemental,
             'equipment', t.equipment, 'creature', to_jsonb(c), 'sheet', d -> 'wild_shape')
    into act from public.character_transformations t join public.creatures c on c.id = t.creature_id where t.character_id = p_character;
  end if;
  return jsonb_build_object('character_id', p_character, 'active', act,
    'druid_level', druid.level, 'moon', druid.subclass_version_id = 'druid-moon-phb', 'total_level', (select level from public.characters where id = p_character),
    'settings', jsonb_build_object('seen_mode', st.seen_mode, 'default_equipment', st.default_equipment, 'confirm_lethal', st.confirm_lethal,
                                   'can_change_mode', public._acts_as_dm(p_character)),
    'resources', coalesce((select jsonb_agg(distinct r) from public._character_transform_rules(p_character) tr
                            join jsonb_array_elements(res) r on r ->> 'key' = tr.resource_key), '[]'),
    'rules', coalesce((select jsonb_agg(jsonb_build_object('resource_key', tr.resource_key, 'feature_name', tr.feature_name,
                         'class_level', tr.class_level, 'cost', (tr.rule ->> 'cost')::int,
                         'max_cr', (select (e ->> 1)::numeric from jsonb_array_elements(tr.rule -> 'max_cr_by_level') e
                                    where (e ->> 0)::int <= tr.class_level order by (e ->> 0)::int desc limit 1),
                         'swim_from', (tr.rule ->> 'no_swim_below')::int, 'fly_from', (tr.rule ->> 'no_fly_below')::int,
                         'creature_types', tr.rule -> 'creature_types', 'creature_ids', tr.rule -> 'creature_ids'))
                       from public._character_transform_rules(p_character) tr), '[]'),
    'options', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'size', c.size, 'creature_type', c.creature_type,
               'challenge_rating', c.challenge_rating, 'cr_text', public._cr_text(c.challenge_rating), 'armor_class', c.armor_class,
               'hit_points', c.hit_points, 'speed', c.speed, 'senses', c.senses, 'mechanics_status', c.mechanics_status,
               'attacks', (select coalesce(jsonb_agg(jsonb_build_object('name', a ->> 'name', 'bonus', a -> 'attack_bonus', 'damage', a -> 'damage',
                                                                         'save', a -> 'save', 'multiattack', a -> 'multiattack')), '[]')
                           from jsonb_array_elements(c.actions) a),
               'traits', (select coalesce(jsonb_agg(jsonb_build_object('name', tr ->> 'name', 'group', tr ->> 'group')), '[]') from jsonb_array_elements(c.traits) tr),
               'damage_types', (select coalesce(jsonb_agg(distinct dm ->> 'type'), '[]') from jsonb_array_elements(c.actions) a, jsonb_array_elements(coalesce(a -> 'damage', '[]')) dm),
               'source', c.source_label,
               'allowed', o.allowed, 'status', o.status, 'reasons', to_jsonb(o.reasons),
               'reason', case when not o.cr_ok then 'challenge_rating' when not o.fly_ok then 'flying_speed' when not o.swim_ok then 'swimming_speed'
                              when o.status = 'unseen_locked' then 'unseen' end, 'seen', o.seen, 'cost', o.cost, 'elemental', o.elemental,
               'max_cr', o.max_cr, 'class_level', o.class_level, 'duration_minutes', o.duration_minutes,
               'favorite', exists (select 1 from public.character_form_favorites f where f.character_id = p_character and f.creature_id = c.id),
               'last_used', (select max(ev.created_at) from public.character_transformation_events ev
                             where ev.character_id = p_character and ev.creature_id = c.id and ev.event_type = 'transformed'))
             order by o.elemental, c.challenge_rating, c.name)
      from public._form_options(p_character) o join public.creatures c on c.id = o.creature_id), '[]'),
    'events', coalesce((select jsonb_agg(jsonb_build_object('type', ev.event_type, 'creature_id', ev.creature_id, 'at', ev.created_at,
                          'before', ev.before, 'after', ev.after, 'metadata', ev.metadata) order by ev.created_at desc)
                        from (select * from public.character_transformation_events ev where ev.character_id = p_character
                              order by created_at desc limit 12) ev), '[]'));
end;
$$;

-- =============================================================================
-- Mutations (owner, campaign DM or admin; one character row lock serializes them)
-- =============================================================================

-- end the form when its duration is over (any mutation calls it first; the read model flags it)
create function public._end_expired_form(p_character uuid)
returns boolean
language plpgsql
set search_path = public, pg_temp
as $$
declare t public.character_transformations;
begin
  select * into t from public.character_transformations where character_id = p_character and expires_at is not null and expires_at <= now();
  if not found then return false; end if;
  delete from public.character_transformations where character_id = p_character;
  perform public._wild_shape_event(p_character, 'reverted_expired', t.creature_id, jsonb_build_object('hp', t.hp_current), null,
                                   jsonb_build_object('expires_at', t.expires_at));
  return true;
end;
$$;

-- returns true when the form had expired and was ended now (the caller then returns the new state instead of failing,
-- so the expiry is kept)
create function public._lock_for_wild_shape(p_character uuid)
returns boolean
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;          -- serializes every Wild Shape change
  return public._end_expired_form(p_character);
end;
$$;

-- Take a form. p_options: {"equipment": {"mode": "merge" | "drop" | "wear", "items": {"<inventory item id>": mode}}, "notes": "..."}.
-- The form, its hit points, its cost and the duration come from the catalog and the rules, never from the client.
create function public.start_transformation(p_character uuid, p_creature text, p_options jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.creatures; o record; ch public.characters; mode text; items jsonb := '{}'; k text; dropped jsonb := '{}'; v text;
begin
  perform public._lock_for_wild_shape(p_character);
  if exists (select 1 from public.character_transformations where character_id = p_character) then
    raise exception 'End the current form first' using errcode = '22023';
  end if;
  select * into c from public.creatures where id = p_creature;
  if not found then raise exception 'Unknown creature "%"', p_creature using errcode = '22023'; end if;
  select * into o from public._form_options(p_character) x where x.creature_id = c.id;
  if o.creature_id is null then
    raise exception '% is not a form you can take: %', c.name,
      case when exists (select 1 from public._character_transform_rules(p_character)) then 'it is not a kind of creature you can become'
           else 'you have no feature that lets you change shape' end using errcode = '22023';
  end if;
  if not coalesce(o.allowed, false) then
    raise exception '% is not a form you can take: %', c.name, array_to_string(o.reasons, '; ') using errcode = '22023';
  end if;
  mode := coalesce(p_options -> 'equipment' ->> 'mode', (public._wild_shape_settings(p_character)).default_equipment);
  if mode not in ('merge', 'drop', 'wear') then raise exception 'Equipment mode is merge, drop or wear' using errcode = '22023'; end if;
  for k, v in select key, value from jsonb_each_text(coalesce(p_options -> 'equipment' -> 'items', '{}')) loop
    if v not in ('merge', 'drop', 'wear') or not exists (select 1 from public.character_equipment ce where ce.character_id = p_character
                                                         and ce.inventory_item_id = k::uuid) then
      raise exception 'Equipment choice for an item that is not equipped, or an unknown mode' using errcode = '22023';
    end if;
    items := items || jsonb_build_object(k, v);
  end loop;
  perform public.expend_character_resource(p_character, o.rule_resource, o.cost,
                                           format('%s: %s', case when o.elemental then 'Elemental Wild Shape' else 'Wild Shape' end, c.name));
  -- dropped equipment: unequipped now (it stays in the inventory) and never re-equipped automatically
  for k in select ce.inventory_item_id::text from public.character_equipment ce where ce.character_id = p_character
             and coalesce(items ->> ce.inventory_item_id::text, mode) = 'drop' loop
    perform public.unequip_item(k::uuid);
    dropped := dropped || jsonb_build_object(k, 'drop');
  end loop;
  select * into ch from public.characters where id = p_character;
  insert into public.character_transformations (character_id, character_class_id, resource_key, creature_id, cost, hp_max, hp_current, started_by,
      normal_hp_current, normal_hp_temp, max_duration_minutes, expires_at, elemental, equipment, seen_status, notes)
  values (p_character, o.character_class_id, o.rule_resource, c.id, o.cost, c.hit_points, c.hit_points, auth.uid(),
      ch.hp_current, ch.hp_temp, o.duration_minutes, case when o.duration_minutes is not null then now() + make_interval(mins => o.duration_minutes) end,
      o.elemental, jsonb_build_object('mode', mode, 'items', items, 'dropped', dropped), coalesce(o.seen, o.status),
      nullif(left(p_options ->> 'notes', 2000), ''));
  perform public._wild_shape_event(p_character, 'transformed', c.id, jsonb_build_object('hp', ch.hp_current, 'hp_temp', ch.hp_temp),
    jsonb_build_object('form_hp', c.hit_points), jsonb_build_object('cost', o.cost, 'elemental', o.elemental, 'status', o.status,
      'moon', (select subclass_version_id = 'druid-moon-phb' from public.character_classes where id = o.character_class_id),
      'equipment', mode, 'dropped', dropped));
  return public.get_character_transformation(p_character);
end;
$$;

-- Damage to the form: temporary HP first, then form HP. At 0 the form ends; the rest carries over to the normal form
-- (its temporary HP first). One locked transaction: the excess is applied exactly once.
create function public.damage_active_transformation(p_character uuid, p_amount int, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare t public.character_transformations; ch public.characters; temp_used int; left_dmg int; nv int; carry int := 0; ntemp int := 0; nhp int;
  result jsonb;
begin
  if p_amount is null or p_amount < 1 or p_amount > 10000 then raise exception 'Give a damage amount (1 or more)' using errcode = '22023'; end if;
  if public._lock_for_wild_shape(p_character) then return public.get_character_transformation(p_character) || jsonb_build_object('result', jsonb_build_object('expired', true, 'ended', true, 'reason', 'expired')); end if;
  select * into t from public.character_transformations where character_id = p_character for update;
  if not found then raise exception 'The character is not in Wild Shape' using errcode = '22023'; end if;
  temp_used := least(t.hp_temp, p_amount);
  left_dmg := p_amount - temp_used;
  nv := t.hp_current - left_dmg;
  if nv > 0 then
    update public.character_transformations set hp_current = nv, hp_temp = hp_temp - temp_used where character_id = p_character;
    perform public._wild_shape_event(p_character, 'damaged', t.creature_id, jsonb_build_object('hp', t.hp_current, 'temp', t.hp_temp),
      jsonb_build_object('hp', nv, 'temp', t.hp_temp - temp_used), jsonb_build_object('amount', p_amount, 'note', p_note));
    result := jsonb_build_object('amount', p_amount, 'temp_absorbed', temp_used, 'form_hp_before', t.hp_current, 'form_hp_after', nv,
                                 'ended', false, 'carryover', 0);
  else
    carry := -nv;
    delete from public.character_transformations where character_id = p_character;
    select * into ch from public.characters where id = p_character;
    ntemp := least(coalesce(ch.hp_temp, 0), carry);
    nhp := greatest(0, coalesce(ch.hp_current, 0) - (carry - ntemp));
    update public.characters set hp_temp = coalesce(hp_temp, 0) - ntemp, hp_current = nhp where id = p_character;
    perform public._wild_shape_event(p_character, 'reverted_zero_hp', t.creature_id, jsonb_build_object('hp', t.hp_current, 'temp', t.hp_temp),
      jsonb_build_object('hp', 0), jsonb_build_object('amount', p_amount, 'note', p_note));
    if carry > 0 then
      perform public._wild_shape_event(p_character, 'excess_damage', t.creature_id, jsonb_build_object('hp', ch.hp_current, 'temp', ch.hp_temp),
        jsonb_build_object('hp', nhp, 'temp', coalesce(ch.hp_temp, 0) - ntemp), jsonb_build_object('carryover', carry));
    end if;
    result := jsonb_build_object('amount', p_amount, 'temp_absorbed', temp_used, 'form_hp_before', t.hp_current, 'form_hp_after', 0,
      'ended', true, 'carryover', carry, 'normal_hp_before', ch.hp_current, 'normal_hp_after', nhp, 'normal_temp_absorbed', ntemp,
      'unconscious', nhp = 0);
  end if;
  return public.get_character_transformation(p_character) || jsonb_build_object('result', result);
end;
$$;

create function public.heal_active_transformation(p_character uuid, p_amount int, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare t public.character_transformations; nv int;
begin
  if p_amount is null or p_amount < 1 or p_amount > 10000 then raise exception 'Give a healing amount (1 or more)' using errcode = '22023'; end if;
  if public._lock_for_wild_shape(p_character) then return public.get_character_transformation(p_character) || jsonb_build_object('result', jsonb_build_object('expired', true, 'ended', true, 'reason', 'expired')); end if;
  select * into t from public.character_transformations where character_id = p_character for update;
  if not found then raise exception 'The character is not in Wild Shape' using errcode = '22023'; end if;
  nv := least(t.hp_max, t.hp_current + p_amount);
  update public.character_transformations set hp_current = nv where character_id = p_character;
  perform public._wild_shape_event(p_character, 'healed', t.creature_id, jsonb_build_object('hp', t.hp_current), jsonb_build_object('hp', nv),
    jsonb_build_object('amount', p_amount, 'note', p_note));
  return public.get_character_transformation(p_character) || jsonb_build_object('result',
    jsonb_build_object('amount', p_amount, 'healed', nv - t.hp_current, 'form_hp_before', t.hp_current, 'form_hp_after', nv));
end;
$$;

-- Manual correction of the form's hit points and temporary hit points (1..max; a reason is kept in the history)
create function public.set_transformation_hp(p_character uuid, p_hp int, p_temp int default null, p_reason text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare t public.character_transformations;
begin
  if public._lock_for_wild_shape(p_character) then return public.get_character_transformation(p_character) || jsonb_build_object('result', jsonb_build_object('expired', true, 'ended', true, 'reason', 'expired')); end if;
  select * into t from public.character_transformations where character_id = p_character for update;
  if not found then raise exception 'The character is not in Wild Shape' using errcode = '22023'; end if;
  if p_hp is null or p_hp < 1 or p_hp > t.hp_max then
    raise exception 'Form hit points are between 1 and % (use Damage to end the form)', t.hp_max using errcode = '22023';
  end if;
  if p_temp is not null and (p_temp < 0 or p_temp > 999) then raise exception 'Temporary hit points are 0 to 999' using errcode = '22023'; end if;
  if p_temp is null and coalesce(btrim(p_reason), '') = '' then raise exception 'A manual correction needs a reason' using errcode = '22023'; end if;
  update public.character_transformations set hp_current = p_hp, hp_temp = coalesce(p_temp, hp_temp) where character_id = p_character;
  perform public._wild_shape_event(p_character, case when p_temp is not null and p_hp = t.hp_current then 'temp_hp' else 'manual_set' end, t.creature_id,
    jsonb_build_object('hp', t.hp_current, 'temp', t.hp_temp), jsonb_build_object('hp', p_hp, 'temp', coalesce(p_temp, t.hp_temp)),
    jsonb_build_object('reason', p_reason));
  return public.get_character_transformation(p_character);
end;
$$;

-- Revert: restores nothing on the character row (normal HP was never touched); no Wild Shape use is spent
create function public.end_transformation(p_character uuid, p_reason text default 'manual')
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare t public.character_transformations;
begin
  if p_reason not in ('manual', 'unconscious', 'dead', 'dm') then raise exception 'Unknown reason "%"', p_reason using errcode = '22023'; end if;
  if public._lock_for_wild_shape(p_character) then return public.get_character_transformation(p_character) || jsonb_build_object('result', jsonb_build_object('expired', true, 'ended', true, 'reason', 'expired')); end if;
  select * into t from public.character_transformations where character_id = p_character for update;
  if not found then raise exception 'The character is not in Wild Shape' using errcode = '22023'; end if;
  delete from public.character_transformations where character_id = p_character;
  perform public._wild_shape_event(p_character, 'reverted_manual', t.creature_id, jsonb_build_object('hp', t.hp_current, 'temp', t.hp_temp), null,
    jsonb_build_object('reason', p_reason, 'dropped', t.equipment -> 'dropped'));
  return public.get_character_transformation(p_character) || jsonb_build_object('result',
    jsonb_build_object('ended', true, 'reason', p_reason, 'dropped', t.equipment -> 'dropped'));
end;
$$;

-- Combat Wild Shape (Circle of the Moon): in a beast form, spend one spell slot to regain 1d8 per slot level. The roll comes
-- from the server unless the player rolled physical dice (validated range). Pact Magic only on explicit request.
create function public.combat_wild_shape_heal(p_character uuid, p_slot_level int, p_pool text default 'standard', p_roll int default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare t public.character_transformations; roll int := 0; i int; nv int; pact jsonb;
begin
  if public._lock_for_wild_shape(p_character) then return public.get_character_transformation(p_character) || jsonb_build_object('result', jsonb_build_object('expired', true, 'ended', true, 'reason', 'expired')); end if;
  select * into t from public.character_transformations where character_id = p_character for update;
  if not found then raise exception 'The character is not in Wild Shape' using errcode = '22023'; end if;
  if not exists (select 1 from public.character_classes cc where cc.character_id = p_character and cc.class_id = 'druid'
                 and cc.subclass_version_id = 'druid-moon-phb' and cc.level >= 2) then
    raise exception 'Combat Wild Shape needs the Circle of the Moon' using errcode = '22023';
  end if;
  if t.elemental then raise exception 'Combat Wild Shape heals a beast form, not an elemental' using errcode = '22023'; end if;
  if p_pool not in ('standard', 'pact') then raise exception 'Slot pool is standard or pact' using errcode = '22023'; end if;
  if p_pool = 'pact' then
    pact := public.get_character_spell_slots(p_character) -> 'pact_magic';
    if pact is null or jsonb_typeof(pact) <> 'object' then raise exception 'No Pact Magic slots' using errcode = '22023'; end if;
    p_slot_level := (pact ->> 'slot_level')::int;
  end if;
  if p_slot_level is null or p_slot_level not between 1 and 9 then raise exception 'Choose a slot level' using errcode = '22023'; end if;
  if p_roll is not null and (p_roll < p_slot_level or p_roll > 8 * p_slot_level) then
    raise exception 'A roll of %d8 is between % and %', p_slot_level, p_slot_level, 8 * p_slot_level using errcode = '22023';
  end if;
  perform public._slot_change(p_character, p_pool, case when p_pool = 'pact' then null else p_slot_level end, 1, 'Combat Wild Shape');
  if p_roll is null then
    for i in 1..p_slot_level loop roll := roll + 1 + floor(random() * 8)::int; end loop;
  else
    roll := p_roll;
  end if;
  nv := least(t.hp_max, t.hp_current + roll);
  update public.character_transformations set hp_current = nv where character_id = p_character;
  perform public._wild_shape_event(p_character, 'combat_healing', t.creature_id, jsonb_build_object('hp', t.hp_current), jsonb_build_object('hp', nv),
    jsonb_build_object('slot_level', p_slot_level, 'pool', p_pool, 'roll', roll, 'rolled_by', case when p_roll is null then 'server' else 'player' end));
  return public.get_character_transformation(p_character) || jsonb_build_object('result',
    jsonb_build_object('roll', roll, 'dice', format('%sd8', p_slot_level), 'healed', nv - t.hp_current, 'form_hp_after', nv, 'slot_level', p_slot_level, 'pool', p_pool));
end;
$$;

-- Limited form abilities (Recharge 5-6, once per rest): tracked on this form only and gone when it ends.
-- p_action: use | roll (recharge roll; server roll unless p_roll is given) | restore (manual)
create function public.use_form_ability(p_character uuid, p_ability text, p_action text default 'use', p_roll int default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare t public.character_transformations; c public.creatures; a jsonb; avail boolean; roll int; minv int;
begin
  if public._lock_for_wild_shape(p_character) then return public.get_character_transformation(p_character) || jsonb_build_object('result', jsonb_build_object('expired', true, 'ended', true, 'reason', 'expired')); end if;
  select * into t from public.character_transformations where character_id = p_character for update;
  if not found then raise exception 'The character is not in Wild Shape' using errcode = '22023'; end if;
  select * into c from public.creatures where id = t.creature_id;
  select x into a from jsonb_array_elements(c.actions || c.traits || c.reactions) x where x ->> 'name' = p_ability and x ? 'usage';
  if a is null then raise exception '% has no limited ability "%"', c.name, p_ability using errcode = '22023'; end if;
  avail := coalesce((t.action_state -> p_ability ->> 'available')::boolean, true);
  if p_action = 'use' then
    if not avail then raise exception '% is not available (recharge it first)', p_ability using errcode = '22023'; end if;
    avail := false;
  elsif p_action = 'roll' then
    if a -> 'usage' ->> 'type' <> 'recharge on roll' then raise exception '% does not recharge on a roll', p_ability using errcode = '22023'; end if;
    minv := (a -> 'usage' ->> 'min_value')::int;
    if p_roll is not null and p_roll not between 1 and 6 then raise exception 'A d6 roll is 1 to 6' using errcode = '22023'; end if;
    roll := coalesce(p_roll, 1 + floor(random() * 6)::int);
    avail := avail or roll >= minv;
  elsif p_action = 'restore' then
    avail := true;
  else
    raise exception 'Action is use, roll or restore' using errcode = '22023';
  end if;
  update public.character_transformations set action_state = action_state || jsonb_build_object(p_ability, jsonb_build_object('available', avail))
  where character_id = p_character;
  perform public._wild_shape_event(p_character, case when p_action = 'use' then 'ability_used' else 'ability_recharged' end, t.creature_id, null,
    jsonb_build_object('ability', p_ability, 'available', avail), jsonb_build_object('action', p_action, 'roll', roll));
  return public.get_character_transformation(p_character) || jsonb_build_object('result',
    jsonb_build_object('ability', p_ability, 'available', avail, 'roll', roll, 'min', minv));
end;
$$;

-- Seen forms: the player marks beasts seen; a DM (or the owner of a character outside a campaign) may grant an exception
create function public.set_seen_forms(p_character uuid, p_creatures text[], p_seen boolean default true, p_source text default 'seen',
                                      p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare x text;
begin
  perform public._lock_for_wild_shape(p_character);
  if p_source not in ('seen', 'dm_grant') then raise exception 'Source is seen or dm_grant' using errcode = '22023'; end if;
  if p_source = 'dm_grant' and not public._acts_as_dm(p_character) then
    raise exception 'Only the DM can grant a form exception' using errcode = '42501';
  end if;
  foreach x in array coalesce(p_creatures, '{}') loop
    if not exists (select 1 from public.creatures where id = x) then raise exception 'Unknown creature "%"', x using errcode = '22023'; end if;
    if p_seen then
      if exists (select 1 from public.character_seen_forms where character_id = p_character and creature_id = x and source = 'dm_grant')
         and p_source <> 'dm_grant' and not public._acts_as_dm(p_character) then
        continue;                                                   -- a DM grant is not downgraded by the player
      end if;
      insert into public.character_seen_forms (character_id, creature_id, source, note, created_by)
      values (p_character, x, p_source, nullif(left(p_note, 300), ''), auth.uid())
      on conflict (character_id, creature_id) do update set source = excluded.source, note = coalesce(excluded.note, character_seen_forms.note);
      perform public._wild_shape_event(p_character, 'seen_added', x, null, null, jsonb_build_object('source', p_source, 'note', p_note));
    else
      if exists (select 1 from public.character_seen_forms where character_id = p_character and creature_id = x and source = 'dm_grant')
         and not public._acts_as_dm(p_character) then
        raise exception 'Only the DM can remove a DM grant' using errcode = '42501';
      end if;
      delete from public.character_seen_forms where character_id = p_character and creature_id = x;
      if found then perform public._wild_shape_event(p_character, 'seen_removed', x, null, null, '{}'); end if;
    end if;
  end loop;
  return public.get_character_transformation(p_character);
end;
$$;

create function public.set_form_favorite(p_character uuid, p_creature text, p_favorite boolean default true)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if not exists (select 1 from public.creatures where id = p_creature) then raise exception 'Unknown creature' using errcode = '22023'; end if;
  if p_favorite then
    insert into public.character_form_favorites (character_id, creature_id) values (p_character, p_creature) on conflict do nothing;
  else
    delete from public.character_form_favorites where character_id = p_character and creature_id = p_creature;
  end if;
  return jsonb_build_object('creature_id', p_creature, 'favorite', p_favorite);
end;
$$;

-- Settings: seen mode (enforce / warn by anyone who may edit the character; unrestricted only by the DM), default equipment
create function public.set_wild_shape_settings(p_character uuid, p_seen_mode text default null, p_default_equipment text default null,
                                               p_confirm_lethal boolean default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cur public.character_wild_shape_settings;
begin
  perform public._lock_for_wild_shape(p_character);
  cur := public._wild_shape_settings(p_character);
  if p_seen_mode is not null and p_seen_mode not in ('enforce', 'warn', 'unrestricted') then raise exception 'Unknown seen mode' using errcode = '22023'; end if;
  if p_default_equipment is not null and p_default_equipment not in ('merge', 'drop', 'wear') then raise exception 'Unknown equipment mode' using errcode = '22023'; end if;
  if (p_seen_mode = 'unrestricted' or (cur.seen_mode = 'unrestricted' and p_seen_mode is not null and p_seen_mode <> 'unrestricted'))
     and not public._acts_as_dm(p_character) then
    raise exception 'Only the DM can turn unrestricted forms on or off' using errcode = '42501';
  end if;
  insert into public.character_wild_shape_settings (character_id, seen_mode, default_equipment, confirm_lethal, updated_at, updated_by)
  values (p_character, coalesce(p_seen_mode, cur.seen_mode), coalesce(p_default_equipment, cur.default_equipment),
          coalesce(p_confirm_lethal, cur.confirm_lethal), now(), auth.uid())
  on conflict (character_id) do update set seen_mode = excluded.seen_mode, default_equipment = excluded.default_equipment,
    confirm_lethal = excluded.confirm_lethal, updated_at = now(), updated_by = auth.uid();
  perform public._wild_shape_event(p_character, 'settings', null, to_jsonb(cur) - 'character_id', null,
    jsonb_build_object('seen_mode', p_seen_mode, 'default_equipment', p_default_equipment, 'confirm_lethal', p_confirm_lethal));
  return public.get_character_transformation(p_character);
end;
$$;

-- Change an equipped item's mode while transformed (merge <-> wear; dropping happens only when the form starts)
create function public.set_transformation_equipment(p_character uuid, p_item uuid, p_mode text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare t public.character_transformations;
begin
  if public._lock_for_wild_shape(p_character) then return public.get_character_transformation(p_character) || jsonb_build_object('result', jsonb_build_object('expired', true, 'ended', true, 'reason', 'expired')); end if;
  select * into t from public.character_transformations where character_id = p_character for update;
  if not found then raise exception 'The character is not in Wild Shape' using errcode = '22023'; end if;
  if p_mode not in ('merge', 'wear') then raise exception 'While transformed an item is merged or worn' using errcode = '22023'; end if;
  if not exists (select 1 from public.character_equipment where character_id = p_character and inventory_item_id = p_item) then
    raise exception 'The item is not equipped' using errcode = '22023';
  end if;
  update public.character_transformations set equipment = jsonb_set(equipment, '{items}', coalesce(equipment -> 'items', '{}') || jsonb_build_object(p_item::text, p_mode))
  where character_id = p_character;
  perform public._wild_shape_event(p_character, 'equipment', t.creature_id, t.equipment -> 'items' -> p_item::text, to_jsonb(p_mode), jsonb_build_object('item', p_item));
  return public.get_character_transformation(p_character);
end;
$$;

-- the earlier API (damage negative, healing positive) on top of the locked operations
create function public.change_transformation_hp(p_character uuid, p_delta int)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r jsonb;
begin
  if p_delta is null or p_delta = 0 then raise exception 'Give a damage or healing amount' using errcode = '22023'; end if;
  r := case when p_delta < 0 then public.damage_active_transformation(p_character, -p_delta) else public.heal_active_transformation(p_character, p_delta) end;
  return r || jsonb_build_object('ended', coalesce((r -> 'result' ->> 'ended')::boolean, false),
                                 'carryover', coalesce((r -> 'result' ->> 'carryover')::int, 0));
end;
$$;

-- the derived stats while transformed: the class layer result with the Wild Shape layer on top
alter function public.get_character_derived_stats(uuid) rename to _derived_stats_full;
create function public.get_character_derived_stats(p_character uuid)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$ select public._wild_shape_layer(p_character, public._derived_stats_full(p_character)) $$;

revoke all on function public._active_form(uuid), public._item_active_in_form(uuid, uuid), public._wild_shape_event(uuid, text, text, jsonb, jsonb, jsonb),
  public._wild_shape_settings(uuid), public._acts_as_dm(uuid), public._form_options(uuid), public._cr_text(numeric),
  public._wild_shape_sheet(uuid, jsonb), public._wild_shape_layer(uuid, jsonb), public._end_expired_form(uuid), public._lock_for_wild_shape(uuid),
  public.get_character_transformation(uuid), public.start_transformation(uuid, text, jsonb), public.damage_active_transformation(uuid, int, text),
  public.heal_active_transformation(uuid, int, text), public.set_transformation_hp(uuid, int, int, text), public.end_transformation(uuid, text),
  public.combat_wild_shape_heal(uuid, int, text, int), public.use_form_ability(uuid, text, text, int), public.set_seen_forms(uuid, text[], boolean, text, text),
  public.set_form_favorite(uuid, text, boolean), public.set_wild_shape_settings(uuid, text, text, boolean),
  public.set_transformation_equipment(uuid, uuid, text), public.change_transformation_hp(uuid, int), public.get_character_derived_stats(uuid),
  public._derived_stats_full(uuid) from public, anon;
revoke all on function public._wild_shape_event(uuid, text, text, jsonb, jsonb, jsonb), public._end_expired_form(uuid) from authenticated;
grant execute on function public._active_form(uuid), public._item_active_in_form(uuid, uuid), public._wild_shape_settings(uuid), public._acts_as_dm(uuid),
  public._form_options(uuid), public._cr_text(numeric), public._wild_shape_sheet(uuid, jsonb), public._wild_shape_layer(uuid, jsonb),
  public._lock_for_wild_shape(uuid), public.get_character_transformation(uuid), public.start_transformation(uuid, text, jsonb),
  public.damage_active_transformation(uuid, int, text), public.heal_active_transformation(uuid, int, text), public.set_transformation_hp(uuid, int, int, text),
  public.end_transformation(uuid, text), public.combat_wild_shape_heal(uuid, int, text, int), public.use_form_ability(uuid, text, text, int),
  public.set_seen_forms(uuid, text[], boolean, text, text), public.set_form_favorite(uuid, text, boolean),
  public.set_wild_shape_settings(uuid, text, text, boolean), public.set_transformation_equipment(uuid, uuid, text),
  public.change_transformation_hp(uuid, int), public.get_character_derived_stats(uuid), public._derived_stats_full(uuid) to authenticated;

-- ---- edited copies (privileges kept by create or replace) ----

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
begin
  select * into c from public.characters where id = p_character;                 -- RLS: owner, campaign DM, admin
  if not found then raise exception 'Character not found' using errcode = '42501'; end if;

  pb := (greatest(c.level, 1) - 1) / 4 + 2;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.effect_type, e.source_name, e.seq), '[]'::jsonb) into effects
  from public._character_effects(p_character) e;
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
    score := least(30, greatest(after_lineage, coalesce(override_score, 0)) + bonus);
    if form_ab is not null and k in ('str', 'dex', 'con') then score := (form_ab ->> k)::int; end if;   -- the form's physical scores
    scores := scores || jsonb_build_object(k, score);
    mods := mods || jsonb_build_object(k, public._ability_mod(score));
    abilities := abilities || jsonb_build_object(k, jsonb_build_object('base', base_score, 'score', score,
      'modifier', public._ability_mod(score), 'override', override_score, 'bonus', bonus,
      'lineage_bonus', lin_bonus, 'lineage_applied', lin_after - base_score, 'lineage_included', lin_included,
      'background_bonus', bg_bonus, 'background_applied', after_lineage - lin_after,
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
                                'movement', movement),
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
                                                       where (e ->> 'active')::boolean and e ->> 'effect_type' = 'initiative_bonus'), 0),
                                     'sources', (select coalesce(jsonb_agg(e ->> 'trait_name'), '[]') from jsonb_array_elements(leff) e
                                                 where (e ->> 'active')::boolean and e ->> 'effect_type' = 'initiative_bonus')),
    'hit_points', jsonb_build_object('lineage_bonus', coalesce((select sum((e ->> 'value')::int) * c.level from jsonb_array_elements(leff) e
                                                               where (e ->> 'active')::boolean and e ->> 'effect_type' = 'hp_per_level'), 0),
                                     'sources', (select coalesce(jsonb_agg(e ->> 'trait_name'), '[]') from jsonb_array_elements(leff) e
                                                 where (e ->> 'active')::boolean and e ->> 'effect_type' = 'hp_per_level')),
    'carrying_capacity', jsonb_build_object('size_steps', coalesce((select max((e ->> 'value')::int) from jsonb_array_elements(leff) e
                                                                    where (e ->> 'active')::boolean and e ->> 'effect_type' = 'carrying_capacity'), 0))));
end;
$function$;

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
    join public.items it on it.id = ii.item_id                       -- RLS: effects of invisible items do not exist
    left join public.character_equipment e on e.inventory_item_id = ii.id and e.character_id = p_character
      and public._item_active_in_form(p_character, ii.id)              -- merged or dropped in Wild Shape: no effect
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
    union all
    -- class feature effects (20261015001800); only active features, the effect's own conditions decide inactive_reason
    select 'class_feature', ce.character_class_id, null, ce.class_name || ': ' || ce.feature_name,
           ce.unlock_id || ':' || ce.seq || ':' || coalesce(ce.pick, 0), ce.seq,
           ce.effect_type, ce.value, case when ce.effect_type = 'resistance' then coalesce(ce.target, ce.value_text) else ce.target end,
           'owned', 'additive', null, 0, 'global',
           case when ce.active then null else coalesce(ce.inactive_reason, 'inactive') end
    from public._character_class_effects(p_character) ce
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
