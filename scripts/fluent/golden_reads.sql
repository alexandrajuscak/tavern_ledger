-- Fluent read release 20261030000100: golden check, READ-ONLY. Prints one NOTICE line per character and read: a character index
-- (by id order) and a 12-character hash. No names, ids or values. Every call runs as the character's owner (RLS applies).
--   before the migration:  the direct RPCs only                               -> golden_before.txt
--   after the migration:   the direct RPCs again (must equal before) and the same reads through get_character_view /
--                          get_character_bundle (must equal the direct ones)  -> golden_after.txt, view lines
-- Normalization (as scripts/incident/golden_derived.sql): the class proficiency list inside the derived stats is compared as a
-- sorted set (its order was never defined); everything else byte-identical.
do $$
declare ids uuid[]; owners uuid[]; i int; n text; v jsonb; bnd jsonb; direct jsonb; x jsonb; h text; k int; has_view boolean;
  reads constant text[] := array['get_character_derived_stats', 'get_character_proficiencies', 'get_character_lineage',
    'get_character_background', 'get_character_feats', 'get_character_class_summary', 'get_character_spell_slots',
    'get_character_class_features', 'get_character_resources', 'get_character_states', 'get_character_transformation',
    'get_character_infusions', 'get_character_governance', 'get_character_spellbook'];
begin
  has_view := to_regprocedure('public.get_character_view(uuid,text)') is not null;
  select array_agg(id order by id), array_agg(owner_id order by id) into ids, owners from public.characters;
  for i in 1 .. coalesce(cardinality(ids), 0) loop
    perform set_config('request.jwt.claims', json_build_object('sub', owners[i], 'role', 'authenticated')::text, true);
    set local role authenticated;
    if has_view then
      v := public.get_character_view(ids[i], 'spells');
      bnd := public.get_character_bundle(ids[i], 'inventory');
      raise notice 'char % view_errors %', i, coalesce((select string_agg(ek, ',') from jsonb_object_keys(v -> 'errors') ek), 'none');
    end if;
    foreach n in array reads loop
      execute format('select public.%I($1)', n) into direct using ids[i];
      for k in 1 .. case when has_view then 2 else 1 end loop
        x := case k when 1 then direct else v -> 'reads' -> n end;
        h := case when n = 'get_character_derived_stats' and x is not null
               then left(md5((x - 'proficiencies')::text), 12) || '/' || left(md5(coalesce((select string_agg(e::text, '|' order by e::text)
                    from jsonb_array_elements(x -> 'proficiencies') e), '')), 12)
               else left(md5(coalesce(x::text, 'null')), 12) end;
        raise notice 'char % % % %', i, n, case k when 1 then 'direct' else 'via-view' end, h;
      end loop;
    end loop;
    raise notice 'char % runtime %', i, left(md5((select jsonb_build_object('hp', hp_current, 'hp_max', hp_max, 'temp', hp_temp,
      'insp', inspiration, 'ds', death_successes, 'df', death_failures, 'coins', array[cp, sp, ep, gp, pp], 'cond', conditions)::text
      from public.characters where id = ids[i])), 12);
    raise notice 'char % visible conditions % hidden-visible %', i,
      (select count(*) from public.character_conditions where character_id = ids[i]),
      (select count(*) from public.character_conditions where character_id = ids[i] and hidden);
    if has_view then
      raise notice 'char % inventory_rows direct % via-bundle %', i,
        left(md5((select coalesce(jsonb_agg(to_jsonb(d) order by d.sort_order, d.acquired_at, d.id), '[]') from public.v_inventory_detail d
          join public.inventories inv on inv.id = d.inventory_id where inv.character_id = ids[i] and inv.kind = 'character')::text), 12),
        left(md5(coalesce(bnd -> 'reads' -> 'inventory_bundle' -> 'rows', '[]')::text), 12);
    end if;
    set local role postgres;
  end loop;
end $$;
