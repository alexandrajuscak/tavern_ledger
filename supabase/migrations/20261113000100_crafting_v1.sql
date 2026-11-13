-- =============================================================================
-- Crafting v1 (docs/CRAFTING_V1.md). OFF everywhere until a DM turns it on per campaign:
-- * frontend flag CRAFTING ('off' | 'dm' | 'on', js/config.js; shipped 'off');
-- * governance action inventory.craft: 'disabled' in every preset (max_player = player_managed, can_request = false). A DM opens it
--   per campaign in Campaign rules (custom). Every player RPC below calls _gov_gate(character, 'inventory.craft') (TLDIS while off)
--   and checks the character's owner itself (_gov_decide answers 'allow' for non-owners and characters without a campaign).
--   The DM recipe RPCs need the campaign DM role only (a DM prepares recipes while players are still off: CRAFTING = 'dm').
-- Model: separate recipe tables (crafting_recipes, crafting_recipe_ingredients), recipe discovery per character
-- (character_known_recipes), and attempts with their own state machine (crafting_attempts):
--   start -> applied (auto: no DC and requires_dm_approval = false; consumed and produced in the same transaction)
--   start -> pending -> DM approve (edited roll, outcome) -> applied | apply_failed (-> DM approve again = retry, or reject)
--                    -> DM reject -> rejected (nothing changes)        -> player cancel -> cancelled
--   The server never rolls dice: the player enters the total of a physical roll, the DM confirms or corrects it.
--   Pending attempts reserve nothing: _craft_apply locks the attempt row, then the selected rows (id order), and re-checks them.
-- Audit: the existing inventory_events actions 'remove' / 'add' with metadata.craft_attempt (the CHECK constraint is unchanged);
-- the attempt keeps consumed / produced.
-- Knowledge (T4 / T4b): only rows the character fully knows count as ingredients (_craft_row_known = the masking predicate of
-- v_inventory_detail). Player reads never say whether an unidentified row matches; start_craft_attempt refuses any unidentified
-- selected row with ONE fixed message before any other check of the selection; a secret item the character does not know is
-- shown as the DM's label (never its name or id); a produced item arrives like a DM assignment (identified, or disguised and
-- INSERTED with the decoy so the Realtime INSERT never carries the true name).
-- Cache: crafting_recipes / crafting_recipe_ingredients -> tl_cache.skip() (no cached character read reads them: the reads of
-- get_character_reads' _CACHEABLE list never touch these new tables); character_known_recipes / crafting_attempts carry
-- character_id -> tl_cache.bump('character'). Not in the Realtime publication: the player's open sheet refreshes through a
-- character_revisions row with source 'inventory_items' (_identify_touch), which every frontend already handles.
-- Deletion: recipes reference items (no action = restrict for a direct delete); _item_dependencies, preview_item_deletion,
-- _dm_content_dependencies and get_dm_content_usage_detail (bodies of 20261112000100 + the marked additions) report
-- "crafting recipe X" instead of a raw foreign-key error.
-- Rollback: supabase/rollback/rollback_crafting_v1.sql.
-- =============================================================================

-- ---- 1. governance action (disabled in every preset) ---------------------------------------------------------------------
insert into public.governance_actions (action_key, category, lock_class, relaxed, standard, strict, max_player, can_request, sort_order, label, description)
values ('inventory.craft', 'inventory', 'inventory_acquire', 'disabled', 'disabled', 'disabled', 'player_managed', false, 71, 'Crafting',
        'Players craft items from your recipes (DM Space, Crafting). Off until you turn it on.')
on conflict (action_key) do nothing;

-- ---- 2. tables ------------------------------------------------------------------------------------------------------------
create table public.crafting_recipes (
  id                      uuid primary key default gen_random_uuid(),
  campaign_id             uuid not null references public.campaigns (id) on delete cascade,
  name                    text not null check (length(btrim(name)) between 1 and 120),
  description             text not null default '' check (length(description) <= 2000),     -- player-visible
  dm_notes                text check (length(dm_notes) <= 2000),                            -- DM only
  status                  text not null default 'draft' check (status in ('draft', 'published', 'archived')),
  visibility              text not null default 'known' check (visibility in ('known', 'discoverable', 'secret')),
  output_item_id          text not null references public.items (id),
  output_quantity         int not null default 1 check (output_quantity between 1 and 99),
  output_label            text check (length(output_label) <= 120),   -- shown while the result is unknown to the character
  output_identified       boolean not null default true,               -- false: the result arrives disguised (like a DM assignment)
  crit_output_item_id     text references public.items (id),           -- critical success: another result (null: the normal one)
  crit_bonus_quantity     int not null default 0 check (crit_bonus_quantity between 0 and 99),
  failure_mode            text not null default 'keep' check (failure_mode in ('keep', 'lose_all', 'lose_half')),
  failure_output_item_id  text references public.items (id),           -- failure flavour (a harmless junk item)
  failure_output_quantity int not null default 1 check (failure_output_quantity between 1 and 99),
  check_key               text check (length(check_key) between 1 and 60),   -- skill / tool id (nature, herbalism-kit, ...)
  check_dc                int check (check_dc between 1 and 40),             -- DM only
  requires_dm_approval    boolean not null default true,
  time_note               text check (length(time_note) <= 200),
  revision                int not null default 1,
  created_by              uuid references public.profiles (id) on delete set null default auth.uid(),
  updated_by              uuid references public.profiles (id) on delete set null,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  check (check_dc is null or check_key is not null),        -- a DC needs a skill or tool
  check (requires_dm_approval or check_dc is null)          -- auto-approve only for recipes without a DC
);
create index crafting_recipes_campaign on public.crafting_recipes (campaign_id, status);
create index crafting_recipes_output on public.crafting_recipes (output_item_id);

create table public.crafting_recipe_ingredients (
  id             uuid primary key default gen_random_uuid(),
  recipe_id      uuid not null references public.crafting_recipes (id) on delete cascade,
  seq            int not null check (seq between 1 and 20),
  item_id        text references public.items (id),                        -- an exact item, or:
  ingredient_tag text check (ingredient_tag ~ '^[a-z0-9][a-z0-9 _-]{0,39}$'),   -- matches items.details.ingredient_tags
  label          text check (length(label) <= 120),                        -- player-facing label (e.g. for a secret item)
  quantity       int not null default 1 check (quantity between 1 and 99),
  consumed       boolean not null default true,                            -- false: a tool / reusable
  check (num_nonnulls(item_id, ingredient_tag) = 1),
  unique (recipe_id, seq)
);
create index crafting_recipe_ingredients_item on public.crafting_recipe_ingredients (item_id) where item_id is not null;

create table public.character_known_recipes (
  character_id uuid not null references public.characters (id) on delete cascade,
  recipe_id    uuid not null references public.crafting_recipes (id) on delete cascade,
  source       text not null default 'dm' check (source in ('dm', 'experiment')),
  granted_by   uuid references public.profiles (id) on delete set null,
  learned_at   timestamptz not null default now(),
  seen_at      timestamptz,                                               -- null: "New recipe learned!"
  primary key (character_id, recipe_id)
);
create index character_known_recipes_recipe on public.character_known_recipes (recipe_id);

create table public.crafting_attempts (
  id               uuid primary key default gen_random_uuid(),
  character_id     uuid not null references public.characters (id) on delete cascade,
  recipe_id        uuid not null references public.crafting_recipes (id) on delete cascade,
  recipe_revision  int not null,
  inventory_id     uuid not null references public.inventories (id) on delete cascade,
  selected         jsonb not null,                                     -- [{seq, inventory_item_id, quantity}]
  roll_total       int check (roll_total between -10 and 60),
  natural_roll     text check (natural_roll in ('nat20', 'nat1')),          -- typed by the player; the server never rolls
  dm_roll_total    int check (dm_roll_total between -10 and 60),
  status           text not null default 'pending' check (status in ('pending', 'rejected', 'cancelled', 'applied', 'apply_failed')),
  outcome          text check (outcome in ('success', 'failure', 'critical_success', 'critical_failure')),
  failure_consumes text check (failure_consumes in ('keep', 'lose_all', 'lose_half')),
  consumed         jsonb,                                              -- [{inventory_item_id, item_id, name, quantity}]
  produced         jsonb,                                              -- [{inventory_item_id, item_id, name, quantity, identified}]
  apply_error      text check (length(apply_error) <= 300),
  player_note      text check (length(player_note) <= 500),
  dm_reply         text check (length(dm_reply) <= 500),               -- shown to the player
  dm_private_note  text check (length(dm_private_note) <= 500),        -- DM only
  auto             boolean not null default false,
  request_id       uuid not null,
  created_by       uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at       timestamptz not null default now(),
  resolved_at      timestamptz,
  resolved_by      uuid references public.profiles (id) on delete set null,
  revision         int not null default 1,
  unique (character_id, request_id)
);
create unique index crafting_attempts_one_pending on public.crafting_attempts (character_id, recipe_id) where status = 'pending';
create index crafting_attempts_character on public.crafting_attempts (character_id, created_at desc);
create index crafting_attempts_recipe on public.crafting_attempts (recipe_id);
create index crafting_attempts_open on public.crafting_attempts (status) where status in ('pending', 'apply_failed');

-- nobody reads or writes these tables directly: everything goes through the RPCs below
alter table public.crafting_recipes enable row level security;
alter table public.crafting_recipe_ingredients enable row level security;
alter table public.character_known_recipes enable row level security;
alter table public.crafting_attempts enable row level security;
revoke all on public.crafting_recipes, public.crafting_recipe_ingredients, public.character_known_recipes, public.crafting_attempts
  from public, anon, authenticated;

-- cache counters (progressive_read_tests coverage rule): no cached read reads the recipe tables -> skip (a DM's recipe edit
-- never invalidates any cache); the per-character tables -> the character counter
create trigger tl_cache_rev after insert or update or delete on public.crafting_recipes
  for each row execute function tl_cache.skip();
create trigger tl_cache_rev after insert or update or delete on public.crafting_recipe_ingredients
  for each row execute function tl_cache.skip();
create trigger tl_cache_rev after insert or update or delete on public.character_known_recipes
  for each row execute function tl_cache.bump('character');
create trigger tl_cache_rev after insert or update or delete on public.crafting_attempts
  for each row execute function tl_cache.bump('character');

-- ---- 3. helpers -------------------------------------------------------------------------------------------------------------
-- An inventory row the character KNOWS: no knowledge row, or an identified one. This is exactly the predicate with which
-- v_inventory_detail (20261112000300 section 7, "masked") and use_inventory_item hide an instance; only such rows count as
-- ingredients for a player. Per row on purpose: a holder of a plain and a disguised copy has one usable copy, not two.
create function public._craft_row_known(p_row uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select not exists (select 1 from public.inventory_item_knowledge k where k.inventory_item_id = p_row and k.state <> 'identified');
$$;

-- Does the character know an ITEM (for labels: a recipe's result, an exact ingredient)? The "effective" level of the T4b overview
-- (get_item_knowledge_overview, 20261112000400): an undisguised copy -> known; disguised copies -> the lowest of them; an item
-- that is not secret -> known; otherwise the character's record.
create function public._craft_item_known(p_character uuid, p_item text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select case
    when it.id is null then false
    when r.n_plain > 0 then true
    when r.n_disg > 0 then coalesce(r.all_identified, false)
    when not it.secret then true
    else coalesce((select ck.state = 'identified' from public.character_item_knowledge ck
                   where ck.character_id = p_character and ck.item_id = p_item), false) end
  from (select 1) one
  left join public.items it on it.id = p_item
  cross join lateral (
    select count(ii.id) filter (where k.inventory_item_id is null) as n_plain,
           count(ii.id) filter (where k.inventory_item_id is not null) as n_disg,
           bool_and(k.state = 'identified') filter (where k.inventory_item_id is not null) as all_identified
    from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
    left join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
    where inv.character_id = p_character and ii.item_id = p_item) r;
$$;

-- does an inventory row fit an ingredient line (exact item, or a tag of the item's details.ingredient_tags)?
create function public._craft_row_matches(p_item_id text, p_ing public.crafting_recipe_ingredients)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select p_item_id is not null and case
    when p_ing.item_id is not null then p_item_id = p_ing.item_id
    else exists (select 1 from public.items i
                 cross join lateral jsonb_array_elements_text(case when jsonb_typeof(i.details -> 'ingredient_tags') = 'array'
                                                                   then i.details -> 'ingredient_tags' else '[]'::jsonb end) t
                 where i.id = p_item_id and lower(btrim(t)) = p_ing.ingredient_tag) end;
$$;

-- may a row be CONSUMED? Never equipped, attuned, a quest item or a container with something in it
create function public._craft_row_free(p_row uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.inventory_items ii where ii.id = p_row and not ii.is_attuned and not ii.is_quest_item)
     and not exists (select 1 from public.character_equipment e where e.inventory_item_id = p_row)
     and not exists (select 1 from public.inventory_items c where c.container_item_id = p_row);
$$;

-- the recipe as a player of this character may see it (or null when it is not visible to the character)
create function public._craft_recipe_player(p_character uuid, p_recipe uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare rc public.crafting_recipes; ch public.characters; kn public.character_known_recipes; it public.items; known boolean;
  ings jsonb; d record;
begin
  select * into ch from public.characters where id = p_character;
  select * into rc from public.crafting_recipes where id = p_recipe;
  if rc.id is null or ch.campaign_id is null or rc.campaign_id <> ch.campaign_id or rc.status <> 'published' then return null; end if;
  select * into kn from public.character_known_recipes where character_id = p_character and recipe_id = p_recipe;
  if rc.visibility <> 'known' and kn.character_id is null then return null; end if;
  select * into it from public.items where id = rc.output_item_id;
  known := public._craft_item_known(p_character, rc.output_item_id);
  select * into d from public._item_decoy(rc.output_item_id);
  select coalesce(jsonb_agg(x.j order by x.seq), '[]') into ings from (
    select g.seq, jsonb_build_object(
      'seq', g.seq, 'quantity', g.quantity, 'consumed', g.consumed, 'tag', g.ingredient_tag,
      'label', case when g.item_id is null then coalesce(nullif(btrim(g.label), ''), 'Any ingredient tagged “' || g.ingredient_tag || '”')
                    when gk.known then (select i.name from public.items i where i.id = g.item_id)
                    else coalesce(nullif(btrim(g.label), ''), 'An unknown ingredient') end,
      'item_id', case when g.item_id is not null and gk.known then g.item_id end,
      'have', coalesce(c.have, 0), 'candidates', coalesce(c.list, '[]')) as j
    from public.crafting_recipe_ingredients g
    cross join lateral (select g.item_id is null or public._craft_item_known(p_character, g.item_id) as known) gk
    left join lateral (
      select sum(ii.quantity)::int as have,
             jsonb_agg(jsonb_build_object('inventory_item_id', ii.id, 'name', coalesce(nullif(ii.custom_name, ''), ii.name), 'quantity', ii.quantity)
                       order by coalesce(nullif(ii.custom_name, ''), ii.name), ii.id) as list
      from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
      where inv.character_id = p_character and inv.kind = 'character'
        and public._craft_row_known(ii.id) and public._craft_row_matches(ii.item_id, g)
        and (not g.consumed or public._craft_row_free(ii.id))) c on true
    where g.recipe_id = rc.id) x;
  return jsonb_build_object(
    'recipe_id', rc.id, 'name', rc.name, 'description', rc.description, 'time_note', rc.time_note,
    'source', case when kn.character_id is not null then 'learned' else 'known' end,
    'new', kn.character_id is not null and kn.seen_at is null,
    'output', jsonb_build_object('name', case when known then it.name else coalesce(nullif(btrim(rc.output_label), ''), d.name) end,
                                 'item_id', case when known then it.id end, 'kind_id', case when known then it.kind_id end,
                                 'quantity', rc.output_quantity, 'known', known),
    'check', case when rc.check_key is not null then jsonb_build_object('key', rc.check_key, 'label', public._identify_check_label(rc.check_key)) end,
    'dm_confirms', rc.requires_dm_approval,
    'ingredients', ings,
    'missing', (select coalesce(jsonb_agg(jsonb_build_object('seq', (e ->> 'seq')::int, 'label', e ->> 'label',
                                 'need', (e ->> 'quantity')::int - (e ->> 'have')::int) order by (e ->> 'seq')::int), '[]')
                from jsonb_array_elements(ings) e where (e ->> 'have')::int < (e ->> 'quantity')::int),
    'can_craft', not exists (select 1 from jsonb_array_elements(ings) e where (e ->> 'have')::int < (e ->> 'quantity')::int),
    'pending_attempt_id', (select a.id from public.crafting_attempts a where a.character_id = p_character and a.recipe_id = rc.id and a.status = 'pending'));
end $$;

-- one attempt as the player sees it: never the DC, the DM's private note, item ids or the selection's rows
create function public._craft_attempt_player(a public.crafting_attempts)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object('attempt_id', a.id, 'recipe_id', a.recipe_id, 'recipe_name', r.name, 'status', a.status, 'outcome', a.outcome,
    'roll_total', a.roll_total, 'natural', a.natural_roll, 'dm_roll_total', a.dm_roll_total, 'dm_reply', a.dm_reply, 'player_note', a.player_note,
    'auto', a.auto, 'created_at', a.created_at, 'resolved_at', a.resolved_at, 'revision', a.revision,
    'consumed', (select coalesce(jsonb_agg(jsonb_build_object('name', x ->> 'name', 'quantity', (x ->> 'quantity')::int)), '[]') from jsonb_array_elements(coalesce(a.consumed, '[]')) x),
    'produced', (select coalesce(jsonb_agg(jsonb_build_object('name', x ->> 'name', 'quantity', (x ->> 'quantity')::int)), '[]') from jsonb_array_elements(coalesce(a.produced, '[]')) x))
  from public.crafting_recipes r where r.id = a.recipe_id;
$$;

-- one attempt as the DM sees it: true names, the DC, the selection, private note
create function public._craft_attempt_dm(a public.crafting_attempts)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public._craft_attempt_player(a) || jsonb_build_object(
    'character_id', a.character_id, 'character_name', ch.name, 'recipe_revision', a.recipe_revision, 'current_revision', r.revision,
    'check_key', r.check_key, 'check_label', case when r.check_key is not null then public._identify_check_label(r.check_key) end,
    'check_dc', r.check_dc, 'failure_mode', r.failure_mode, 'failure_consumes', a.failure_consumes, 'dm_private_note', a.dm_private_note,
    'apply_error', a.apply_error, 'consumed_detail', coalesce(a.consumed, '[]'), 'produced_detail', coalesce(a.produced, '[]'),
    'selected', (select coalesce(jsonb_agg(jsonb_build_object('seq', (s ->> 'seq')::int, 'inventory_item_id', s ->> 'inventory_item_id',
                    'quantity', (s ->> 'quantity')::int, 'shown_name', coalesce(nullif(ii.custom_name, ''), ii.name),
                    'true_name', it.name, 'item_id', ii.item_id, 'have', ii.quantity, 'known', ii.id is not null and public._craft_row_known(ii.id))
                    order by (s ->> 'seq')::int, s ->> 'inventory_item_id'), '[]')
                 from jsonb_array_elements(a.selected) s
                 left join public.inventory_items ii on ii.id = (s ->> 'inventory_item_id')::uuid
                 left join public.items it on it.id = ii.item_id),
    'resolved_by_name', (select p.display_name from public.profiles p where p.id = a.resolved_by))
  from public.crafting_recipes r, public.characters ch where r.id = a.recipe_id and ch.id = a.character_id;
$$;

-- the recipe as the DM edits it
create function public._craft_recipe_dm(p_recipe uuid)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select to_jsonb(r) || jsonb_build_object(
    'output_name', (select name from public.items where id = r.output_item_id),
    'output_secret', (select secret from public.items where id = r.output_item_id),
    'crit_output_name', (select name from public.items where id = r.crit_output_item_id),
    'failure_output_name', (select name from public.items where id = r.failure_output_item_id),
    'check_label', case when r.check_key is not null then public._identify_check_label(r.check_key) end,
    'ingredients', (select coalesce(jsonb_agg(jsonb_build_object('seq', g.seq, 'item_id', g.item_id, 'item_name', i.name, 'item_secret', i.secret,
                       'tag', g.ingredient_tag, 'label', g.label, 'quantity', g.quantity, 'consumed', g.consumed) order by g.seq), '[]')
                    from public.crafting_recipe_ingredients g left join public.items i on i.id = g.item_id where g.recipe_id = r.id),
    'known_by', (select coalesce(jsonb_agg(jsonb_build_object('character_id', k.character_id, 'name', c.name, 'seen', k.seen_at is not null) order by c.name), '[]')
                 from public.character_known_recipes k join public.characters c on c.id = k.character_id where k.recipe_id = r.id),
    'pending', (select count(*) from public.crafting_attempts a where a.recipe_id = r.id and a.status in ('pending', 'apply_failed')),
    'attempts', (select count(*) from public.crafting_attempts a where a.recipe_id = r.id))
  from public.crafting_recipes r where r.id = p_recipe;
$$;

-- an item a recipe of this campaign may name: official or of this campaign, not archived
create function public._craft_item_ok(p_item text, p_campaign uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.items i where i.id = p_item and i.archived_at is null
                 and (i.owner_id is null or i.campaign_id = p_campaign));
$$;

-- Produce p_quantity of an item into the character's inventory, as a DM assignment would (_dm_add_item semantics, without its
-- governance gate and its _rpc_begin / _rpc_end): identified -> plain rows (a secret item the character only knew partly is
-- learned first, so its other copies follow); otherwise INSERTED with the disguise + knowledge row (the Realtime INSERT never
-- carries the true name) and the character's record. Logs 'add' with p_meta (craft_attempt). Returns the produced entry.
create function public._craft_produce(p_inventory uuid, p_character uuid, p_item text, p_quantity int, p_identified boolean, p_meta jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items; ck public.character_item_knowledge; d record; nm text; ds text; remaining int := greatest(coalesce(p_quantity, 1), 1);
  chunk int; rid uuid; last_id uuid; plain boolean;
begin
  select * into it from public.items where id = p_item;
  if it.id is null or it.archived_at is not null then
    raise exception 'The result of this recipe is no longer available' using errcode = 'TLCRF';
  end if;
  select * into ck from public.character_item_knowledge where character_id = p_character and item_id = p_item;
  plain := coalesce(p_identified, true) or coalesce(ck.state = 'identified', false) or it.owner_id is null;   -- official rows are never disguised
  if plain then
    if it.secret and ((ck.character_id is not null and ck.state <> 'identified')
                      or exists (select 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                                 join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
                                 where inv.character_id = p_character and ii.item_id = p_item and k.state <> 'identified')) then
      perform public._identify_apply(p_character, p_item, '{all}');   -- they made it: they know it (record + other copies)
    end if;
    while remaining > 0 loop
      chunk := case when it.stackable then least(remaining, coalesce(it.stack_max, remaining)) else 1 end;
      insert into public.inventory_items (inventory_id, item_id, quantity) values (p_inventory, p_item, chunk) returning id into rid;
      last_id := public._try_auto_merge(rid);
      remaining := remaining - chunk;
    end loop;
    nm := it.name;
  else
    update public.items set secret = true where id = p_item and not secret;   -- as _dm_add_item (campaign items only, see above)
    select * into d from public._item_decoy(p_item);
    nm := case when 'name' = any (coalesce(ck.revealed, '{}')) then it.name else d.name end;
    ds := case when 'description' = any (coalesce(ck.revealed, '{}')) then coalesce(it.description, '') else d.description end;
    while remaining > 0 loop
      chunk := case when it.stackable then least(remaining, coalesce(it.stack_max, remaining)) else 1 end;
      insert into public.inventory_items (inventory_id, item_id, quantity, name, description) values (p_inventory, p_item, chunk, nm, ds)
      returning id into rid;
      insert into public.inventory_item_knowledge (inventory_item_id, state, revealed, true_name, updated_by)
      values (rid, coalesce(ck.state, 'unidentified'), coalesce(ck.revealed, '{}'), it.name, auth.uid());
      last_id := public._try_auto_merge(rid);
      remaining := remaining - chunk;
    end loop;
    insert into public.character_item_knowledge (character_id, item_id, state, revealed, updated_by)
    values (p_character, p_item, 'unidentified', '{}', auth.uid()) on conflict (character_id, item_id) do nothing;
  end if;
  perform public.log_inventory_event(p_inventory, last_id, 'add', greatest(coalesce(p_quantity, 1), 1), p_item,
    coalesce(p_meta, '{}') || jsonb_build_object('via', 'craft', 'name', nm, 'unidentified', not plain));
  return jsonb_build_object('inventory_item_id', last_id, 'item_id', p_item, 'name', nm, 'quantity', greatest(coalesce(p_quantity, 1), 1), 'identified', plain);
end $$;

-- Apply an attempt with an outcome (the caller holds the attempt row lock). Locks the selected rows (id order: deadlock-safe;
-- the character row is NOT locked here, examine locks row -> character), re-checks them against the CURRENT recipe, consumes and
-- produces with direct writes inside ONE _rpc_begin / _rpc_end scope. Any problem raises TLCRF with a fixed text (no item names):
-- the caller turns it into apply_failed after its savepoint rolled back every partial write.
create function public._craft_apply(p_attempt uuid, p_outcome text, p_failure_consumes text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare a public.crafting_attempts; r public.crafting_recipes; g public.crafting_recipe_ingredients; s jsonb; ir public.inventory_items;
  inv_char uuid; inv_kind text; q int; mode text; consumed jsonb := '[]'; produced jsonb := '[]'; meta jsonb; out_item text; out_qty int;
  covered int;
begin
  select * into a from public.crafting_attempts where id = p_attempt;
  select * into r from public.crafting_recipes where id = a.recipe_id;
  perform public._rpc_begin();
  perform 1 from public.inventory_items where id in (select (x ->> 'inventory_item_id')::uuid from jsonb_array_elements(a.selected) x)
    order by id for update;
  -- every ingredient line still covered by the selection, every selected row still there, known, fitting and free
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
  end loop;

  mode := case when p_outcome in ('success', 'critical_success') then 'lose_all'
               when p_outcome = 'critical_failure' then 'lose_all'
               else coalesce(p_failure_consumes, r.failure_mode) end;
  meta := jsonb_build_object('craft_attempt', a.id, 'recipe', r.id, 'outcome', p_outcome);
  -- consume (rows in id order)
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
  -- produce
  if p_outcome in ('success', 'critical_success') then
    out_item := case when p_outcome = 'critical_success' then coalesce(r.crit_output_item_id, r.output_item_id) else r.output_item_id end;
    out_qty := r.output_quantity + case when p_outcome = 'critical_success' then r.crit_bonus_quantity else 0 end;
  else
    out_item := r.failure_output_item_id;
    out_qty := r.failure_output_quantity;
  end if;
  if out_item is not null then
    produced := jsonb_build_array(public._craft_produce(a.inventory_id, a.character_id, out_item, out_qty, r.output_identified, meta));
  end if;
  perform public._rpc_end();
  return jsonb_build_object('consumed', consumed, 'produced', produced);
end $$;

-- the player's line in the audit (only the character's owner reads non-DM events) and the DM's line with true names
create function public._craft_audit(a public.crafting_attempts)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.crafting_recipes; camp uuid; made text;
begin
  select * into r from public.crafting_recipes where id = a.recipe_id;
  camp := r.campaign_id;
  made := (select string_agg((x ->> 'quantity') || ' × ' || (x ->> 'name'), ', ') from jsonb_array_elements(coalesce(a.produced, '[]')) x);
  perform public._audit(camp, a.character_id, 'item_crafted',
    case a.status
      when 'applied' then case when a.outcome in ('success', 'critical_success') then 'Crafted ' || coalesce(made, 'nothing') || ' (' || r.name || ')'
                               else 'Crafting failed: ' || r.name || coalesce(' (got ' || made || ')', '') end
      when 'pending' then 'Crafting attempt sent to the DM: ' || r.name
      when 'rejected' then 'The DM did not accept the crafting attempt: ' || r.name
      when 'cancelled' then 'Crafting attempt cancelled: ' || r.name
      else 'Crafting attempt could not be applied yet: ' || r.name end,
    null, null, null, null, 'party');
  perform public._audit(camp, a.character_id, 'item_crafted',
    'Crafting ' || a.status || coalesce(' (' || a.outcome || ')', '') || ': ' || r.name
      || coalesce(', roll ' || coalesce(a.dm_roll_total, a.roll_total), '') || coalesce(' vs DC ' || r.check_dc, ''),
    null, jsonb_build_object('attempt_id', a.id, 'recipe_id', r.id, 'consumed', coalesce(a.consumed, '[]'), 'produced', coalesce(a.produced, '[]')),
    null, null, 'dm');
end $$;

-- ---- 4. player RPCs (owner of the character; governance inventory.craft) ------------------------------------------------------
create function public._craft_player_gate(p_character uuid)
returns public.characters
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare ch public.characters;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  select * into ch from public.characters where id = p_character;
  if ch.id is null or not (ch.owner_id = auth.uid() or public.is_admin()) then
    raise exception 'Only the character''s player can craft' using errcode = '42501';
  end if;
  perform public._gov_gate(ch.id, 'inventory.craft');
  return ch;
end $$;

-- known recipes with what is missing (computed from fully known rows only), recent attempts, the number still to discover
create function public.get_character_recipes(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare ch public.characters; dm boolean;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  select * into ch from public.characters where id = p_character;
  dm := public.is_admin() or (ch.campaign_id is not null and public.is_campaign_dm(ch.campaign_id));
  if not dm then perform public._craft_player_gate(p_character); end if;
  return jsonb_build_object(
    'character_id', ch.id,
    'recipes', (select coalesce(jsonb_agg(x.j order by x.nm, x.id), '[]') from (
                 select rc.name as nm, rc.id, public._craft_recipe_player(ch.id, rc.id) as j
                 from public.crafting_recipes rc
                 where ch.campaign_id is not null and rc.campaign_id = ch.campaign_id and rc.status = 'published'
                   and (rc.visibility = 'known' or exists (select 1 from public.character_known_recipes k where k.character_id = ch.id and k.recipe_id = rc.id))) x),
    'undiscovered', (select count(*) from public.crafting_recipes rc where ch.campaign_id is not null and rc.campaign_id = ch.campaign_id
                     and rc.status = 'published' and rc.visibility = 'discoverable'
                     and not exists (select 1 from public.character_known_recipes k where k.character_id = ch.id and k.recipe_id = rc.id)),
    'attempts', (select coalesce(jsonb_agg(public._craft_attempt_player(a) order by a.created_at desc, a.id), '[]')
                 from (select * from public.crafting_attempts x where x.character_id = ch.id order by x.created_at desc, x.id limit 20) a));
end $$;

-- p_selected: [{seq, inventory_item_id, quantity}] (one row per ingredient line or more; a row only once)
create function public.start_craft_attempt(p_character uuid, p_recipe uuid, p_selected jsonb, p_roll_total int default null,
                                           p_request_id uuid default null, p_natural text default null, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare ch public.characters; rc public.crafting_recipes; a public.crafting_attempts; inv uuid; s jsonb; g public.crafting_recipe_ingredients;
  ir public.inventory_items; norm jsonb := '[]'; ids uuid[] := '{}'; covered int; res jsonb; inv_char uuid; inv_kind text; q int;
begin
  if p_request_id is null then raise exception 'A request id is required' using errcode = '22023'; end if;
  ch := public._craft_player_gate(p_character);
  select * into a from public.crafting_attempts where character_id = ch.id and request_id = p_request_id;
  if a.id is not null then return public._craft_attempt_player(a) || jsonb_build_object('replayed', true); end if;
  select * into rc from public.crafting_recipes where id = p_recipe;
  if public._craft_recipe_player(ch.id, p_recipe) is null then raise exception 'Recipe not found' using errcode = 'P0002'; end if;
  -- no character row lock: the auto path locks inventory rows (_craft_apply) and examine locks a row, then the character.
  -- Duplicates are caught by the unique keys below (same request id: replay; a second pending attempt: 55000).
  select id into inv from public.inventories where character_id = ch.id and kind = 'character' order by created_at limit 1;
  if inv is null then raise exception 'The character has no inventory' using errcode = '22023'; end if;

  -- the selection: shape and ownership
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
  -- knowledge FIRST, for every selected row, with one fixed message (it never says "matches" or "does not match")
  if exists (select 1 from unnest(ids) x where not public._craft_row_known(x)) then
    raise exception 'You don''t know what this ingredient is yet' using errcode = '22023';
  end if;
  -- only now: does the selection fit the recipe?
  for s in select x from jsonb_array_elements(norm) x loop
    select * into g from public.crafting_recipe_ingredients where recipe_id = rc.id and seq = (s ->> 'seq')::int;
    select * into ir from public.inventory_items where id = (s ->> 'inventory_item_id')::uuid;
    q := (s ->> 'quantity')::int;
    if g.id is null or not public._craft_row_matches(ir.item_id, g) then raise exception 'This item does not fit that ingredient' using errcode = '22023'; end if;
    if q > ir.quantity then raise exception 'Not enough items in that stack' using errcode = '22023'; end if;
    if g.consumed and not public._craft_row_free(ir.id) then
      raise exception 'Equipped, attuned or quest items and containers with contents cannot be used up' using errcode = '22023';
    end if;
  end loop;
  for g in select * from public.crafting_recipe_ingredients where recipe_id = rc.id order by seq loop
    select coalesce(sum((x ->> 'quantity')::int), 0) into covered from jsonb_array_elements(norm) x where (x ->> 'seq')::int = g.seq;
    if covered <> g.quantity then raise exception 'Choose exactly what the recipe needs for each ingredient' using errcode = '22023'; end if;
  end loop;
  if rc.check_key is not null and (p_roll_total is null or p_roll_total < -10 or p_roll_total > 60) then
    raise exception 'Enter the total of your roll (-10 to 60)' using errcode = '22023';
  end if;
  if p_roll_total is not null and (p_roll_total < -10 or p_roll_total > 60) then raise exception 'Roll out of range' using errcode = '22023'; end if;
  if p_natural is not null and p_natural not in ('nat20', 'nat1') then raise exception 'Natural roll: nat20 or nat1' using errcode = '22023'; end if;
  if exists (select 1 from public.crafting_attempts x where x.character_id = ch.id and x.recipe_id = rc.id and x.status = 'pending') then
    raise exception 'Your DM has not answered your last attempt at this recipe yet' using errcode = '55000';
  end if;

  begin
    insert into public.crafting_attempts (character_id, recipe_id, recipe_revision, inventory_id, selected, roll_total, natural_roll,
                                          player_note, request_id, auto)
    values (ch.id, rc.id, rc.revision, inv, norm, p_roll_total, p_natural, nullif(left(btrim(coalesce(p_note, '')), 500), ''), p_request_id,
            not rc.requires_dm_approval and rc.check_dc is null)
    on conflict (character_id, request_id) do nothing
    returning * into a;
  exception when unique_violation then   -- a concurrent second pending attempt at the same recipe (crafting_attempts_one_pending)
    raise exception 'Your DM has not answered your last attempt at this recipe yet' using errcode = '55000';
  end;
  if a.id is null then
    select * into a from public.crafting_attempts where character_id = ch.id and request_id = p_request_id;
    return public._craft_attempt_player(a) || jsonb_build_object('replayed', true);
  end if;
  if a.auto then
    -- auto path: consumed and produced now (an error rolls the whole start back: nothing is recorded or changed)
    res := public._craft_apply(a.id, 'success', null);
    update public.crafting_attempts set status = 'applied', outcome = 'success', consumed = res -> 'consumed', produced = res -> 'produced',
           resolved_at = now(), revision = revision + 1 where id = a.id returning * into a;
  end if;
  perform public._craft_audit(a);
  perform public._identify_touch(ch.id);
  return public._craft_attempt_player(a);
end $$;

create function public.cancel_craft_attempt(p_attempt uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare a public.crafting_attempts;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  select * into a from public.crafting_attempts where id = p_attempt for update;
  if a.id is null then raise exception 'Attempt not found' using errcode = 'P0002'; end if;
  perform public._craft_player_gate(a.character_id);
  if a.status <> 'pending' then raise exception 'This attempt was already answered' using errcode = '55000'; end if;
  update public.crafting_attempts set status = 'cancelled', resolved_at = now(), resolved_by = auth.uid(), revision = revision + 1
   where id = a.id returning * into a;
  perform public._craft_audit(a);
  perform public._identify_touch(a.character_id);
  return public._craft_attempt_player(a);
end $$;

-- "New recipe learned!" seen
create function public.mark_recipes_seen(p_character uuid)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare n int;
begin
  perform public._craft_player_gate(p_character);
  update public.character_known_recipes set seen_at = now() where character_id = p_character and seen_at is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---- 5. DM RPCs (DM of the campaign or admin; independent of inventory.craft) --------------------------------------------------
create function public._craft_dm_gate(p_campaign uuid)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or p_campaign is null or not (public.is_admin() or public.is_campaign_dm(p_campaign)) then
    raise exception 'Only the DM of the campaign can manage crafting' using errcode = '42501';
  end if;
end $$;

-- insert (p_recipe.id null) or update a recipe; the ingredients are replaced as a set
create function public.dm_save_recipe(p_campaign uuid, p_recipe jsonb, p_expected_revision int default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare o jsonb := coalesce(p_recipe, '{}'); r public.crafting_recipes; rid uuid; g jsonb; n int := 0; dc int; key text; out_item text;
  crit text; fail text; ident boolean; ing_item text; ing_tag text; qty int;
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
  out_item := nullif(btrim(coalesce(o ->> 'output_item_id', '')), '');
  crit := nullif(btrim(coalesce(o ->> 'crit_output_item_id', '')), '');
  fail := nullif(btrim(coalesce(o ->> 'failure_output_item_id', '')), '');
  if out_item is null then raise exception 'Choose what the recipe makes' using errcode = '22023'; end if;
  if not public._craft_item_ok(out_item, p_campaign) or (crit is not null and not public._craft_item_ok(crit, p_campaign))
     or (fail is not null and not public._craft_item_ok(fail, p_campaign)) then
    raise exception 'Choose an official item or an item of this campaign (not archived)' using errcode = '22023';
  end if;
  ident := coalesce((o ->> 'output_identified')::boolean, true);
  if not ident and exists (select 1 from public.items i where i.id in (out_item, crit, fail) and i.owner_id is null) then
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
  end loop;

  if r.id is null then
    insert into public.crafting_recipes (campaign_id, name, output_item_id, updated_by) values (p_campaign, btrim(o ->> 'name'), out_item, auth.uid())
    returning * into r;
  end if;
  update public.crafting_recipes set
    name = btrim(o ->> 'name'), description = left(coalesce(o ->> 'description', ''), 2000),
    dm_notes = nullif(left(coalesce(o ->> 'dm_notes', ''), 2000), ''),
    visibility = coalesce(o ->> 'visibility', 'known'), output_item_id = out_item,
    output_quantity = least(greatest(coalesce((o ->> 'output_quantity')::int, 1), 1), 99),
    output_label = nullif(left(btrim(coalesce(o ->> 'output_label', '')), 120), ''), output_identified = ident,
    crit_output_item_id = crit, crit_bonus_quantity = least(greatest(coalesce((o ->> 'crit_bonus_quantity')::int, 0), 0), 99),
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
    insert into public.crafting_recipe_ingredients (recipe_id, seq, item_id, ingredient_tag, label, quantity, consumed)
    values (r.id, n, nullif(btrim(coalesce(g ->> 'item_id', '')), ''), nullif(lower(btrim(coalesce(g ->> 'tag', ''))), ''),
            nullif(left(btrim(coalesce(g ->> 'label', '')), 120), ''), qty, coalesce((g ->> 'consumed')::boolean, true));
  end loop;
  return public._craft_recipe_dm(r.id);
end $$;

-- draft | published | archived (archive keeps every attempt; the DM can still answer pending ones)
create function public.dm_set_recipe_status(p_recipe uuid, p_status text)
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
  if p_status = 'published' and (not public._craft_item_ok(r.output_item_id, r.campaign_id)
      or exists (select 1 from public.crafting_recipe_ingredients g where g.recipe_id = r.id and g.item_id is not null
                 and not public._craft_item_ok(g.item_id, r.campaign_id))) then
    raise exception 'An item of this recipe is archived or not available in the campaign' using errcode = '22023';
  end if;
  if r.status <> p_status then
    update public.crafting_recipes set status = p_status, revision = revision + 1, updated_by = auth.uid(), updated_at = now() where id = r.id;
    perform public._audit(r.campaign_id, null, 'recipe_changed', 'Crafting recipe ' || r.name || ': ' || p_status, null,
                          jsonb_build_object('recipe_id', r.id, 'status', p_status), null, null, 'dm');
  end if;
  return public._craft_recipe_dm(r.id);
end $$;

-- recipe discovery: grant (or take back) a recipe to characters of the campaign
create function public.dm_grant_recipe(p_recipe uuid, p_characters uuid[], p_grant boolean default true)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.crafting_recipes; cid uuid; n int := 0; k int;
begin
  select * into r from public.crafting_recipes where id = p_recipe;
  if r.id is null then raise exception 'Recipe not found' using errcode = 'P0002'; end if;
  perform public._craft_dm_gate(r.campaign_id);
  if p_characters is null or cardinality(p_characters) = 0 or cardinality(p_characters) > 100 then
    raise exception 'Choose 1 to 100 characters' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(p_characters) t left join public.characters c on c.id = t where t is null or c.campaign_id is distinct from r.campaign_id) then
    raise exception 'Every character must be in the campaign' using errcode = '22023';
  end if;
  foreach cid in array array(select distinct x from unnest(p_characters) x order by 1) loop
    if coalesce(p_grant, true) then
      insert into public.character_known_recipes (character_id, recipe_id, granted_by) values (cid, r.id, auth.uid()) on conflict do nothing;
    else
      delete from public.character_known_recipes where character_id = cid and recipe_id = r.id;
    end if;
    get diagnostics k = row_count;
    if k > 0 then
      n := n + 1;
      -- the player hears of a learned recipe only while it is published (a draft's name stays with the DM)
      if coalesce(p_grant, true) and r.status = 'published' then
        perform public._audit(r.campaign_id, cid, 'recipe_learned', 'New recipe learned: ' || r.name, null, null, null, null, 'party');
      end if;
      perform public._identify_touch(cid);
    end if;
  end loop;
  return jsonb_build_object('recipe_id', r.id, 'changed', n, 'recipe', public._craft_recipe_dm(r.id));
end $$;

-- approve (outcome; null = by the roll against the DC, success without a DC) or reject. Exactly one answer succeeds (row lock +
-- revision). Approving an apply_failed attempt is the retry.
create function public.dm_resolve_craft_attempt(p_attempt uuid, p_decision text, p_outcome text default null, p_dm_roll_total int default null,
                                                p_reply text default null, p_private_note text default null,
                                                p_failure_consumes text default null, p_expected_revision int default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare a public.crafting_attempts; r public.crafting_recipes; outc text; res jsonb; err text; roll int;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  select * into a from public.crafting_attempts where id = p_attempt for update;
  if a.id is null then raise exception 'Attempt not found' using errcode = 'P0002'; end if;
  select * into r from public.crafting_recipes where id = a.recipe_id;
  perform public._craft_dm_gate(r.campaign_id);
  if p_expected_revision is not null and p_expected_revision <> a.revision then
    raise exception 'Someone else answered this attempt meanwhile. Reload and try again.' using errcode = '40001';
  end if;
  if a.status not in ('pending', 'apply_failed') then raise exception 'This attempt was already answered' using errcode = '55000'; end if;
  if p_decision not in ('approve', 'reject') then raise exception 'Approve or reject' using errcode = '22023'; end if;
  if p_dm_roll_total is not null and (p_dm_roll_total < -10 or p_dm_roll_total > 60) then raise exception 'Roll out of range' using errcode = '22023'; end if;
  if p_outcome is not null and p_outcome not in ('success', 'failure', 'critical_success', 'critical_failure') then
    raise exception 'Unknown outcome' using errcode = '22023';
  end if;
  if p_failure_consumes is not null and p_failure_consumes not in ('keep', 'lose_all', 'lose_half') then
    raise exception 'Unknown failure rule' using errcode = '22023';
  end if;
  update public.crafting_attempts set dm_reply = coalesce(nullif(left(btrim(coalesce(p_reply, '')), 500), ''), dm_reply),
         dm_private_note = coalesce(nullif(left(btrim(coalesce(p_private_note, '')), 500), ''), dm_private_note),
         dm_roll_total = coalesce(p_dm_roll_total, dm_roll_total)
   where id = a.id returning * into a;
  if p_decision = 'reject' then
    update public.crafting_attempts set status = 'rejected', resolved_at = now(), resolved_by = auth.uid(), revision = revision + 1
     where id = a.id returning * into a;
  else
    roll := coalesce(a.dm_roll_total, a.roll_total);
    outc := coalesce(p_outcome, a.outcome, case when r.check_dc is null then 'success' when roll is null then null
                                                when roll >= r.check_dc then 'success' else 'failure' end);
    if outc is null then raise exception 'Choose the outcome (no roll was entered)' using errcode = '22023'; end if;
    update public.crafting_attempts set outcome = outc, failure_consumes = coalesce(p_failure_consumes, failure_consumes) where id = a.id
    returning * into a;
    begin
      res := public._craft_apply(a.id, outc, a.failure_consumes);
    exception when sqlstate 'TLCRF' then
      err := sqlerrm;   -- every partial write of the apply is rolled back with this block's savepoint
    end;
    if err is null then
      update public.crafting_attempts set status = 'applied', consumed = res -> 'consumed', produced = res -> 'produced', apply_error = null,
             resolved_at = now(), resolved_by = auth.uid(), revision = revision + 1 where id = a.id returning * into a;
    else
      update public.crafting_attempts set status = 'apply_failed', apply_error = left(err, 300), resolved_by = auth.uid(), revision = revision + 1
       where id = a.id returning * into a;
    end if;
  end if;
  perform public._craft_audit(a);
  perform public._identify_touch(a.character_id);
  return public._craft_attempt_dm(a);
end $$;

-- DM reads
create function public.get_campaign_recipes(p_campaign uuid)
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
                   from public.characters c where c.campaign_id = p_campaign));
end $$;

create function public.get_campaign_craft_attempts(p_campaign uuid, p_status text default 'open')
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform public._craft_dm_gate(p_campaign);
  return (select coalesce(jsonb_agg(public._craft_attempt_dm(a) order by (a.status in ('pending', 'apply_failed')) desc, a.created_at desc, a.id), '[]')
          from (select x.* from public.crafting_attempts x join public.crafting_recipes r on r.id = x.recipe_id
                where r.campaign_id = p_campaign
                  and (p_status is null or (p_status = 'open' and x.status in ('pending', 'apply_failed'))
                       or (p_status = 'closed' and x.status not in ('pending', 'apply_failed')) or x.status = p_status)
                order by x.created_at desc, x.id limit 200) a);
end $$;

-- the Crafting tab's badge (a count only)
create function public.get_campaign_pending_craft_count(p_campaign uuid)
returns int
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform public._craft_dm_gate(p_campaign);
  return (select count(*)::int from public.crafting_attempts x join public.crafting_recipes r on r.id = x.recipe_id
          where r.campaign_id = p_campaign and x.status in ('pending', 'apply_failed'));
end $$;

-- the recipe editor's item picker: official items and items of this campaign (not archived), by name
create function public.get_campaign_craft_items(p_campaign uuid, p_query text default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare q text := nullif(btrim(coalesce(p_query, '')), '');
begin
  perform public._craft_dm_gate(p_campaign);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'kind_id', i.kind_id, 'official', i.owner_id is null, 'secret', i.secret,
                    'tags', case when jsonb_typeof(i.details -> 'ingredient_tags') = 'array' then i.details -> 'ingredient_tags' else '[]'::jsonb end)
                    order by (i.owner_id is null), i.name, i.id), '[]')
          from (select * from public.items i where i.archived_at is null and (i.owner_id is null or i.campaign_id = p_campaign)
                  and (q is null or strpos(lower(i.name), lower(left(q, 80))) > 0)
                order by (i.owner_id is null), i.name, i.id limit 40) i);
end $$;

-- ---- 6. replaced deletion-dependency functions (bodies of 20261112000100 + the lines marked 20261113000100) -------------------
create or replace function public._item_dependencies(p_item text, p_self_content uuid default null)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'character_inventories', (select count(*) from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                              where ii.item_id = p_item and inv.kind = 'character'),
    'other_inventories', (select count(*) from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                          where ii.item_id = p_item and inv.kind <> 'character'),
    'equipped_or_attuned', (select count(*) from public.inventory_items ii where ii.item_id = p_item and (ii.equipped or ii.is_attuned)),
    'in_containers', (select count(*) from public.inventory_items ii where ii.item_id = p_item and ii.container_item_id is not null),
    'owned_assets', (select count(*) from public.owned_assets where item_id = p_item),
    'background_equipment', (select count(*) from public.background_equipment_entries where item_id = p_item),
    'proficiencies', (select count(*) from public.character_proficiencies where item_id = p_item),
    'items_based_on_it', (select count(*) from public.items where base_item_id = p_item),
    'inventory_history', (select count(*) from public.inventory_events where item_id = p_item),
    'pending_requests', (select count(*) from public.change_requests r where r.status in ('submitted', 'returned_for_changes', 'apply_failed')
                         and not r.stale and public._json_mentions(r.ops::text, p_item)),
    'request_history', (select count(*) from public.change_requests r
                        where (r.status = 'draft' or (r.status in ('submitted', 'returned_for_changes', 'apply_failed') and r.stale))
                        and public._json_mentions(r.ops::text, p_item)),
    'dm_content_versions', (select count(*) from public.dm_content_versions v where v.catalog_ref = p_item
                            and v.content_id is distinct from p_self_content),
    -- 20261113000100: every crafting recipe (any status) that names the item (result, critical / failure result, ingredient)
    'crafting_recipes', (select count(*) from public.crafting_recipes cr
                         where p_item in (cr.output_item_id, cr.crit_output_item_id, cr.failure_output_item_id)
                            or exists (select 1 from public.crafting_recipe_ingredients g where g.recipe_id = cr.id and g.item_id = p_item)));
$$;

create or replace function public.preview_item_deletion(p_item text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare it public.items; d jsonb; n int; dm uuid; reasons text[] := '{}'; hist text[] := '{}';
begin
  select * into it from public.items where id = p_item;
  if it.id is null or not public.can_view_owned(it.owner_id, it.campaign_id) then raise exception 'Unknown item' using errcode = 'P0002'; end if;
  if it.owner_id is null then
    return jsonb_build_object('item_id', it.id, 'name', it.name, 'deletable', false, 'official', true, 'reasons', jsonb_build_array('Official items are never deleted.'));
  end if;
  if not public.can_edit_owned(it.owner_id, it.campaign_id) then raise exception 'Not allowed to change this item' using errcode = '42501'; end if;
  select content_id into dm from public.dm_content_versions where catalog_ref = p_item limit 1;
  d := public._item_dependencies(p_item, dm);
  n := public._item_blocking(d);
  if (d ->> 'character_inventories')::int > 0 then reasons := reasons || format('%s character inventory entr%s', d ->> 'character_inventories', case when (d ->> 'character_inventories')::int = 1 then 'y' else 'ies' end); end if;
  if (d ->> 'other_inventories')::int > 0 then reasons := reasons || format('%s stash or party entr%s', d ->> 'other_inventories', case when (d ->> 'other_inventories')::int = 1 then 'y' else 'ies' end); end if;
  if (d ->> 'owned_assets')::int > 0 then reasons := reasons || 'owned assets'::text; end if;
  if (d ->> 'background_equipment')::int > 0 then reasons := reasons || 'background starting equipment'::text; end if;
  if (d ->> 'proficiencies')::int > 0 then reasons := reasons || 'character proficiencies'::text; end if;
  if (d ->> 'items_based_on_it')::int > 0 then reasons := reasons || 'other items are based on it'::text; end if;
  if (d ->> 'pending_requests')::int > 0 then reasons := reasons || 'submitted change requests'::text; end if;
  if (d ->> 'dm_content_versions')::int > 0 then reasons := reasons || 'other DM content versions'::text; end if;
  -- 20261113000100: the recipes by name (up to three)
  if coalesce((d ->> 'crafting_recipes')::int, 0) > 0 then
    reasons := reasons || (select 'used in crafting recipe' || case when count(*) > 1 then 's ' else ' ' end
                                  || string_agg('“' || x.name || '”', ', ' order by x.name) || case when (d ->> 'crafting_recipes')::int > 3 then ' …' else '' end
                           from (select cr.name from public.crafting_recipes cr
                                 where p_item in (cr.output_item_id, cr.crit_output_item_id, cr.failure_output_item_id)
                                    or exists (select 1 from public.crafting_recipe_ingredients g where g.recipe_id = cr.id and g.item_id = p_item)
                                 order by cr.name limit 3) x);
  end if;
  if (d ->> 'inventory_history')::int > 0 then hist := hist || format('%s inventory history entr%s', d ->> 'inventory_history', case when (d ->> 'inventory_history')::int = 1 then 'y' else 'ies' end); end if;
  if (d ->> 'request_history')::int > 0 then hist := hist || 'draft or outdated change requests'::text; end if;
  return jsonb_build_object('item_id', it.id, 'name', it.name, 'kind_id', it.kind_id, 'archived', it.archived_at is not null,
    'dm_content_id', dm, 'deletable', n = 0, 'dependencies', d, 'reasons', to_jsonb(reasons), 'history', to_jsonb(hist),
    'advice', case when n = 0 and cardinality(hist) > 0 then 'Nothing uses this definition now. Deleting it cannot be undone; its history stays readable under its name.'
                   when n = 0 then 'Nothing uses this definition. Deleting it cannot be undone.'
                   when it.archived_at is not null then 'This archived definition is still in use. Remove it from those places first; then it can be deleted.'
                   else 'This definition is in use. Archive it instead: it can no longer be added, and every existing entry keeps working.' end);
end $$;

create or replace function public._dm_content_dependencies(p_content uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.dm_content; refs text[]; vids uuid[]; base text; d jsonb := '{}'; cur int := 0; hist int := 0; n int;
  item jsonb; r text;
begin
  select * into c from public.dm_content where id = p_content;
  if c.id is null then return null; end if;
  select coalesce(array_agg(v.catalog_ref) filter (where v.catalog_ref is not null), '{}'), coalesce(array_agg(v.id), '{}')
    into refs, vids from public.dm_content_versions v where v.content_id = p_content;
  base := public._dm_short(p_content);
  -- current use, per type
  case c.content_type
  when 'spell' then
    d := d || jsonb_build_object(
      'character_spells', (select count(*) from public.character_spells where spell_version_id = any (refs)),
      'character_resources', (select count(*) from public.character_resources where spell_version_id = any (refs)),
      'feat_spell_grants', (select count(*) from public.feat_spell_grants where spell_version_id = any (refs)),
      'class_feature_effects', (select count(*) from public.class_feature_effects where spell_version_id = any (refs)));
  when 'item' then
    foreach r in array refs loop
      item := public._item_dependencies(r, p_content);
      d := d || jsonb_build_object(
        'inventory_instances', coalesce((d ->> 'inventory_instances')::int, 0) + coalesce((item ->> 'character_inventories')::int, 0) + coalesce((item ->> 'other_inventories')::int, 0),
        'inventory_history', coalesce((d ->> 'inventory_history')::int, 0) + coalesce((item ->> 'inventory_history')::int, 0),
        'owned_assets', coalesce((d ->> 'owned_assets')::int, 0) + coalesce((item ->> 'owned_assets')::int, 0),
        'background_equipment', coalesce((d ->> 'background_equipment')::int, 0) + coalesce((item ->> 'background_equipment')::int, 0),
        'proficiencies', coalesce((d ->> 'proficiencies')::int, 0) + coalesce((item ->> 'proficiencies')::int, 0),
        'items_based_on_it', coalesce((d ->> 'items_based_on_it')::int, 0) + coalesce((item ->> 'items_based_on_it')::int, 0),
        -- 20261113000100
        'crafting_recipes', coalesce((d ->> 'crafting_recipes')::int, 0) + coalesce((item ->> 'crafting_recipes')::int, 0));
    end loop;
    d := d || jsonb_build_object(
      'equipped_instances', (select count(*) from public.character_equipment e join public.inventory_items ii on ii.id = e.inventory_item_id where ii.item_id = any (refs)),
      'attuned_instances', (select count(*) from public.inventory_items ii where ii.item_id = any (refs) and coalesce(ii.is_attuned, false)));
  when 'feat' then
    d := d || jsonb_build_object(
      'feat_assignments', (select count(*) from public.character_feats where feat_version_id = any (refs)),
      'feat_choices', (select count(*) from public.character_feat_choices x join public.feat_choices fc on fc.id = x.choice_id where fc.version_id = any (refs)),
      'lineage_feat_picks', (select count(*) from public.character_lineage_choices where value = any (array(select 'feat:' || x from unnest(refs) x))),
      'class_feat_picks', (select count(*) from public.character_feature_choice_values where value = any (array(select 'feat:' || x from unnest(refs) x))),
      'backgrounds_granting', (select count(*) from public.background_feat_grants where feat_id = any (refs)));
  when 'creature', 'companion' then
    d := d || jsonb_build_object(
      'seen_forms', (select count(*) from public.character_seen_forms where creature_id = any (refs)),
      'form_favorites', (select count(*) from public.character_form_favorites where creature_id = any (refs)),
      'companions', (select count(*) from public.character_companions where creature_id = any (refs) or template_version_id = any (vids)),
      'transformations', (select count(*) from public.character_transformations where creature_id = any (refs)),
      'active_encounter_snapshots', (select count(*) from public.combat_statblocks s join public.combat_encounters e on e.id = s.encounter_id
                                     where s.source_id = any (refs) and e.status <> 'completed'));
  when 'background' then
    d := d || jsonb_build_object(
      'background_assignments', (select count(*) from public.character_backgrounds where version_id = any (refs)),
      'background_equipment', (select count(*) from public.character_background_equipment where version_id = any (refs)),
      'background_choices', (select count(*) from public.character_background_choices x join public.background_choices bc on bc.id = x.choice_id where bc.version_id = any (refs)));
  when 'lineage' then
    d := d || jsonb_build_object(
      'lineage_assignments', (select count(*) from public.character_lineages where version_id = any (refs) or subversion_id = any (refs)),
      'lineage_choices', (select count(*) from public.character_lineage_choices x join public.lineage_choices lc on lc.id = x.choice_id where lc.version_id = any (refs)));
  when 'condition' then
    d := d || jsonb_build_object('condition_assignments', (select count(*) from public.character_conditions where content_version_id = any (vids)));
  else null;
  end case;
  d := d || jsonb_build_object(
    -- a request the DM can still approve; a player's draft or a stale request is history (below)
    'pending_requests', (select count(*) from public.change_requests cr where cr.status in ('submitted', 'returned_for_changes', 'apply_failed')
                         and not cr.stale and exists (select 1 from unnest(refs) x where public._json_mentions(cr.ops::text, x))),
    -- only the published version of other content that is not archived depends on it
    'other_content', (select count(*) from public.dm_content_versions ov join public.dm_content oc on oc.id = ov.content_id
                      where ov.content_id <> p_content and ov.id = oc.published_version_id and oc.archived_at is null and oc.status <> 'archived'
                      and exists (select 1 from unnest(refs) x where public._json_mentions(ov.definition::text, x))));
  -- every key so far is current use, except inventory_history (history, never blocking)
  select coalesce(sum(value::int), 0) into cur from jsonb_each_text(d) where key <> 'inventory_history';
  -- history: kept for the record and readable after a delete; only completed encounter snapshots still block (creatures)
  d := d || jsonb_build_object(
    'completed_encounter_snapshots', case when c.content_type in ('creature', 'companion') then
        (select count(*) from public.combat_statblocks s join public.combat_encounters e on e.id = s.encounter_id where s.source_id = any (refs) and e.status = 'completed') else 0 end,
    'audit_references', (select count(*) from public.campaign_audit_events a where a.campaign_id is not distinct from c.campaign_id
                         and a.character_id is not null   -- a character's history (the content's own publish / archive events do not count)
                         and exists (select 1 from unnest(refs) x where public._json_mentions(coalesce(a.before::text, '') || coalesce(a.after::text, ''), x))),
    'earlier_assignments', (select count(*) from public.dm_content_events ev where ev.content_id = p_content and ev.event = 'assigned'),
    'request_history', (select count(*) from public.change_requests cr
                        where (cr.status = 'draft' or (cr.status in ('submitted', 'returned_for_changes', 'apply_failed') and cr.stale))
                        and exists (select 1 from unnest(refs) x where public._json_mentions(cr.ops::text, x))),
    'other_content_history', (select count(*) from public.dm_content_versions ov join public.dm_content oc on oc.id = ov.content_id
                              where ov.content_id <> p_content
                              and not (ov.id = oc.published_version_id and oc.archived_at is null and oc.status <> 'archived')
                              and exists (select 1 from unnest(refs) x where public._json_mentions(ov.definition::text, x))));
  hist := (d ->> 'completed_encounter_snapshots')::int + (d ->> 'audit_references')::int + (d ->> 'earlier_assignments')::int
          + coalesce((d ->> 'inventory_history')::int, 0) + (d ->> 'request_history')::int + (d ->> 'other_content_history')::int;
  n := (select count(distinct x.cid) from (
      select character_id as cid from public.character_spells where spell_version_id = any (refs)
      union all select ii.character_id from public.inventory_items ii where ii.item_id = any (refs)
      union all select character_id from public.character_feats where feat_version_id = any (refs)
      union all select character_id from public.character_lineage_choices where value = any (array(select 'feat:' || x from unnest(refs) x))
      union all select ch.character_id from public.character_feature_choice_values fv join public.character_feature_choices ch on ch.id = fv.character_choice_id
                where fv.value = any (array(select 'feat:' || x from unnest(refs) x))
      union all select character_id from public.character_seen_forms where creature_id = any (refs)
      union all select character_id from public.character_companions where creature_id = any (refs) or template_version_id = any (vids)
      union all select character_id from public.character_transformations where creature_id = any (refs)
      union all select character_id from public.character_backgrounds where version_id = any (refs)
      union all select character_id from public.character_lineages where version_id = any (refs) or subversion_id = any (refs)
      union all select character_id from public.character_conditions where content_version_id = any (vids)) x where x.cid is not null);
  return jsonb_build_object('counts', d, 'characters', n, 'current', cur, 'history', hist,
                            'blocking_history', (d ->> 'completed_encounter_snapshots')::int, 'published_versions', cardinality(refs),
                            'catalog_refs', to_jsonb(refs), 'base', base);
end $$;

create or replace function public.get_dm_content_usage_detail(p_content uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.dm_content; refs text[]; vids uuid[]; admin boolean; me uuid := auth.uid(); places jsonb; hidden int; total int;
  lim constant int := 200; d jsonb;
begin
  if me is null or not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content;
  select coalesce(array_agg(v.catalog_ref) filter (where v.catalog_ref is not null), '{}'), coalesce(array_agg(v.id), '{}')
    into refs, vids from public.dm_content_versions v where v.content_id = p_content;
  admin := public.is_admin();
  with uses as (
    -- inventory entries: character inventories, party stash, NPC, shop and personal stashes
    select 10 as ord, jsonb_build_object(
             'kind', case inv.kind when 'character' then 'character_inventory' when 'party_stash' then 'party_stash'
                                   when 'npc' then 'npc_inventory' when 'shop' then 'shop' else 'stash' end,
             'character_id', ch.id, 'character_name', ch.name, 'inventory_id', inv.id, 'inventory_name', inv.name,
             'entry_name', ii.name, 'quantity', ii.quantity, 'equipped', coalesce(ii.equipped, false), 'attuned', coalesce(ii.is_attuned, false),
             'in_container', ii.container_item_id is not null, 'blocks', true) as j,
           coalesce(ch.campaign_id, inv.campaign_id) as camp, inv.owner_id as owner
      from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
      left join public.characters ch on ch.id = inv.character_id
     where c.content_type = 'item' and ii.item_id = any (refs)
    union all
    -- other per-character uses (one row per character and kind of use)
    select 20, jsonb_build_object('kind', 'character', 'use', x.use, 'character_id', ch.id, 'character_name', ch.name, 'count', count(*), 'blocks', true),
           ch.campaign_id, null::uuid
      from (
        select character_id, 'owned asset' as use from public.owned_assets where c.content_type = 'item' and item_id = any (refs)
        union all select character_id, 'proficiency' from public.character_proficiencies where c.content_type = 'item' and item_id = any (refs)
        union all select character_id, 'knows or prepares the spell' from public.character_spells where c.content_type = 'spell' and spell_version_id = any (refs)
        union all select character_id, 'free-cast counter' from public.character_resources where c.content_type = 'spell' and spell_version_id = any (refs)
        union all select character_id, 'has the feat' from public.character_feats where c.content_type = 'feat' and feat_version_id = any (refs)
        union all select x.character_id, 'saved feat choice' from public.character_feat_choices x join public.feat_choices fc on fc.id = x.choice_id
                  where c.content_type = 'feat' and fc.version_id = any (refs)
        union all select character_id, 'lineage feat pick' from public.character_lineage_choices
                  where c.content_type = 'feat' and value = any (array(select 'feat:' || r from unnest(refs) r))
        union all select ch2.character_id, 'Ability Score Improvement feat pick' from public.character_feature_choice_values fv
                  join public.character_feature_choices ch2 on ch2.id = fv.character_choice_id
                  where c.content_type = 'feat' and fv.value = any (array(select 'feat:' || r from unnest(refs) r))
        union all select character_id, 'Wild Shape form known' from public.character_seen_forms where c.content_type in ('creature', 'companion') and creature_id = any (refs)
        union all select character_id, 'form favourite' from public.character_form_favorites where c.content_type in ('creature', 'companion') and creature_id = any (refs)
        union all select character_id, 'companion' from public.character_companions
                  where c.content_type in ('creature', 'companion') and (creature_id = any (refs) or template_version_id = any (vids))
        union all select character_id, 'active transformation' from public.character_transformations where c.content_type in ('creature', 'companion') and creature_id = any (refs)
        union all select character_id, 'background' from public.character_backgrounds where c.content_type = 'background' and version_id = any (refs)
        union all select character_id, 'background equipment' from public.character_background_equipment where c.content_type = 'background' and version_id = any (refs)
        union all select x.character_id, 'saved background choice' from public.character_background_choices x join public.background_choices bc on bc.id = x.choice_id
                  where c.content_type = 'background' and bc.version_id = any (refs)
        union all select character_id, 'lineage' from public.character_lineages where c.content_type = 'lineage' and (version_id = any (refs) or subversion_id = any (refs))
        union all select x.character_id, 'saved lineage choice' from public.character_lineage_choices x join public.lineage_choices lc on lc.id = x.choice_id
                  where c.content_type = 'lineage' and lc.version_id = any (refs)
        union all select character_id, 'applied condition' from public.character_conditions where c.content_type = 'condition' and content_version_id = any (vids)
      ) x join public.characters ch on ch.id = x.character_id
     group by x.use, ch.id, ch.name, ch.campaign_id
    union all
    -- change requests the DM can still approve (drafts and stale requests are history: counted only)
    select 30, jsonb_build_object('kind', 'request', 'request_id', cr.id, 'status', cr.status, 'title', cr.title,
                                  'character_id', ch.id, 'character_name', ch.name, 'submitted_at', cr.submitted_at, 'blocks', true),
           cr.campaign_id, null::uuid
      from public.change_requests cr join public.characters ch on ch.id = cr.character_id
     where cr.status in ('submitted', 'returned_for_changes', 'apply_failed') and not cr.stale
       and exists (select 1 from unnest(refs) r where public._json_mentions(cr.ops::text, r))
    union all
    -- encounters with a stat block snapshot of the creature (running / planned: current use; completed: encounter history)
    select 40, jsonb_build_object('kind', 'encounter', 'encounter_id', e.id, 'encounter_name', e.name, 'status', e.status, 'blocks', true),
           e.campaign_id, null::uuid
      from public.combat_encounters e
     where c.content_type in ('creature', 'companion')
       and exists (select 1 from public.combat_statblocks s where s.encounter_id = e.id and s.source_id = any (refs))
    union all
    -- 20261113000100: crafting recipes that name a version of the item (result, critical / failure result, ingredient)
    select 45, jsonb_build_object('kind', 'crafting_recipe', 'recipe_id', cr.id, 'recipe_name', cr.name, 'recipe_status', cr.status, 'blocks', true),
           cr.campaign_id, null::uuid
      from public.crafting_recipes cr
     where c.content_type = 'item'
       and (cr.output_item_id = any (refs) or cr.crit_output_item_id = any (refs) or cr.failure_output_item_id = any (refs)
            or exists (select 1 from public.crafting_recipe_ingredients g where g.recipe_id = cr.id and g.item_id = any (refs)))
    union all
    -- published, not archived content that names it
    select 50, jsonb_build_object('kind', 'other_content', 'content_id', oc.id, 'content_name', oc.name, 'content_type', oc.content_type,
                                  'status', oc.status, 'blocks', true),
           oc.campaign_id, case when oc.campaign_id is null then oc.author_id end
      from public.dm_content oc join public.dm_content_versions ov on ov.id = oc.published_version_id
     where oc.id <> p_content and oc.archived_at is null and oc.status <> 'archived'
       and exists (select 1 from unnest(refs) r where public._json_mentions(ov.definition::text, r))
  ), vis as (
    select ord, j, camp, (admin or (camp is not null and public.is_campaign_dm(camp)) or (camp is null and owner = me)) as visible from uses
  )
  select coalesce(jsonb_agg(v.j || jsonb_build_object('campaign_id', v.camp, 'campaign_name', k.name)
                            order by v.ord, v.j ->> 'character_name', v.j ->> 'inventory_name') filter (where v.visible), '[]'::jsonb),
         count(*) filter (where not v.visible), count(*) filter (where v.visible)
    into places, hidden, total
    from vis v left join public.campaigns k on k.id = v.camp;
  if jsonb_array_length(places) > lim then
    places := (select jsonb_agg(e) from (select e from jsonb_array_elements(places) with ordinality t(e, i) where i <= lim) s);
  end if;
  d := public._dm_content_dependencies(p_content) -> 'counts';
  return jsonb_build_object('content_id', c.id, 'name', c.name, 'content_type', c.content_type, 'archived', c.archived_at is not null,
    'places', places, 'total_places', total, 'truncated', total > lim, 'hidden_places', hidden,
    'history', jsonb_strip_nulls(jsonb_build_object(
      'inventory_history', d -> 'inventory_history', 'audit_references', d -> 'audit_references', 'earlier_assignments', d -> 'earlier_assignments',
      'request_history', d -> 'request_history', 'other_content_history', d -> 'other_content_history',
      'completed_encounter_snapshots', d -> 'completed_encounter_snapshots')));
end $$;

-- ---- 7. grants -------------------------------------------------------------------------------------------------------------------
revoke all on function public._craft_row_known(uuid), public._craft_item_known(uuid, text),
  public._craft_row_matches(text, public.crafting_recipe_ingredients), public._craft_row_free(uuid), public._craft_recipe_player(uuid, uuid),
  public._craft_attempt_player(public.crafting_attempts), public._craft_attempt_dm(public.crafting_attempts), public._craft_recipe_dm(uuid),
  public._craft_item_ok(text, uuid), public._craft_produce(uuid, uuid, text, int, boolean, jsonb), public._craft_apply(uuid, text, text),
  public._craft_audit(public.crafting_attempts), public._craft_player_gate(uuid), public._craft_dm_gate(uuid)
  from public, anon, authenticated;
revoke all on function public.get_character_recipes(uuid), public.start_craft_attempt(uuid, uuid, jsonb, int, uuid, text, text),
  public.cancel_craft_attempt(uuid), public.mark_recipes_seen(uuid), public.dm_save_recipe(uuid, jsonb, int),
  public.dm_set_recipe_status(uuid, text), public.dm_grant_recipe(uuid, uuid[], boolean),
  public.dm_resolve_craft_attempt(uuid, text, text, int, text, text, text, int), public.get_campaign_recipes(uuid),
  public.get_campaign_craft_attempts(uuid, text), public.get_campaign_pending_craft_count(uuid), public.get_campaign_craft_items(uuid, text)
  from public, anon;
grant execute on function public.get_character_recipes(uuid), public.start_craft_attempt(uuid, uuid, jsonb, int, uuid, text, text),
  public.cancel_craft_attempt(uuid), public.mark_recipes_seen(uuid), public.dm_save_recipe(uuid, jsonb, int),
  public.dm_set_recipe_status(uuid, text), public.dm_grant_recipe(uuid, uuid[], boolean),
  public.dm_resolve_craft_attempt(uuid, text, text, int, text, text, text, int), public.get_campaign_recipes(uuid),
  public.get_campaign_craft_attempts(uuid, text), public.get_campaign_pending_craft_count(uuid), public.get_campaign_craft_items(uuid, text)
  to authenticated, service_role;

notify pgrst, 'reload schema';
