-- Item visibility snapshot (T4b, 20261112000400): READ-ONLY. Run it before and after the migration and diff the two outputs:
-- they must be identical when nothing changed for anyone. No names, ids or values are printed: only indexes (by id order) and
-- 12-character hashes. Every read runs AS THAT USER (role authenticated + their JWT subject, so RLS applies).
--   psql -v ON_ERROR_STOP=1 -f scripts/fluent/item_visibility_snapshot.sql 2>&1 | grep -E 'snapshot|char |user '
-- The whole script runs in a READ ONLY transaction and calls only stable reads (never get_character_reads / _view / _bundle,
-- which write tl_cache). Hashed columns / keys exist both before and after 20261112000400 (they all come from 20261112000300).
-- Every row is hashed as json_build_array(<columns>)::text, so a null and an empty string hash differently.
-- Section 1, one line per CHARACTER, read as the character's owner:
--   inv   v_inventory_detail rows of the character's inventories:
--         id, inventory_kind, name, custom_name, description, item_id, kind_id, category_id, rarity_id, is_magic,
--         requires_attunement, knowledge_state, quantity
--   cat   catalog rows the owner can read (items RLS) among campaign items (campaign_id set) and secret items:
--         id, name, description, kind_id, rarity_id, is_magic
--   know  get_character_item_knowledge(character), every element projected to the keys
--         inventory_item_id, state, display_name, magic_known, revealed, facts, properties, curse, true_name, item_id, kind_id,
--         description, details, identify  (sorted by inventory_item_id)
--   stash v_inventory_detail rows of party stash / shop inventories of the character's campaign the owner can read
--         (same columns as inv)
-- Section 2, one line per USER (every profile and every campaign member, DMs and members without characters included):
--   cat   catalog rows the user can read among campaign items, secret items and custom items (owner_id set):
--         id, name, description, kind_id, rarity_id, is_magic, secret
--   stash every v_inventory_detail row of a non-character inventory (party stash, shop, NPC, stash) the user can read
--         (same columns as inv)
begin read only;
do $$
declare ids uuid[]; owners uuid[]; camps uuid[]; users uuid[]; i int; h_inv text; h_cat text; h_know text; h_stash text;
  n_inv int; n_cat int; n_know int; n_stash int; kn jsonb; err text;
  rowcols constant text := 'id, inventory_kind, name, custom_name, description, item_id, kind_id, category_id, rarity_id, is_magic, requires_attunement, knowledge_state, quantity';
  keys constant text[] := array['inventory_item_id', 'state', 'display_name', 'magic_known', 'revealed', 'facts', 'properties', 'curse',
    'true_name', 'item_id', 'kind_id', 'description', 'details', 'identify'];
begin
  select array_agg(id order by id), array_agg(owner_id order by id), array_agg(campaign_id order by id) into ids, owners, camps from public.characters;
  select array_agg(u order by u) into users
    from (select p.id as u from public.profiles p union select m.user_id from public.campaign_members m where m.user_id is not null) x;
  raise notice 'snapshot columns inv/stash: %', rowcols;
  raise notice 'snapshot keys know: %', array_to_string(keys, ',');
  raise notice 'snapshot % characters, % users', coalesce(cardinality(ids), 0), coalesce(cardinality(users), 0);
  -- ---- section 1: per character, as its owner
  for i in 1 .. coalesce(cardinality(ids), 0) loop
    perform set_config('request.jwt.claims', json_build_object('sub', owners[i], 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', coalesce(owners[i]::text, ''), true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    set local role authenticated;
    select left(md5(coalesce(string_agg(json_build_array(d.id, d.inventory_kind, d.name, d.custom_name, d.description, d.item_id, d.kind_id,
             d.category_id, d.rarity_id, d.is_magic, d.requires_attunement, d.knowledge_state, d.quantity)::text, E'\n' order by d.id), '')), 12), count(*)
      into h_inv, n_inv
      from public.v_inventory_detail d join public.inventories inv on inv.id = d.inventory_id where inv.character_id = ids[i];
    select left(md5(coalesce(string_agg(json_build_array(it.id, it.name, it.description, it.kind_id, it.rarity_id, it.is_magic)::text, E'\n' order by it.id), '')), 12), count(*)
      into h_cat, n_cat
      from public.items it where it.campaign_id is not null or it.secret;
    err := null;
    begin
      kn := public.get_character_item_knowledge(ids[i]);
    exception when others then err := sqlstate; kn := null;
    end;
    select left(md5(coalesce(string_agg(p.j::text, E'\n' order by p.k), coalesce(err, ''))), 12), count(*)
      into h_know, n_know
      from (select x ->> 'inventory_item_id' as k,
                   (select jsonb_object_agg(kk, x -> kk) from unnest(keys) kk where x ? kk) as j
            from jsonb_array_elements(coalesce(kn, '[]'::jsonb)) x) p;
    select left(md5(coalesce(string_agg(json_build_array(d.id, d.inventory_kind, d.name, d.custom_name, d.description, d.item_id, d.kind_id,
             d.category_id, d.rarity_id, d.is_magic, d.requires_attunement, d.knowledge_state, d.quantity)::text, E'\n' order by d.id), '')), 12)
      into h_stash
      from public.v_inventory_detail d join public.inventories inv on inv.id = d.inventory_id
      where inv.character_id is null and inv.kind in ('party_stash', 'shop') and camps[i] is not null and inv.campaign_id = camps[i];
    raise notice 'char % inv % (% rows) cat % (% rows) know % (% rows) stash %', i, h_inv, n_inv, h_cat, n_cat, h_know, n_know, h_stash;
    set local role postgres;
  end loop;
  -- ---- section 2: per user (profiles and campaign members), as that user
  for i in 1 .. coalesce(cardinality(users), 0) loop
    perform set_config('request.jwt.claims', json_build_object('sub', users[i], 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', users[i]::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    set local role authenticated;
    select left(md5(coalesce(string_agg(json_build_array(it.id, it.name, it.description, it.kind_id, it.rarity_id, it.is_magic, it.secret)::text,
             E'\n' order by it.id), '')), 12), count(*)
      into h_cat, n_cat
      from public.items it where it.campaign_id is not null or it.secret or it.owner_id is not null;
    select left(md5(coalesce(string_agg(json_build_array(d.id, d.inventory_kind, d.name, d.custom_name, d.description, d.item_id, d.kind_id,
             d.category_id, d.rarity_id, d.is_magic, d.requires_attunement, d.knowledge_state, d.quantity)::text, E'\n' order by d.id), '')), 12), count(*)
      into h_stash, n_stash
      from public.v_inventory_detail d join public.inventories inv on inv.id = d.inventory_id
      where inv.character_id is null;
    raise notice 'user % cat % (% rows) stash % (% rows)', i, h_cat, n_cat, h_stash, n_stash;
    set local role postgres;
  end loop;
end $$;
rollback;
