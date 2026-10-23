-- =============================================================================
-- 20261019000800: materialize the feats of characters that existed before the feat engine.
-- 20261019000300 resolves feat grants (background Origin feats, lineage and ASI feat choices) on read, but their resources
-- and spells are materialized by _sync_character_feats, which only ran when a grant source changed afterwards. A character
-- whose 2024 background already granted Lucky therefore had no Luck Points until its background was touched.
-- Idempotent (the sync adds what is missing and removes only what no grant gives any more); it changes no ability, HP or
-- choice, and feats whose own choices are still open (Magic Initiate spells) stay pending until the player chooses.
-- Rollback: supabase/rollback/rollback_feat_backfill.sql (bookkeeping only; feat rows go with rollback_feat_catalog.sql).
-- =============================================================================

do $$
declare c uuid;
begin
  for c in select id from public.characters order by id loop
    perform public._sync_character_feats(c);
  end loop;
end $$;
