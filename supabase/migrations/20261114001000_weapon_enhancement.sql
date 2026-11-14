-- =============================================================================
-- Weapon enhancement (crafting, R-E2; docs/CRAFTING_V1.md "Weapon enhancement"). Additive on top of 20261114000900_crafting_v2;
-- rollback supabase/rollback/rollback_weapon_enhancement.sql (exact previous bodies; it REFUSES, changing nothing, once a DM has
-- written an enhancement recipe, so the v2 bodies never meet a recipe without a result).
--  1. A recipe kind 'enhancement': one ingredient line is the BASE (an exact item or a tag, kept, quantity 1); the result is the
--     SAME inventory row (same id, quantity, knowledge, equipped / attuned state) with a campaign item modifier attached
--     (inventory_item_modifiers, the infusion pattern). output_item_id is null only for such recipes (a CHECK per kind).
--     Success and critical success attach it (a critical success has success semantics: no bonus); a failure follows the failure
--     rule for the used-up ingredients and never touches the base. An unidentified base is refused like an ingredient.
--  2. Campaign modifiers ('cm-<10 hex>', owner = the DM, campaign_id): dm_save_campaign_modifier (name, description, kind it fits,
--     rarity, effects of the kinds the derived engine applies: attack / damage (that item only), AC, saving throws, a note).
--     Effects of a modifier already on an item are frozen (make a new one). Read: get_campaign_recipes(...).modifiers.
--  3. Secrecy: a homebrew modifier (and its effects) is readable only by its author, an admin, the campaign DM, or a reader of an
--     inventory holding a row with it that the reader sees undisguised (_modifier_visible, the _item_visible pattern). The modifier
--     branch of _character_effects moves into a SECURITY DEFINER helper (numbers do not depend on that policy) and, for a copy the
--     reader sees disguised, carries only the disguise: no modifier name, no modifier id, no inactive rows. Numbers are unchanged.
--  4. A campaign modifier is attached only by crafting (tavern.rpc), the campaign DM or an admin: a player's direct REST insert
--     into inventory_item_modifiers is refused.
--  5. Review follow-ups of R-E: m3 (start_craft_attempt refuses a natural roll on a recipe without a check), m4 (recipe items must
--     be items of the campaign: DM content or a DM's campaign homebrew; existing links keep working).
-- No grant-sync enqueue: an item modifier carries no spells, weapon blocks or counters (its after-write trigger updates the
-- inventory row, which the existing triggers handle). Cache: no new table. No Realtime change.
-- =============================================================================
set lock_timeout = '5s';

-- ---- 1. schema -----------------------------------------------------------------------------------------------------------------
alter table public.crafting_recipes add column if not exists kind text not null default 'item';
alter table public.crafting_recipes add column if not exists enhance_modifier_id text references public.item_modifiers (id);
alter table public.crafting_recipes alter column output_item_id drop not null;
alter table public.crafting_recipes drop constraint if exists crafting_recipes_kind_check;
alter table public.crafting_recipes add constraint crafting_recipes_kind_check check (
  (kind = 'item' and output_item_id is not null and enhance_modifier_id is null)
  or (kind = 'enhancement' and output_item_id is null and enhance_modifier_id is not null and crit_output_item_id is null));
create index if not exists crafting_recipes_modifier on public.crafting_recipes (enhance_modifier_id) where enhance_modifier_id is not null;

alter table public.crafting_recipe_ingredients add column if not exists is_base boolean not null default false;
alter table public.crafting_recipe_ingredients drop constraint if exists crafting_recipe_ingredients_base_check;
alter table public.crafting_recipe_ingredients add constraint crafting_recipe_ingredients_base_check
  check (not is_base or (not consumed and quantity = 1));
create unique index if not exists crafting_recipe_ingredients_one_base on public.crafting_recipe_ingredients (recipe_id) where is_base;

-- ---- 2. modifier visibility ------------------------------------------------------------------------------------------------------
-- Official modifiers: everybody. Homebrew: as before (author, admin, campaign members) AND, beyond the DM side, only for a reader
-- who can read an inventory holding a row with the modifier that is not disguised for him (no knowledge row or an identified one).
create or replace function public._modifier_visible(p_id text, p_owner uuid, p_campaign uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public.can_view_owned(p_owner, p_campaign)
     and (p_owner is null or public.is_admin() or public.can_edit_owned(p_owner, p_campaign)
          or (p_campaign is not null and public.is_campaign_dm(p_campaign))
          or exists (select 1 from public.inventory_item_modifiers im join public.inventory_items ii on ii.id = im.inventory_item_id
                     where im.modifier_id = p_id and public.can_read_inventory(ii.inventory_id)
                       and not exists (select 1 from public.inventory_item_knowledge k
                                       where k.inventory_item_id = ii.id and k.state <> 'identified')));
$$;
revoke all on function public._modifier_visible(text, uuid, uuid) from public, anon;
grant execute on function public._modifier_visible(text, uuid, uuid) to anon, authenticated;

drop policy if exists "item_modifiers_read" on public.item_modifiers;
create policy "item_modifiers_read" on public.item_modifiers for select to anon, authenticated
  using (public._modifier_visible(id, owner_id, campaign_id));

-- item_modifier_categories / item_modifier_effects read through this (body of 20261015000700 + _modifier_visible)
create or replace function public.can_view_modifier(p_mod text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$ select exists (select 1 from public.item_modifiers m where m.id = p_mod and public._modifier_visible(m.id, m.owner_id, m.campaign_id)); $$;

-- ---- 3. who attaches a campaign modifier ----------------------------------------------------------------------------------------
-- body of 20261017000900 + SECURITY DEFINER (the modifier is read whatever the caller may see) + the campaign-modifier rule
create or replace function public.inventory_item_modifiers_before_write()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items; m public.item_modifiers;
begin
  if tg_op = 'DELETE' then
    if exists (select 1 from public.item_modifiers x where x.id = old.modifier_id and x.managed_by is not null)
       and coalesce(current_setting('tavern.managed_modifier', true), '') <> '1' then
      raise exception 'This modifier is managed by a class feature; end it there (Infuse Item)' using errcode = '42501';
    end if;
    return old;
  end if;
  select i.* into it from public.inventory_items ii join public.items i on i.id = ii.item_id where ii.id = new.inventory_item_id;
  if it.id is null then raise exception 'Modifiers can only be applied to catalog items'; end if;
  select * into m from public.item_modifiers where id = new.modifier_id;
  if m.managed_by is not null and coalesce(current_setting('tavern.managed_modifier', true), '') <> '1' then
    raise exception 'This modifier is applied by a class feature (Infuse Item), not directly' using errcode = '42501';
  end if;
  -- 20261114001000: a campaign modifier (an enhancement) is attached by crafting (inside an RPC), the campaign DM or an admin
  if m.campaign_id is not null and m.owner_id is not null
     and coalesce(current_setting('tavern.rpc', true), '') <> '1' and coalesce(current_setting('tavern.managed_modifier', true), '') <> '1'
     and auth.uid() is not null and not public.is_admin() and not public.is_campaign_dm(m.campaign_id) then
    raise exception 'This enhancement is attached by crafting, not directly' using errcode = '42501';
  end if;
  if m.applies_to_kind_id is not null and m.applies_to_kind_id <> it.kind_id then
    raise exception 'Modifier % does not apply to items of kind %', m.id, it.kind_id;
  end if;
  if exists (select 1 from public.item_modifier_categories c where c.modifier_id = m.id)
     and not exists (select 1 from public.item_modifier_categories c where c.modifier_id = m.id and c.category_id = it.category_id) then
    raise exception 'Modifier % does not apply to category %', m.id, coalesce(it.category_id, '(none)');
  end if;
  return new;
end;
$$;

-- ---- 4. derived stats: the modifier rows ------------------------------------------------------------------------------------------
-- The modifier rows of a character's items for _character_effects (same columns and rules as its former `owned` branch, now
-- SECURITY DEFINER: the numbers never depend on what the reader may read; only a character the caller may access). A copy the reader sees disguised: the disguise as the
-- source name (no modifier name), no item id, no modifier id (seq numbered per copy instead, so additive effects stay apart), and
-- no inactive rows (they would show that the item is magic); its active numbers still count, as for every unidentified item.
create or replace function public._character_modifier_effect_rows(p_character uuid)
returns table (source_type text, source_id uuid, item_id text, source_name text, modifier_id text, seq int, effect_type text, value numeric,
               target text, activation text, stacking text, stack_group text, priority int, scope text, inactive_reason text)
language sql stable security definer
set search_path = public, pg_temp
as $$
  with v as (select public.can_access_character(p_character) or public._internal_caller() as ok),
  owned as (
    select ii.id, ii.item_id, mk.masked,
           ii.is_attuned and public._item_active_in_form(p_character, ii.id) as is_attuned,
           case when mk.masked then coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item') else coalesce(ii.custom_name, it.name) end as name,
           it.requires_attunement, e.slot_id
    from v, public.inventories inv
    join public.inventory_items ii on ii.inventory_id = inv.id
    join public.items it on it.id = ii.item_id
    left join public.character_equipment e on e.inventory_item_id = ii.id and e.character_id = p_character
      and public._item_active_in_form(p_character, ii.id)              -- merged or dropped in Wild Shape: no effect
    cross join lateral (select public._inventory_item_masked(ii.id) as masked) mk
    where v.ok and inv.character_id = p_character
      and exists (select 1 from public.inventory_item_modifiers im where im.inventory_item_id = ii.id)
  ),
  rows_ as (
    select o.id, o.masked, case when o.masked then null else o.item_id end as item_id,
           case when o.masked then o.name else o.name || ' (' || md.name || ')' end as source_name,
           md.id as mod_id, me.seq as mseq, me.effect_type, me.value,
           case when coalesce(md.requires_attunement_override, o.requires_attunement) then 'equipped_and_attuned' else 'equipped' end as activation,
           case when me.effect_type in ('attack_bonus', 'damage_bonus') then 'self' else 'global' end as scope,
           case when o.slot_id is null then 'not_equipped'
                when coalesce(md.requires_attunement_override, o.requires_attunement) and not o.is_attuned then 'not_attuned' end as inactive_reason
    from owned o
    join public.inventory_item_modifiers im on im.inventory_item_id = o.id
    join public.item_modifiers md on md.id = im.modifier_id
    join public.item_modifier_effects me on me.modifier_id = md.id
  )
  select 'modifier'::text, r.id, r.item_id, r.source_name,
         case when r.masked then null else r.mod_id end,
         case when r.masked then (row_number() over (partition by r.id order by r.mod_id, r.mseq))::int else r.mseq end,
         r.effect_type, r.value, null::text, r.activation, 'additive'::text, null::text, 0, r.scope, r.inactive_reason
  from rows_ r
  where not (r.masked and r.inactive_reason is not null);
$$;
-- as _character_item_effect_rows: callable by authenticated (the invoker _character_effects runs as the reader), rows only for a
-- character the caller may access (or an internal caller)
revoke all on function public._character_modifier_effect_rows(uuid) from public, anon;
grant execute on function public._character_modifier_effect_rows(uuid) to authenticated, service_role;

-- body of 20261114000800 with the modifier branch read from _character_modifier_effect_rows (above)
create or replace function public._character_effects(p_character uuid)
returns table (source_type text, source_id uuid, item_id text, source_name text, modifier_id text, seq int, effect_type text, value numeric,
               target text, activation text, stacking text, stack_group text, scope text, active boolean, inactive_reason text, applied boolean)
language sql stable
set search_path = public, pg_temp
as $$
  with raw as (
    -- 20261114000500: item effects of every owned item (also unidentified ones, under their disguise) and permanent effects
    select x.source_type, x.source_id, x.item_id, x.source_name, null::text as modifier_id, x.seq,
           x.effect_type, x.value, x.target, x.activation, x.stacking, x.stack_group, x.priority,
           case when x.effect_type in ('attack_bonus', 'damage_bonus') and x.kind_id = 'weapon' then 'self' else 'global' end as scope,
           x.inactive_reason
    from public._character_item_effect_rows(p_character) x
    union all
    -- 20261114001000: item modifiers (masked per copy, SECURITY DEFINER)
    select m.source_type, m.source_id, m.item_id, m.source_name, m.modifier_id, m.seq,
           m.effect_type, m.value, m.target, m.activation, m.stacking, m.stack_group, m.priority, m.scope, m.inactive_reason
    from public._character_modifier_effect_rows(p_character) m
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
$$;

-- ---- 5. campaign modifiers (the DM's enhancements) -------------------------------------------------------------------------------
-- a modifier a recipe of this campaign may attach: a homebrew modifier of the campaign authored by a DM of the campaign, not
-- managed by a class feature (never another campaign's, never official)
create or replace function public._craft_modifier_ok(p_mod text, p_campaign uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.item_modifiers m where m.id = p_mod and m.campaign_id = p_campaign and m.owner_id is not null
                   and m.managed_by is null
                   and exists (select 1 from public.campaign_members cm where cm.campaign_id = p_campaign and cm.user_id = m.owner_id and cm.role = 'dm'));
$$;

-- the effects of a modifier for a reader who may see them: [{type, value, text}]
create or replace function public._modifier_effects_json(p_mod text)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('type', e.effect_type, 'value', e.value, 'text', nullif(e.data ->> 'text', '')) order by e.seq), '[]')
  from public.item_modifier_effects e where e.modifier_id = p_mod;
$$;

-- one modifier as the DM edits it
create or replace function public._craft_modifier_dm(p_mod text)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', m.id, 'name', m.name, 'description', m.description, 'applies_to_kind_id', m.applies_to_kind_id,
    'rarity_id', m.rarity_id, 'effects', public._modifier_effects_json(m.id),
    'attached', (select count(*) from public.inventory_item_modifiers im where im.modifier_id = m.id),
    'recipes', (select count(*) from public.crafting_recipes r where r.enhance_modifier_id = m.id))
  from public.item_modifiers m where m.id = p_mod;
$$;

-- Insert or update a campaign modifier. p_modifier = {id?, name, description, applies_to_kind_id: 'weapon' | 'armor' | null,
-- rarity_id, effects: [{type: attack_bonus | damage_bonus | ac_bonus | save_bonus | custom, value (-10..10, not 0), text}]}.
-- The effects and the kind of a modifier already on an item are frozen (a new modifier changes them); name / description /
-- rarity may change.
create or replace function public.dm_save_campaign_modifier(p_campaign uuid, p_modifier jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare o jsonb := coalesce(p_modifier, '{}'); m public.item_modifiers; mid text; e jsonb; n int := 0; kind text; rar text; t text; v numeric;
  fx jsonb := '[]'; attached boolean;
begin
  perform public._craft_dm_gate(p_campaign);
  if jsonb_typeof(o) <> 'object' then raise exception 'The enhancement must be an object' using errcode = '22023'; end if;
  if nullif(o ->> 'id', '') is not null then
    select * into m from public.item_modifiers where id = o ->> 'id' for update;
    if m.id is null or m.campaign_id is distinct from p_campaign or m.id !~ '^cm-' then raise exception 'Enhancement not found' using errcode = 'P0002'; end if;
  end if;
  if length(btrim(coalesce(o ->> 'name', ''))) not between 1 and 80 then raise exception 'Give the enhancement a name (up to 80 characters)' using errcode = '22023'; end if;
  if length(coalesce(o ->> 'description', '')) > 1000 then raise exception 'Description up to 1000 characters' using errcode = '22023'; end if;
  kind := nullif(o ->> 'applies_to_kind_id', '');
  if kind is not null and kind not in ('weapon', 'armor') then raise exception 'An enhancement fits weapons, armor or any item' using errcode = '22023'; end if;
  rar := nullif(o ->> 'rarity_id', '');
  if rar is not null and not exists (select 1 from public.rarities where id = rar) then raise exception 'Unknown rarity' using errcode = '22023'; end if;
  if jsonb_typeof(coalesce(o -> 'effects', '[]')) <> 'array' or jsonb_array_length(coalesce(o -> 'effects', '[]')) > 10 then
    raise exception 'Up to 10 effects' using errcode = '22023';
  end if;
  for e in select x from jsonb_array_elements(coalesce(o -> 'effects', '[]')) x loop
    t := e ->> 'type';
    if t not in ('attack_bonus', 'damage_bonus', 'ac_bonus', 'save_bonus', 'custom') then raise exception 'Unknown effect' using errcode = '22023'; end if;
    if t = 'custom' then
      if length(btrim(coalesce(e ->> 'text', ''))) not between 1 and 300 then raise exception 'A note needs a text (up to 300 characters)' using errcode = '22023'; end if;
      fx := fx || jsonb_build_array(jsonb_build_object('type', t, 'value', null, 'text', btrim(e ->> 'text')));
    else
      if jsonb_typeof(e -> 'value') <> 'number' then raise exception 'A bonus needs a number from -10 to 10' using errcode = '22023'; end if;
      v := (e ->> 'value')::numeric;
      if v <> trunc(v) or v not between -10 and 10 or v = 0 then raise exception 'A bonus needs a number from -10 to 10 (not 0)' using errcode = '22023'; end if;
      fx := fx || jsonb_build_array(jsonb_build_object('type', t, 'value', v, 'text', null));
    end if;
  end loop;
  if m.id is not null then
    attached := exists (select 1 from public.inventory_item_modifiers im where im.modifier_id = m.id);
    if attached and (m.applies_to_kind_id is distinct from kind or public._modifier_effects_json(m.id) <> fx) then
      raise exception 'This enhancement is already on an item: its effects and kind stay as they are. Make a new enhancement for other effects.'
        using errcode = '55000';
    end if;
    update public.item_modifiers set name = btrim(o ->> 'name'), description = nullif(left(o ->> 'description', 1000), ''),
           applies_to_kind_id = kind, rarity_id = rar
     where id = m.id;
    mid := m.id;
  else
    mid := 'cm-' || substr(md5(gen_random_uuid()::text), 1, 10);
    insert into public.item_modifiers (id, name, description, applies_to_kind_id, rarity_id, is_magic_override, data_source_id, owner_id, campaign_id)
    values (mid, btrim(o ->> 'name'), nullif(left(o ->> 'description', 1000), ''), kind, rar, true, 'homebrew', auth.uid(), p_campaign);
  end if;
  if m.id is null or not attached then
    delete from public.item_modifier_effects where modifier_id = mid;   -- the effect rows of this (unused) DM modifier only
    for e in select x from jsonb_array_elements(fx) x loop
      n := n + 1;
      insert into public.item_modifier_effects (modifier_id, seq, effect_type, value, data)
      values (mid, n, e ->> 'type', (e ->> 'value')::numeric, case when e ->> 'text' is not null then jsonb_build_object('text', e ->> 'text') else '{}'::jsonb end);
    end loop;
  end if;
  perform public._audit(p_campaign, null, 'enhancement_changed', 'Enhancement ' || btrim(o ->> 'name') || case when m.id is null then ' created' else ' saved' end,
                        null, jsonb_build_object('modifier_id', mid), null, null, 'dm');
  return public._craft_modifier_dm(mid);
end $$;

-- ---- 6. crafting helpers ---------------------------------------------------------------------------------------------------------
-- why a row cannot be the base of an enhancement recipe (null = it can): quantity 1, the modifier not on it yet, a kind / category
-- the modifier fits. Fixed texts (no item or modifier names).
create or replace function public._craft_base_refusal(p_row uuid, p_mod text)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when ii.id is null or it.id is null then 'This item cannot be enhanced'
    when ii.quantity <> 1 then 'Only a single item can be enhanced: split the stack first'
    when exists (select 1 from public.inventory_item_modifiers im where im.inventory_item_id = ii.id and im.modifier_id = p_mod)
      then 'This item already has that enhancement'
    when m.applies_to_kind_id is not null and m.applies_to_kind_id <> it.kind_id then 'This enhancement does not fit that item'
    when exists (select 1 from public.item_modifier_categories c where c.modifier_id = p_mod)
         and not exists (select 1 from public.item_modifier_categories c where c.modifier_id = p_mod and c.category_id = it.category_id)
      then 'This enhancement does not fit that item'
    end
  from (select 1) one
  left join public.inventory_items ii on ii.id = p_row
  left join public.items it on it.id = ii.item_id
  left join public.item_modifiers m on m.id = p_mod;
$$;

-- m4: an item that may teach a recipe: an item of this campaign (DM content or a DM's campaign homebrew), not archived; never an
-- official catalog item (any player could add a copy from the catalog)
create or replace function public._craft_teacher_ok(p_item text, p_campaign uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public._craft_item_ok(p_item, p_campaign)
     and exists (select 1 from public.items i where i.id = p_item and i.owner_id is not null and i.campaign_id = p_campaign);
$$;

-- ---- 7. the player read --------------------------------------------------------------------------------------------------------
-- body of 20261114000900 + enhancement recipes: a base line lists the known rows that can take the enhancement
-- (_craft_base_refusal is null; kept, so equipped / attuned / quest rows count), the result is the enhancement (its name, description
-- and effects, or the DM's label). Item recipes: the answer is unchanged (the new keys appear only on enhancement recipes).
create or replace function public._craft_recipes_player(p_character uuid, p_recipe uuid default null)
returns table (recipe_id uuid, recipe_name text, j jsonb)
language sql stable security definer set search_path = public, pg_temp as $$
  with ch as (select c.id, c.campaign_id from public.characters c where c.id = p_character and c.campaign_id is not null),
  rc as (
    select r.*, kn.character_id is not null as learned, kn.seen_at as kn_seen
    from ch join public.crafting_recipes r on r.campaign_id = ch.campaign_id and r.status = 'published'
    left join public.character_known_recipes kn on kn.character_id = ch.id and kn.recipe_id = r.id
    where (p_recipe is null or r.id = p_recipe) and (r.visibility = 'known' or kn.character_id is not null)),
  rws as (
    select ii.id, ii.item_id, ii.quantity, coalesce(nullif(ii.custom_name, ''), ii.name) as nm,
           coalesce(not ii.is_attuned and not ii.is_quest_item
                    and not exists (select 1 from public.character_equipment e where e.inventory_item_id = ii.id)
                    and not exists (select 1 from public.inventory_items c where c.container_item_id = ii.id), false) as free
    from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
    where inv.character_id = p_character and inv.kind = 'character' and ii.item_id is not null
      and not exists (select 1 from public.inventory_item_knowledge k where k.inventory_item_id = ii.id and k.state <> 'identified')
      and exists (select 1 from rc)),
  lines as (select g.*, rc.enhance_modifier_id as emod from public.crafting_recipe_ingredients g join rc on rc.id = g.recipe_id),
  tag_pairs as (
    select distinct x.item_id, lower(btrim(t)) as tag
    from (select distinct w.item_id from rws w) x join public.items i on i.id = x.item_id
    cross join lateral jsonb_array_elements_text(case when jsonb_typeof(i.details -> 'ingredient_tags') = 'array'
                                                      then i.details -> 'ingredient_tags' else '[]'::jsonb end) t
    where exists (select 1 from lines l where l.ingredient_tag is not null)
      and public._craft_item_trusted(x.item_id, (select ch.campaign_id from ch))),
  cand as materialized (
    select g.id as gid, w.id, w.nm, w.quantity from lines g join rws w on w.item_id = g.item_id
     where g.item_id is not null and (not g.consumed or w.free) and (not g.is_base or public._craft_base_refusal(w.id, g.emod) is null)
    union all
    select g.id, w.id, w.nm, w.quantity from lines g join tag_pairs p on p.tag = g.ingredient_tag join rws w on w.item_id = p.item_id
     where g.item_id is null and (not g.consumed or w.free) and (not g.is_base or public._craft_base_refusal(w.id, g.emod) is null)),
  agg as materialized (
    select c.gid, sum(c.quantity)::int as have,
           jsonb_agg(jsonb_build_object('inventory_item_id', c.id, 'name', c.nm, 'quantity', c.quantity) order by c.nm, c.id) as list
    from cand c group by c.gid),
  known_items as materialized (
    select x.item_id, public._craft_item_known(p_character, x.item_id) as known
    from (select rc.output_item_id as item_id from rc where rc.output_item_id is not null
          union select l.item_id from lines l where l.item_id is not null) x),
  ings as materialized (
    select g.recipe_id, jsonb_agg(jsonb_build_object(
      'seq', g.seq, 'quantity', g.quantity, 'consumed', g.consumed, 'tag', g.ingredient_tag,
      'label', case when g.item_id is null then coalesce(nullif(btrim(g.label), ''), 'Any ingredient tagged “' || g.ingredient_tag || '”')
                    when ki.known then (select i.name from public.items i where i.id = g.item_id)
                    else coalesce(nullif(btrim(g.label), ''), 'An unknown ingredient') end,
      'item_id', case when g.item_id is not null and ki.known then g.item_id end,
      'have', coalesce(a.have, 0), 'candidates', coalesce(a.list, '[]'::jsonb))
      || case when g.is_base then '{"base": true}'::jsonb else '{}'::jsonb end order by g.seq) as list
    from lines g left join known_items ki on ki.item_id = g.item_id left join agg a on a.gid = g.id
    group by g.recipe_id)
  select rc.id, rc.name, jsonb_build_object(
    'recipe_id', rc.id, 'name', rc.name, 'description', rc.description, 'time_note', rc.time_note,
    'source', case when rc.learned then 'learned' else 'known' end,
    'new', rc.learned and rc.kn_seen is null,
    'output', case when rc.kind = 'enhancement' then
                jsonb_build_object('enhancement', true, 'quantity', 1, 'item_id', null, 'kind_id', null,
                                   'known', nullif(btrim(rc.output_label), '') is null,
                                   'name', coalesce(nullif(btrim(rc.output_label), ''), md.name),
                                   'description', case when nullif(btrim(rc.output_label), '') is null then md.description end,
                                   'effects', case when nullif(btrim(rc.output_label), '') is null then public._modifier_effects_json(md.id) else '[]'::jsonb end)
              else jsonb_build_object('name', case when ko.known then it.name
                                              else coalesce(nullif(btrim(rc.output_label), ''), (select d.name from public._item_decoy(rc.output_item_id) d)) end,
                                 'item_id', case when ko.known then it.id end, 'kind_id', case when ko.known then it.kind_id end,
                                 'quantity', rc.output_quantity, 'known', ko.known) end,
    'check', case when rc.check_key is not null then jsonb_build_object('key', rc.check_key, 'label', public._identify_check_label(rc.check_key),
                                                                         'dc', rc.check_dc) end,
    'tool', case when tl.tool is not null then jsonb_build_object('item_id', tl.tool, 'name', public._identify_check_label(tl.tool),
                                                                  'have', exists (select 1 from rws w where w.item_id = tl.tool)) end,
    'dm_confirms', rc.requires_dm_approval,
    'ingredients', coalesce(ig.list, '[]'::jsonb),
    'missing', (select coalesce(jsonb_agg(jsonb_build_object('seq', (e ->> 'seq')::int, 'label', e ->> 'label',
                                 'need', (e ->> 'quantity')::int - (e ->> 'have')::int) order by (e ->> 'seq')::int), '[]')
                from jsonb_array_elements(coalesce(ig.list, '[]'::jsonb)) e where (e ->> 'have')::int < (e ->> 'quantity')::int),
    'can_craft', not exists (select 1 from jsonb_array_elements(coalesce(ig.list, '[]'::jsonb)) e where (e ->> 'have')::int < (e ->> 'quantity')::int)
                 and (tl.tool is null or exists (select 1 from rws w where w.item_id = tl.tool)),
    'pending_attempt_id', (select a.id from public.crafting_attempts a where a.character_id = p_character and a.recipe_id = rc.id and a.status = 'pending'))
    || case when rc.kind = 'enhancement' then '{"kind": "enhancement"}'::jsonb else '{}'::jsonb end
  from rc
  left join public.items it on it.id = rc.output_item_id
  left join public.item_modifiers md on md.id = rc.enhance_modifier_id
  left join known_items ko on ko.item_id = rc.output_item_id
  left join ings ig on ig.recipe_id = rc.id
  cross join lateral (select public._craft_tool_item(rc.check_key) as tool) tl;
$$;

-- ---- 8. crafting paths -------------------------------------------------------------------------------------------------------------
-- body of 20261114000900 + enhancement: the base row is re-checked (TLCRF, fixed texts) and, on a success / critical success, the
-- modifier is attached to that same row (logged as apply_modifier with the attempt); a failure never touches the base
create or replace function public._craft_apply(p_attempt uuid, p_outcome text, p_failure_consumes text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare a public.crafting_attempts; r public.crafting_recipes; g public.crafting_recipe_ingredients; s jsonb; ir public.inventory_items;
  inv_char uuid; inv_kind text; q int; mode text; consumed jsonb := '[]'; produced jsonb := '[]'; meta jsonb; out_item text; out_qty int;
  covered int; base_row uuid; why text; mname text;
begin
  select * into a from public.crafting_attempts where id = p_attempt;
  select * into r from public.crafting_recipes where id = a.recipe_id;
  -- 20261114000900: the per-item locks before any row lock (the callers took them before their first write already)
  perform public._craft_lock_items(a.selected, r.id);
  if not exists (select 1 from public.characters c where c.id = a.character_id and c.campaign_id = r.campaign_id) then
    raise exception 'The character is no longer in this campaign' using errcode = 'TLCRF';
  end if;
  perform public._rpc_begin();
  perform 1 from public.inventory_items where id in (select (x ->> 'inventory_item_id')::uuid from jsonb_array_elements(a.selected) x)
    order by id for update;
  for g in select * from public.crafting_recipe_ingredients where recipe_id = r.id order by seq loop
    select coalesce(sum((x ->> 'quantity')::int), 0) into covered from jsonb_array_elements(a.selected) x where (x ->> 'seq')::int = g.seq;
    if covered <> g.quantity then raise exception 'The ingredients no longer fit the recipe (it was changed)' using errcode = 'TLCRF'; end if;
  end loop;
  for s in select x from jsonb_array_elements(a.selected) x loop
    select * into g from public.crafting_recipe_ingredients where recipe_id = r.id and seq = (s ->> 'seq')::int;
    select * into ir from public.inventory_items where id = (s ->> 'inventory_item_id')::uuid;
    select i.character_id, i.kind into inv_char, inv_kind from public.inventories i where i.id = ir.inventory_id;
    if g.id is null then raise exception 'The ingredients no longer fit the recipe (it was changed)' using errcode = 'TLCRF'; end if;
    if ir.id is null or inv_char is distinct from a.character_id or inv_kind <> 'character' or ir.quantity < (s ->> 'quantity')::int then
      raise exception 'Some ingredients are no longer in the inventory' using errcode = 'TLCRF';
    end if;
    if not public._craft_row_known(ir.id) or not public._craft_row_matches(ir.item_id, g) then
      raise exception 'Some ingredients changed since the attempt' using errcode = 'TLCRF';
    end if;
    if g.consumed and not public._craft_row_free(ir.id) then
      raise exception 'An ingredient is equipped, attuned, a quest item or a container with contents' using errcode = 'TLCRF';
    end if;
    -- 20261114001000: the base of an enhancement
    if g.is_base then
      if r.kind <> 'enhancement' then raise exception 'The ingredients no longer fit the recipe (it was changed)' using errcode = 'TLCRF'; end if;
      why := public._craft_base_refusal(ir.id, r.enhance_modifier_id);
      if why is not null then raise exception '%', why using errcode = 'TLCRF'; end if;
      base_row := ir.id;
    end if;
  end loop;
  if r.kind = 'enhancement' and base_row is null then
    raise exception 'The ingredients no longer fit the recipe (it was changed)' using errcode = 'TLCRF';
  end if;
  if not public._craft_tool_ok(a.character_id, r.check_key) then
    raise exception 'The tool for this recipe is no longer in the inventory' using errcode = 'TLCRF';
  end if;

  mode := case when p_outcome in ('success', 'critical_success') then 'lose_all'
               when p_outcome = 'critical_failure' then 'lose_all'
               else coalesce(p_failure_consumes, r.failure_mode) end;
  meta := jsonb_build_object('craft_attempt', a.id, 'recipe', r.id, 'outcome', p_outcome);
  for s in select x from jsonb_array_elements(a.selected) x order by (x ->> 'inventory_item_id') loop
    select * into g from public.crafting_recipe_ingredients where recipe_id = r.id and seq = (s ->> 'seq')::int;
    continue when not g.consumed;
    q := case mode when 'lose_all' then (s ->> 'quantity')::int when 'lose_half' then (s ->> 'quantity')::int / 2 else 0 end;
    continue when q < 1;
    select * into ir from public.inventory_items where id = (s ->> 'inventory_item_id')::uuid;
    if q = ir.quantity then delete from public.inventory_items where id = ir.id;
    else update public.inventory_items set quantity = quantity - q where id = ir.id; end if;
    perform public.log_inventory_event(ir.inventory_id, case when q = ir.quantity then null else ir.id end, 'remove', -q, ir.item_id,
      meta || jsonb_build_object('previous_quantity', ir.quantity, 'deleted', q = ir.quantity, 'name', coalesce(nullif(ir.custom_name, ''), ir.name)));
    consumed := consumed || jsonb_build_array(jsonb_build_object('inventory_item_id', ir.id, 'item_id', ir.item_id,
      'name', coalesce(nullif(ir.custom_name, ''), ir.name), 'quantity', q));
  end loop;
  if r.kind = 'enhancement' then
    -- success and critical success attach the enhancement to the base row itself (a critical success has success semantics)
    if p_outcome in ('success', 'critical_success') then
      select * into ir from public.inventory_items where id = base_row;
      select name into mname from public.item_modifiers where id = r.enhance_modifier_id;
      insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (base_row, r.enhance_modifier_id);
      perform public.log_inventory_event(ir.inventory_id, ir.id, 'apply_modifier', null, ir.item_id,
        meta || jsonb_build_object('modifier_id', r.enhance_modifier_id, 'via', 'craft', 'name', coalesce(nullif(ir.custom_name, ''), ir.name)));
      produced := jsonb_build_array(jsonb_build_object('inventory_item_id', ir.id, 'item_id', ir.item_id,
        'name', coalesce(nullif(ir.custom_name, ''), ir.name) || ' (' || mname || ')', 'quantity', 1, 'identified', true,
        'enhanced', true, 'modifier_id', r.enhance_modifier_id));
    end if;
    out_item := case when p_outcome in ('success', 'critical_success') then null else r.failure_output_item_id end;
    out_qty := r.failure_output_quantity;
  elsif p_outcome in ('success', 'critical_success') then
    out_item := case when p_outcome = 'critical_success' then coalesce(r.crit_output_item_id, r.output_item_id) else r.output_item_id end;
    out_qty := r.output_quantity + case when p_outcome = 'critical_success' then r.crit_bonus_quantity else 0 end;
  else
    out_item := r.failure_output_item_id;
    out_qty := r.failure_output_quantity;
  end if;
  if out_item is not null then
    produced := produced || jsonb_build_array(public._craft_produce(a.inventory_id, a.character_id, out_item, out_qty, r.output_identified, meta));
  end if;
  perform public._rpc_end();
  return jsonb_build_object('consumed', consumed, 'produced', produced);
end $$;

-- body of 20261114000900 + m3 (a natural roll needs a check) + the base of an enhancement (checked after the knowledge rule)
create or replace function public.start_craft_attempt(p_character uuid, p_recipe uuid, p_selected jsonb, p_roll_total int default null,
                                           p_request_id uuid default null, p_natural text default null, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare ch public.characters; rc public.crafting_recipes; a public.crafting_attempts; inv uuid; s jsonb; g public.crafting_recipe_ingredients;
  ir public.inventory_items; norm jsonb := '[]'; ids uuid[] := '{}'; covered int; res jsonb; inv_char uuid; inv_kind text; q int; why text;
begin
  if p_request_id is null then raise exception 'A request id is required' using errcode = '22023'; end if;
  ch := public._craft_player_gate(p_character);
  select * into a from public.crafting_attempts where character_id = ch.id and request_id = p_request_id;
  if a.id is not null then return public._craft_attempt_player(a) || jsonb_build_object('replayed', true); end if;
  select * into rc from public.crafting_recipes where id = p_recipe;
  if not public._craft_recipe_visible(ch.id, p_recipe) then raise exception 'Recipe not found' using errcode = 'P0002'; end if;
  -- 20261114001000 (review m3): a natural 20 / 1 belongs to a roll; a recipe without a check has none (refused, never stored)
  if p_natural is not null and rc.check_key is null then raise exception 'This recipe has no roll' using errcode = '22023'; end if;
  select id into inv from public.inventories where character_id = ch.id and kind = 'character' order by created_at limit 1;
  if inv is null then raise exception 'The character has no inventory' using errcode = '22023'; end if;

  if p_selected is null or jsonb_typeof(p_selected) <> 'array' or jsonb_array_length(p_selected) = 0 or jsonb_array_length(p_selected) > 40 then
    raise exception 'Choose the items to use' using errcode = '22023';
  end if;
  for s in select x from jsonb_array_elements(p_selected) x loop
    if jsonb_typeof(s) <> 'object' or coalesce(s ->> 'seq', '') !~ '^\d{1,2}$' or coalesce(s ->> 'quantity', '') !~ '^\d{1,3}$'
       or coalesce(s ->> 'inventory_item_id', '') !~ '^[0-9a-fA-F-]{36}$' or (s ->> 'quantity')::int < 1 then
      raise exception 'Choose the items to use' using errcode = '22023';
    end if;
    select * into ir from public.inventory_items where id = (s ->> 'inventory_item_id')::uuid;
    select i.character_id, i.kind into inv_char, inv_kind from public.inventories i where i.id = ir.inventory_id;
    if ir.id is null or inv_char is distinct from ch.id or inv_kind <> 'character' then
      raise exception 'Choose items from this character''s inventory' using errcode = '22023';
    end if;
    if ir.id = any (ids) then raise exception 'Use each stack for one ingredient only' using errcode = '22023'; end if;
    ids := ids || ir.id;
    norm := norm || jsonb_build_array(jsonb_build_object('seq', (s ->> 'seq')::int, 'inventory_item_id', ir.id, 'quantity', (s ->> 'quantity')::int));
  end loop;
  -- knowledge FIRST, for every selected row (the base too), with one fixed message (it never says "matches" or "does not match")
  if exists (select 1 from unnest(ids) x where not public._craft_row_known(x)) then
    raise exception 'You don''t know what this ingredient is yet' using errcode = '22023';
  end if;
  for s in select x from jsonb_array_elements(norm) x loop
    select * into g from public.crafting_recipe_ingredients where recipe_id = rc.id and seq = (s ->> 'seq')::int;
    select * into ir from public.inventory_items where id = (s ->> 'inventory_item_id')::uuid;
    q := (s ->> 'quantity')::int;
    if g.id is null or not public._craft_row_matches(ir.item_id, g) then raise exception 'This item does not fit that ingredient' using errcode = '22023'; end if;
    if q > ir.quantity then raise exception 'Not enough items in that stack' using errcode = '22023'; end if;
    if g.consumed and not public._craft_row_free(ir.id) then
      raise exception 'Equipped, attuned or quest items and containers with contents cannot be used up' using errcode = '22023';
    end if;
    -- 20261114001000: the base of an enhancement (kept): a single item that can take the enhancement
    if g.is_base then
      why := public._craft_base_refusal(ir.id, rc.enhance_modifier_id);
      if why is not null then raise exception '%', why using errcode = '22023'; end if;
    end if;
  end loop;
  for g in select * from public.crafting_recipe_ingredients where recipe_id = rc.id order by seq loop
    select coalesce(sum((x ->> 'quantity')::int), 0) into covered from jsonb_array_elements(norm) x where (x ->> 'seq')::int = g.seq;
    if covered <> g.quantity then raise exception 'Choose exactly what the recipe needs for each ingredient' using errcode = '22023'; end if;
  end loop;
  -- 20261114000900: the tool the check needs must be carried (a known row)
  if not public._craft_tool_ok(ch.id, rc.check_key) then
    raise exception 'You need % for this recipe', public._identify_check_label(rc.check_key) using errcode = '22023';
  end if;
  if rc.check_key is not null and (p_roll_total is null or p_roll_total < -10 or p_roll_total > 60) then
    raise exception 'Enter the total of your roll (-10 to 60)' using errcode = '22023';
  end if;
  if p_roll_total is not null and (p_roll_total < -10 or p_roll_total > 60) then raise exception 'Roll out of range' using errcode = '22023'; end if;
  if p_natural is not null and p_natural not in ('nat20', 'nat1') then raise exception 'Natural roll: nat20 or nat1' using errcode = '22023'; end if;
  if exists (select 1 from public.crafting_attempts x where x.character_id = ch.id and x.recipe_id = rc.id and x.status = 'pending') then
    raise exception 'Your DM has not answered your last attempt at this recipe yet' using errcode = '55000';
  end if;
  -- 20261114000900: the auto path changes inventory rows -> the per-item locks before the first write (the insert below bumps the
  -- character cache counter, which a transfer holding 4242 also wants)
  if not rc.requires_dm_approval and rc.check_dc is null then
    perform public._craft_lock_items(norm, rc.id);
  end if;

  begin
    insert into public.crafting_attempts (character_id, recipe_id, recipe_revision, inventory_id, selected, roll_total, natural_roll,
                                          player_note, request_id, auto)
    values (ch.id, rc.id, rc.revision, inv, norm, p_roll_total, p_natural, nullif(left(btrim(coalesce(p_note, '')), 500), ''), p_request_id,
            not rc.requires_dm_approval and rc.check_dc is null)
    on conflict (character_id, request_id) do nothing
    returning * into a;
  exception when unique_violation then
    raise exception 'Your DM has not answered your last attempt at this recipe yet' using errcode = '55000';
  end;
  if a.id is null then
    select * into a from public.crafting_attempts where character_id = ch.id and request_id = p_request_id;
    return public._craft_attempt_player(a) || jsonb_build_object('replayed', true);
  end if;
  if a.auto then
    res := public._craft_apply(a.id, 'success', null);
    update public.crafting_attempts set status = 'applied', outcome = 'success', consumed = res -> 'consumed', produced = res -> 'produced',
           resolved_at = now(), revision = revision + 1 where id = a.id returning * into a;
  end if;
  perform public._craft_audit(a);
  perform public._identify_touch(ch.id);
  return public._craft_attempt_player(a);
end $$;

-- ---- 9. DM side ------------------------------------------------------------------------------------------------------------------
-- body of 20261114000900 + the enhancement and the base line
create or replace function public._craft_recipe_dm(p_recipe uuid)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select to_jsonb(r) || jsonb_build_object(
    'output_name', (select name from public.items where id = r.output_item_id),
    'output_secret', (select secret from public.items where id = r.output_item_id),
    'crit_output_name', (select name from public.items where id = r.crit_output_item_id),
    'failure_output_name', (select name from public.items where id = r.failure_output_item_id),
    'enhance_modifier_name', (select name from public.item_modifiers where id = r.enhance_modifier_id),
    'enhance_effects', case when r.enhance_modifier_id is not null then public._modifier_effects_json(r.enhance_modifier_id) end,
    'check_label', case when r.check_key is not null then public._identify_check_label(r.check_key) end,
    'tool_item_id', public._craft_tool_item(r.check_key),
    'ingredients', (select coalesce(jsonb_agg(jsonb_build_object('seq', g.seq, 'item_id', g.item_id, 'item_name', i.name, 'item_secret', i.secret,
                       'tag', g.ingredient_tag, 'label', g.label, 'quantity', g.quantity, 'consumed', g.consumed, 'base', g.is_base) order by g.seq), '[]')
                    from public.crafting_recipe_ingredients g left join public.items i on i.id = g.item_id where g.recipe_id = r.id),
    'teachers', (select coalesce(jsonb_agg(jsonb_build_object('item_id', t.item_id, 'item_name', i.name, 'kind_id', i.kind_id,
                       'consume_on_learn', t.consume_on_learn) order by i.name, t.item_id), '[]')
                 from public.crafting_recipe_teachers t join public.items i on i.id = t.item_id where t.recipe_id = r.id),
    'known_by', (select coalesce(jsonb_agg(jsonb_build_object('character_id', k.character_id, 'name', c.name, 'seen', k.seen_at is not null,
                       'source', k.source) order by c.name), '[]')
                 from public.character_known_recipes k join public.characters c on c.id = k.character_id where k.recipe_id = r.id),
    'pending', (select count(*) from public.crafting_attempts a where a.recipe_id = r.id and a.status in ('pending', 'apply_failed')),
    'attempts', (select count(*) from public.crafting_attempts a where a.recipe_id = r.id))
  from public.crafting_recipes r where r.id = p_recipe;
$$;

-- body of 20261113000100 + the campaign's modifiers (for the editor)
create or replace function public.get_campaign_recipes(p_campaign uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform public._craft_dm_gate(p_campaign);
  return jsonb_build_object(
    'campaign_id', p_campaign,
    'enabled', public._gov_policy(p_campaign, 'inventory.craft'),
    'recipes', (select coalesce(jsonb_agg(public._craft_recipe_dm(r.id) order by (r.status = 'archived'), r.name, r.id), '[]')
                from public.crafting_recipes r where r.campaign_id = p_campaign),
    'characters', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name, c.id), '[]')
                   from public.characters c where c.campaign_id = p_campaign),
    'modifiers', (select coalesce(jsonb_agg(public._craft_modifier_dm(m.id) order by m.name, m.id), '[]')
                  from public.item_modifiers m where m.campaign_id = p_campaign and public._craft_modifier_ok(m.id, p_campaign)));
end $$;

-- body of 20261113000100 + an enhancement recipe needs its modifier (instead of a result item)
create or replace function public.dm_set_recipe_status(p_recipe uuid, p_status text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.crafting_recipes;
begin
  select * into r from public.crafting_recipes where id = p_recipe for update;
  if r.id is null then raise exception 'Recipe not found' using errcode = 'P0002'; end if;
  perform public._craft_dm_gate(r.campaign_id);
  if p_status not in ('draft', 'published', 'archived') then raise exception 'Unknown status' using errcode = '22023'; end if;
  if p_status = 'published' and ((r.kind = 'item' and not public._craft_item_ok(r.output_item_id, r.campaign_id))
      or (r.kind = 'enhancement' and not public._craft_modifier_ok(r.enhance_modifier_id, r.campaign_id))
      or exists (select 1 from public.crafting_recipe_ingredients g where g.recipe_id = r.id and g.item_id is not null
                 and not public._craft_item_ok(g.item_id, r.campaign_id))) then
    raise exception 'An item of this recipe is archived or not available in the campaign' using errcode = '22023';
  end if;
  -- results that arrive unidentified leave the players' catalog now (a DM action), never at a player's first craft
  if p_status = 'published' and not r.output_identified then
    update public.items set secret = true where id in (r.output_item_id, r.crit_output_item_id, r.failure_output_item_id)
      and owner_id is not null and not secret;
  end if;
  if r.status <> p_status then
    update public.crafting_recipes set status = p_status, revision = revision + 1, updated_by = auth.uid(), updated_at = now() where id = r.id;
    perform public._audit(r.campaign_id, null, 'recipe_changed', 'Crafting recipe ' || r.name || ': ' || p_status, null,
                          jsonb_build_object('recipe_id', r.id, 'status', p_status), null, null, 'dm');
  end if;
  return public._craft_recipe_dm(r.id);
end $$;

-- body of 20261114000900 + kind 'enhancement' (enhance_modifier_id; one base ingredient line {base: true}, kept, quantity 1;
-- no result item, no critical result) + m4 (recipe items: campaign items only)
create or replace function public.dm_save_recipe(p_campaign uuid, p_recipe jsonb, p_expected_revision int default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare o jsonb := coalesce(p_recipe, '{}'); r public.crafting_recipes; rid uuid; g jsonb; n int := 0; dc int; key text; out_item text;
  crit text; fail text; ident boolean; ing_item text; ing_tag text; qty int; t_item text; knd text; emod text; bases int := 0; is_b boolean;
begin
  perform public._craft_dm_gate(p_campaign);
  if jsonb_typeof(o) <> 'object' then raise exception 'The recipe must be an object' using errcode = '22023'; end if;
  if nullif(o ->> 'id', '') is not null then
    select * into r from public.crafting_recipes where id = (o ->> 'id')::uuid for update;
    if r.id is null or r.campaign_id <> p_campaign then raise exception 'Recipe not found' using errcode = 'P0002'; end if;
    if r.status = 'archived' then raise exception 'Restore the recipe before changing it' using errcode = '55000'; end if;
    if p_expected_revision is not null and p_expected_revision <> r.revision then
      raise exception 'Someone else changed this recipe meanwhile. Reload and try again.' using errcode = '40001';
    end if;
  end if;
  if length(btrim(coalesce(o ->> 'name', ''))) not between 1 and 120 then raise exception 'Give the recipe a name (up to 120 characters)' using errcode = '22023'; end if;
  knd := coalesce(nullif(o ->> 'kind', ''), r.kind, 'item');
  if knd not in ('item', 'enhancement') then raise exception 'A recipe makes an item or an enhancement' using errcode = '22023'; end if;
  if r.id is not null and knd <> r.kind and exists (select 1 from public.crafting_attempts a where a.recipe_id = r.id) then
    raise exception 'This recipe has attempts: make a new recipe instead of changing what it makes' using errcode = '55000';
  end if;
  out_item := nullif(btrim(coalesce(o ->> 'output_item_id', '')), '');
  crit := nullif(btrim(coalesce(o ->> 'crit_output_item_id', '')), '');
  fail := nullif(btrim(coalesce(o ->> 'failure_output_item_id', '')), '');
  emod := nullif(btrim(coalesce(o ->> 'enhance_modifier_id', '')), '');
  if knd = 'enhancement' then
    if emod is null or not public._craft_modifier_ok(emod, p_campaign) then
      raise exception 'Choose an enhancement of this campaign' using errcode = '22023';
    end if;
    if out_item is not null or crit is not null then
      raise exception 'An enhancement recipe changes the base item; it makes no other item' using errcode = '22023';
    end if;
  else
    if emod is not null then raise exception 'Only an enhancement recipe attaches an enhancement' using errcode = '22023'; end if;
    if out_item is null then raise exception 'Choose what the recipe makes' using errcode = '22023'; end if;
  end if;
  if (out_item is not null and not public._craft_item_ok(out_item, p_campaign)) or (crit is not null and not public._craft_item_ok(crit, p_campaign))
     or (fail is not null and not public._craft_item_ok(fail, p_campaign)) then
    raise exception 'Choose an official item or an item of this campaign (not archived)' using errcode = '22023';
  end if;
  ident := knd = 'enhancement' or coalesce((o ->> 'output_identified')::boolean, true);
  if not ident and exists (select 1 from public.items i where i.id = out_item and i.owner_id is null) then
    raise exception 'Copy an official item to campaign homebrew before its result can arrive unidentified' using errcode = '22023';
  end if;
  key := nullif(lower(btrim(coalesce(o ->> 'check_key', ''))), '');
  if key is not null and length(key) > 60 then raise exception 'Check name too long' using errcode = '22023'; end if;
  if jsonb_typeof(o -> 'check_dc') = 'number' then dc := (o ->> 'check_dc')::numeric::int;
  elsif nullif(o ->> 'check_dc', '') is not null then raise exception 'The DC must be a number from 1 to 40' using errcode = '22023'; end if;
  if dc is not null and dc not between 1 and 40 then raise exception 'The DC must be a number from 1 to 40' using errcode = '22023'; end if;
  if dc is not null and key is null then raise exception 'A DC needs a skill or tool to roll' using errcode = '22023'; end if;
  if dc is not null and not coalesce((o ->> 'requires_dm_approval')::boolean, true) then
    raise exception 'A recipe with a DC always needs your approval' using errcode = '22023';
  end if;
  if coalesce(o ->> 'visibility', 'known') not in ('known', 'discoverable', 'secret') then raise exception 'Unknown visibility' using errcode = '22023'; end if;
  if coalesce(o ->> 'failure_mode', 'keep') not in ('keep', 'lose_all', 'lose_half') then raise exception 'Unknown failure rule' using errcode = '22023'; end if;
  if jsonb_typeof(o -> 'ingredients') <> 'array' or jsonb_array_length(o -> 'ingredients') not between 1 and 20 then
    raise exception 'A recipe needs 1 to 20 ingredients' using errcode = '22023';
  end if;
  for g in select x from jsonb_array_elements(o -> 'ingredients') x loop
    ing_item := nullif(btrim(coalesce(g ->> 'item_id', '')), '');
    ing_tag := nullif(lower(btrim(coalesce(g ->> 'tag', ''))), '');
    if num_nonnulls(ing_item, ing_tag) <> 1 then raise exception 'Each ingredient is an item or a tag' using errcode = '22023'; end if;
    if ing_item is not null and not public._craft_item_ok(ing_item, p_campaign) then
      raise exception 'Choose an official item or an item of this campaign (not archived)' using errcode = '22023';
    end if;
    if ing_tag is not null and ing_tag !~ '^[a-z0-9][a-z0-9 _-]{0,39}$' then raise exception 'Tags use letters, digits, spaces, - and _ (up to 40)' using errcode = '22023'; end if;
    if coalesce(g ->> 'quantity', '1') !~ '^\d{1,2}$' or coalesce((g ->> 'quantity')::int, 1) not between 1 and 99 then
      raise exception 'Ingredient quantity 1 to 99' using errcode = '22023';
    end if;
    -- 20261114001000: the base line of an enhancement recipe
    if jsonb_typeof(g -> 'base') not in ('boolean', 'null') and g ? 'base' then raise exception 'Base: true or false' using errcode = '22023'; end if;
    is_b := coalesce(case when jsonb_typeof(g -> 'base') = 'boolean' then (g ->> 'base')::boolean end, false);
    if is_b then
      bases := bases + 1;
      if knd <> 'enhancement' then raise exception 'Only an enhancement recipe has a base item' using errcode = '22023'; end if;
      if coalesce((g ->> 'quantity')::int, 1) <> 1 then raise exception 'The base item is a single item (quantity 1)' using errcode = '22023'; end if;
      if coalesce((g ->> 'consumed')::boolean, false) then raise exception 'The base item is kept (it is what gets the enhancement)' using errcode = '22023'; end if;
      if ing_item is not null and exists (
           select 1 from public.items i join public.item_modifiers m on m.id = emod
           where i.id = ing_item and ((m.applies_to_kind_id is not null and m.applies_to_kind_id <> i.kind_id)
             or (exists (select 1 from public.item_modifier_categories c where c.modifier_id = m.id)
                 and not exists (select 1 from public.item_modifier_categories c where c.modifier_id = m.id and c.category_id = i.category_id)))) then
        raise exception 'This enhancement does not fit the base item' using errcode = '22023';
      end if;
    end if;
  end loop;
  if knd = 'enhancement' and bases <> 1 then raise exception 'Mark exactly one ingredient as the base item (the item that gets the enhancement)' using errcode = '22023'; end if;
  -- 20261114000900: recipe items
  if o ? 'teachers' then
    if jsonb_typeof(o -> 'teachers') <> 'array' or jsonb_array_length(o -> 'teachers') > 10 then
      raise exception 'Up to 10 recipe items' using errcode = '22023';
    end if;
    for g in select x from jsonb_array_elements(o -> 'teachers') x loop
      t_item := nullif(btrim(coalesce(g ->> 'item_id', '')), '');
      -- 20261114001000 (review m4): campaign items only (DM content or a DM's campaign homebrew), never an official catalog item
      if t_item is null or not public._craft_teacher_ok(t_item, p_campaign) then
        raise exception 'A recipe item must be an item of this campaign (DM content or your campaign homebrew, not archived), not an official catalog item'
          using errcode = '22023';
      end if;
      if jsonb_typeof(g -> 'consumed') not in ('boolean', 'null') and g ? 'consumed' then
        raise exception 'Used up when read: true, false or empty' using errcode = '22023';
      end if;
    end loop;
  end if;

  if r.id is null then
    insert into public.crafting_recipes (campaign_id, name, kind, output_item_id, enhance_modifier_id, updated_by)
    values (p_campaign, btrim(o ->> 'name'), knd, out_item, emod, auth.uid())
    returning * into r;
  end if;
  update public.crafting_recipes set
    name = btrim(o ->> 'name'), description = left(coalesce(o ->> 'description', ''), 2000),
    dm_notes = nullif(left(coalesce(o ->> 'dm_notes', ''), 2000), ''),
    visibility = coalesce(o ->> 'visibility', 'known'), kind = knd, output_item_id = out_item, enhance_modifier_id = emod,
    output_quantity = case when knd = 'enhancement' then 1 else least(greatest(coalesce((o ->> 'output_quantity')::int, 1), 1), 99) end,
    output_label = nullif(left(btrim(coalesce(o ->> 'output_label', '')), 120), ''), output_identified = ident,
    crit_output_item_id = crit,
    crit_bonus_quantity = case when knd = 'enhancement' then 0 else least(greatest(coalesce((o ->> 'crit_bonus_quantity')::int, 0), 0), 99) end,
    failure_mode = coalesce(o ->> 'failure_mode', 'keep'), failure_output_item_id = fail,
    failure_output_quantity = least(greatest(coalesce((o ->> 'failure_output_quantity')::int, 1), 1), 99),
    check_key = key, check_dc = dc, requires_dm_approval = dc is not null or coalesce((o ->> 'requires_dm_approval')::boolean, true),
    time_note = nullif(left(btrim(coalesce(o ->> 'time_note', '')), 200), ''),
    revision = case when nullif(o ->> 'id', '') is null then 1 else revision + 1 end, updated_by = auth.uid(), updated_at = now()
  where id = r.id returning * into r;
  delete from public.crafting_recipe_ingredients where recipe_id = r.id;
  for g in select x from jsonb_array_elements(o -> 'ingredients') x loop
    n := n + 1;
    qty := coalesce((g ->> 'quantity')::int, 1);
    is_b := coalesce(case when jsonb_typeof(g -> 'base') = 'boolean' then (g ->> 'base')::boolean end, false);
    insert into public.crafting_recipe_ingredients (recipe_id, seq, item_id, ingredient_tag, label, quantity, consumed, is_base)
    values (r.id, n, nullif(btrim(coalesce(g ->> 'item_id', '')), ''), nullif(lower(btrim(coalesce(g ->> 'tag', ''))), ''),
            nullif(left(btrim(coalesce(g ->> 'label', '')), 120), ''), qty, case when is_b then false else coalesce((g ->> 'consumed')::boolean, true) end, is_b);
  end loop;
  if o ? 'teachers' then
    delete from public.crafting_recipe_teachers where recipe_id = r.id;   -- links only (DM data of this recipe; no item, no row)
    insert into public.crafting_recipe_teachers (recipe_id, item_id, consume_on_learn)
    select distinct on (btrim(x ->> 'item_id')) r.id, btrim(x ->> 'item_id'),
           coalesce(case when jsonb_typeof(x -> 'consumed') = 'boolean' then (x ->> 'consumed')::boolean end,
                    (select i.kind_id = 'scroll' from public.items i where i.id = btrim(x ->> 'item_id')), false)
    from jsonb_array_elements(o -> 'teachers') x;
  end if;
  if r.status = 'published' and not r.output_identified then
    update public.items set secret = true where id in (r.output_item_id, r.crit_output_item_id, r.failure_output_item_id)
      and owner_id is not null and not secret;
  end if;
  return public._craft_recipe_dm(r.id);
end $$;

-- ---- 10. grants ----------------------------------------------------------------------------------------------------------------
revoke all on function public._craft_modifier_ok(text, uuid), public._modifier_effects_json(text), public._craft_modifier_dm(text),
  public._craft_base_refusal(uuid, text), public._craft_teacher_ok(text, uuid) from public, anon, authenticated;
revoke all on function public.dm_save_campaign_modifier(uuid, jsonb) from public, anon;
grant execute on function public.dm_save_campaign_modifier(uuid, jsonb) to authenticated, service_role;

reset lock_timeout;
