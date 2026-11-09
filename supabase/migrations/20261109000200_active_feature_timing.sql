-- Play timing of official lineage traits and feats (docs/ACTIVE_GAMEPLAY_FEATURE_AUDIT.md). ADDITIVE: one new catalog table;
-- no existing row of any table is changed.
--
-- The Play tab groups what a character can use by timing (Actions, Bonus actions, Reactions, Free and special). Class features
-- and class options already carry a timing (class_feature_versions.activation; 20261107000400 for options). Lineage traits and
-- feats did not, so their actions (Breath Weapon, Healing Hands, Rabbit Hop, Relentless Endurance, Interception, Telekinetic
-- shove ...) were only readable on the Build tab. This table records, per stable catalog id, the timing the catalog SUMMARY TEXT
-- itself states ("Bonus action: ...", "as an action", "Reaction: ...", "once per turn ..."); no timing is invented: a trait with
-- uses but no stated timing is 'resource' (shown with its counter), a combat-relevant passive is 'reminder'.
--   play = card      shown as a card under its timing
--   play = resource  shown in Ready to use with its counter (the counter itself is the existing lineage resource)
--   play = reminder  one line under Passives and reminders
-- Rows: 135 lineage traits + 22 feat versions = 157, official catalog only (content_version_id is null). Rows whose id is not
-- in the catalog are skipped (counted below); the migration refuses to run if the matched count differs from the expected one.
-- An empty catalog (a database built from zero, seeds not loaded yet) is skipped: supabase/seed/catalog_play_timing.sql
-- carries the identical block. Campaign custom content has no row (its Play presentation follows its uses and automation). Rollback:
-- supabase/rollback/rollback_active_feature_timing.sql (drops the table).

create table if not exists public.catalog_play_timing (
  source_kind text not null check (source_kind in ('lineage_trait', 'feat_version')),
  source_id   text not null,
  timing      text check (timing in ('action', 'bonus_action', 'reaction', 'special')),
  play        text not null check (play in ('card', 'resource', 'reminder')),
  check (play <> 'card' or timing is not null),
  primary key (source_kind, source_id)
);
comment on table public.catalog_play_timing is 'Play presentation of official lineage traits and feats: the timing stated by the catalog text (20261109000200).';
alter table public.catalog_play_timing enable row level security;
drop policy if exists catalog_play_timing_read on public.catalog_play_timing;
create policy catalog_play_timing_read on public.catalog_play_timing for select to anon, authenticated using (true);
revoke all on public.catalog_play_timing from anon, authenticated;
grant select on public.catalog_play_timing to anon, authenticated;
-- the read-cache counter every public table carries (a change would invalidate the global catalog revision)
drop trigger if exists tl_cache_rev on public.catalog_play_timing;
create trigger tl_cache_rev after insert or update or delete on public.catalog_play_timing
  for each row execute function tl_cache.bump('global');

do $$
declare matched int; inserted int;
begin
  -- a database built from zero runs the migrations before the catalog seeds: nothing to match yet. The same rows are then
  -- loaded by supabase/seed/catalog_play_timing.sql (identical block). Production always has the catalog (157 / 157).
  if not exists (select 1 from public.lineage_traits) and not exists (select 1 from public.feat_versions) then
    raise notice 'catalog_play_timing: the catalog is empty (fresh database); rows come from supabase/seed/catalog_play_timing.sql';
    return;
  end if;
  create temp table _cpt (source_kind text, source_id text, timing text, play text) on commit drop;
  insert into _cpt values
  ('lineage_trait', 'aarakocra-eepc:talons', null, 'reminder'),
  ('lineage_trait', 'aarakocra-mpmm:talons', null, 'reminder'),
  ('lineage_trait', 'aasimar-fallen:necrotic-shroud', 'action', 'card'),
  ('lineage_trait', 'aasimar-mpmm:celestial-resistance', null, 'reminder'),
  ('lineage_trait', 'aasimar-mpmm:celestial-revelation', 'bonus_action', 'card'),
  ('lineage_trait', 'aasimar-mpmm:healing-hands', 'action', 'card'),
  ('lineage_trait', 'aasimar-protector:radiant-soul', 'action', 'card'),
  ('lineage_trait', 'aasimar-scourge:radiant-consumption', 'action', 'card'),
  ('lineage_trait', 'aasimar-vgm:celestial-resistance', null, 'reminder'),
  ('lineage_trait', 'aasimar-vgm:healing-hands', 'action', 'card'),
  ('lineage_trait', 'bugbear-mpmm:fey-ancestry', null, 'reminder'),
  ('lineage_trait', 'centaur-ggr:charge', 'bonus_action', 'card'),
  ('lineage_trait', 'centaur-ggr:hooves', null, 'reminder'),
  ('lineage_trait', 'centaur-mot:charge', 'bonus_action', 'card'),
  ('lineage_trait', 'centaur-mot:hooves', null, 'reminder'),
  ('lineage_trait', 'centaur-mpmm:charge', 'bonus_action', 'card'),
  ('lineage_trait', 'centaur-mpmm:hooves', null, 'reminder'),
  ('lineage_trait', 'changeling-erlw:shapechanger', 'action', 'card'),
  ('lineage_trait', 'changeling-mpmm:shapechanger', 'action', 'card'),
  ('lineage_trait', 'deep-gnome-mpmm:svirfneblin-camouflage', null, 'resource'),
  ('lineage_trait', 'dragonborn-chromatic:breath-weapon', 'action', 'card'),
  ('lineage_trait', 'dragonborn-chromatic:chromatic-warding', 'action', 'card'),
  ('lineage_trait', 'dragonborn-chromatic:draconic-resistance', null, 'reminder'),
  ('lineage_trait', 'dragonborn-draconblood:forceful-presence', null, 'resource'),
  ('lineage_trait', 'dragonborn-gem:breath-weapon', 'action', 'card'),
  ('lineage_trait', 'dragonborn-gem:draconic-resistance', null, 'reminder'),
  ('lineage_trait', 'dragonborn-gem:gem-flight', 'bonus_action', 'card'),
  ('lineage_trait', 'dragonborn-metallic:breath-weapon', 'action', 'card'),
  ('lineage_trait', 'dragonborn-metallic:draconic-resistance', null, 'reminder'),
  ('lineage_trait', 'dragonborn-metallic:metallic-breath-weapon', null, 'resource'),
  ('lineage_trait', 'dragonborn-phb:breath-weapon', 'action', 'card'),
  ('lineage_trait', 'dragonborn-phb:damage-resistance', null, 'reminder'),
  ('lineage_trait', 'dragonborn-ravenite:vengeful-assault', 'reaction', 'card'),
  ('lineage_trait', 'duergar-mpmm:dwarven-resilience', null, 'reminder'),
  ('lineage_trait', 'duergar-mpmm:psionic-fortitude', null, 'reminder'),
  ('lineage_trait', 'duergar-scag:duergar-resilience', null, 'reminder'),
  ('lineage_trait', 'duergar-scag:dwarven-resilience', null, 'reminder'),
  ('lineage_trait', 'dwarf-phb:dwarven-resilience', null, 'reminder'),
  ('lineage_trait', 'eladrin-mpmm:fey-ancestry', null, 'reminder'),
  ('lineage_trait', 'eladrin-mpmm:fey-step', 'bonus_action', 'card'),
  ('lineage_trait', 'eladrin-mtf:fey-ancestry', null, 'reminder'),
  ('lineage_trait', 'eladrin-mtf:fey-step', 'bonus_action', 'card'),
  ('lineage_trait', 'elf-phb:fey-ancestry', null, 'reminder'),
  ('lineage_trait', 'firbolg-mpmm:hidden-step', 'bonus_action', 'card'),
  ('lineage_trait', 'firbolg-vgm:hidden-step', 'bonus_action', 'card'),
  ('lineage_trait', 'genasi-air-mpmm:lightning-resistance', null, 'reminder'),
  ('lineage_trait', 'genasi-earth-mpmm:merge-with-stone', 'bonus_action', 'card'),
  ('lineage_trait', 'genasi-fire-eepc:fire-resistance', null, 'reminder'),
  ('lineage_trait', 'genasi-fire-mpmm:fire-resistance', null, 'reminder'),
  ('lineage_trait', 'genasi-water-eepc:acid-resistance', null, 'reminder'),
  ('lineage_trait', 'genasi-water-mpmm:acid-resistance', null, 'reminder'),
  ('lineage_trait', 'githyanki-mpmm:psychic-resilience', null, 'reminder'),
  ('lineage_trait', 'githzerai-mpmm:mental-discipline', null, 'reminder'),
  ('lineage_trait', 'githzerai-mpmm:psychic-resilience', null, 'reminder'),
  ('lineage_trait', 'githzerai-mtf:mental-discipline', null, 'reminder'),
  ('lineage_trait', 'goblin-dankwood:nimble-escape', 'bonus_action', 'card'),
  ('lineage_trait', 'goblin-mpmm:fey-ancestry', null, 'reminder'),
  ('lineage_trait', 'goblin-mpmm:fury-of-the-small', 'special', 'card'),
  ('lineage_trait', 'goblin-mpmm:nimble-escape', 'bonus_action', 'card'),
  ('lineage_trait', 'goblin-vgm:fury-of-the-small', null, 'resource'),
  ('lineage_trait', 'goblin-vgm:nimble-escape', 'bonus_action', 'card'),
  ('lineage_trait', 'goliath-eepc:mountain-born', null, 'reminder'),
  ('lineage_trait', 'goliath-eepc:stones-endurance', 'reaction', 'card'),
  ('lineage_trait', 'goliath-mpmm:mountain-born', null, 'reminder'),
  ('lineage_trait', 'goliath-mpmm:stones-endurance', 'reaction', 'card'),
  ('lineage_trait', 'grung-oga:poison-immunity', null, 'reminder'),
  ('lineage_trait', 'half-elf-mark-of-storm:storms-boon', null, 'reminder'),
  ('lineage_trait', 'half-elf-phb:fey-ancestry', null, 'reminder'),
  ('lineage_trait', 'half-orc-phb:relentless-endurance', 'special', 'card'),
  ('lineage_trait', 'half-orc-phb:savage-attacks', null, 'reminder'),
  ('lineage_trait', 'halfling-phb:brave', null, 'reminder'),
  ('lineage_trait', 'halfling-phb:lucky', null, 'reminder'),
  ('lineage_trait', 'halfling-stout:stout-resilience', null, 'reminder'),
  ('lineage_trait', 'harengon-mpmm:lucky-footwork', 'reaction', 'card'),
  ('lineage_trait', 'harengon-mpmm:rabbit-hop', 'bonus_action', 'card'),
  ('lineage_trait', 'harengon-wbw:lucky-footwork', 'reaction', 'card'),
  ('lineage_trait', 'harengon-wbw:rabbit-hop', 'bonus_action', 'card'),
  ('lineage_trait', 'hobgoblin-mpmm:fey-ancestry', null, 'reminder'),
  ('lineage_trait', 'hobgoblin-mpmm:fey-gift', 'bonus_action', 'card'),
  ('lineage_trait', 'hobgoblin-mpmm:fortune-from-the-many', 'special', 'card'),
  ('lineage_trait', 'hobgoblin-vgm:saving-face', 'special', 'card'),
  ('lineage_trait', 'human-mark-of-sentinel:vigilant-guardian', 'reaction', 'card'),
  ('lineage_trait', 'kenku-mpmm:kenku-recall', null, 'resource'),
  ('lineage_trait', 'kobold-mpmm:draconic-cry', 'bonus_action', 'card'),
  ('lineage_trait', 'kobold-vgm:grovel-cower-and-beg', 'action', 'card'),
  ('lineage_trait', 'lizardfolk-mpmm:bite', null, 'reminder'),
  ('lineage_trait', 'lizardfolk-mpmm:hungry-jaws', 'bonus_action', 'card'),
  ('lineage_trait', 'lizardfolk-vgm:bite', null, 'reminder'),
  ('lineage_trait', 'lizardfolk-vgm:hungry-jaws', 'bonus_action', 'card'),
  ('lineage_trait', 'locathah-lr:leviathan-will', null, 'reminder'),
  ('lineage_trait', 'minotaur-ggr:goring-rush', 'bonus_action', 'card'),
  ('lineage_trait', 'minotaur-ggr:hammering-horns', 'bonus_action', 'card'),
  ('lineage_trait', 'minotaur-ggr:horns', null, 'reminder'),
  ('lineage_trait', 'minotaur-mot:goring-rush', 'bonus_action', 'card'),
  ('lineage_trait', 'minotaur-mot:hammering-horns', 'bonus_action', 'card'),
  ('lineage_trait', 'minotaur-mot:horns', null, 'reminder'),
  ('lineage_trait', 'minotaur-mpmm:goring-rush', 'bonus_action', 'card'),
  ('lineage_trait', 'minotaur-mpmm:hammering-horns', 'bonus_action', 'card'),
  ('lineage_trait', 'minotaur-mpmm:horns', null, 'reminder'),
  ('lineage_trait', 'orc-egw:aggressive', 'bonus_action', 'card'),
  ('lineage_trait', 'orc-erlw:aggressive', 'bonus_action', 'card'),
  ('lineage_trait', 'orc-mpmm:adrenaline-rush', 'bonus_action', 'card'),
  ('lineage_trait', 'orc-mpmm:relentless-endurance', 'special', 'card'),
  ('lineage_trait', 'orc-vgm:aggressive', 'bonus_action', 'card'),
  ('lineage_trait', 'satyr-mot:magic-resistance', null, 'reminder'),
  ('lineage_trait', 'satyr-mot:ram', null, 'reminder'),
  ('lineage_trait', 'satyr-mpmm:magic-resistance', null, 'reminder'),
  ('lineage_trait', 'satyr-mpmm:ram', null, 'reminder'),
  ('lineage_trait', 'sea-elf-mpmm:child-of-the-sea', null, 'reminder'),
  ('lineage_trait', 'sea-elf-mpmm:fey-ancestry', null, 'reminder'),
  ('lineage_trait', 'sea-elf-mtf:fey-ancestry', null, 'reminder'),
  ('lineage_trait', 'shadar-kai-mpmm:blessing-of-the-raven-queen', 'bonus_action', 'card'),
  ('lineage_trait', 'shadar-kai-mpmm:fey-ancestry', null, 'reminder'),
  ('lineage_trait', 'shadar-kai-mpmm:necrotic-resistance', null, 'reminder'),
  ('lineage_trait', 'shadar-kai-mtf:blessing-of-the-raven-queen', 'bonus_action', 'card'),
  ('lineage_trait', 'shadar-kai-mtf:fey-ancestry', null, 'reminder'),
  ('lineage_trait', 'shadar-kai-mtf:necrotic-resistance', null, 'reminder'),
  ('lineage_trait', 'shifter-erlw:shifting', 'bonus_action', 'card'),
  ('lineage_trait', 'shifter-mpmm:shifting', 'bonus_action', 'card'),
  ('lineage_trait', 'shifter-swiftstride:shifting-feature', 'reaction', 'card'),
  ('lineage_trait', 'shifter-wildhunt:mark-the-scent', 'bonus_action', 'card'),
  ('lineage_trait', 'tabaxi-mpmm:cats-claws', null, 'reminder'),
  ('lineage_trait', 'tabaxi-vgm:cats-claws', null, 'reminder'),
  ('lineage_trait', 'tiefling-phb:hellish-resistance', null, 'reminder'),
  ('lineage_trait', 'tortle-mpmm:claws', null, 'reminder'),
  ('lineage_trait', 'tortle-mpmm:shell-defense', 'action', 'card'),
  ('lineage_trait', 'tortle-ttp:claws', null, 'reminder'),
  ('lineage_trait', 'tortle-ttp:shell-defense', 'action', 'card'),
  ('lineage_trait', 'triton-mpmm:guardian-of-the-depths', null, 'reminder'),
  ('lineage_trait', 'triton-vgm:guardians-of-the-depths', null, 'reminder'),
  ('lineage_trait', 'verdan-ai:black-blood-healing', null, 'reminder'),
  ('lineage_trait', 'yuan-ti-mpmm:magic-resistance', null, 'reminder'),
  ('lineage_trait', 'yuan-ti-mpmm:poison-resilience', null, 'reminder'),
  ('lineage_trait', 'yuan-ti-vgm:magic-resistance', null, 'reminder'),
  ('lineage_trait', 'yuan-ti-vgm:poison-immunity', null, 'reminder'),
  ('feat_version', 'alert-2014', null, 'reminder'),
  ('feat_version', 'boon-of-combat-prowess-2024', 'special', 'card'),
  ('feat_version', 'boon-of-energy-resistance-2024', 'special', 'card'),
  ('feat_version', 'boon-of-fortune-s-favor-2024', null, 'reminder'),
  ('feat_version', 'defensive-duelist-2014', 'reaction', 'card'),
  ('feat_version', 'durable-2024', 'bonus_action', 'card'),
  ('feat_version', 'elemental-adept-2014', null, 'reminder'),
  ('feat_version', 'elemental-adept-2024', null, 'reminder'),
  ('feat_version', 'healer-2024', null, 'reminder'),
  ('feat_version', 'infernal-constitution-2014', null, 'reminder'),
  ('feat_version', 'interception-2024', 'reaction', 'card'),
  ('feat_version', 'keen-mind-2024', 'bonus_action', 'card'),
  ('feat_version', 'mage-slayer-2014', 'reaction', 'card'),
  ('feat_version', 'observant-2024', 'bonus_action', 'card'),
  ('feat_version', 'protection-2024', 'reaction', 'card'),
  ('feat_version', 'savage-attacker-2014', 'special', 'card'),
  ('feat_version', 'savage-attacker-2024', 'special', 'card'),
  ('feat_version', 'tavern-brawler-2014', 'bonus_action', 'card'),
  ('feat_version', 'tavern-brawler-2024', null, 'reminder'),
  ('feat_version', 'telekinetic-2014', 'bonus_action', 'card'),
  ('feat_version', 'telekinetic-2024', 'bonus_action', 'card'),
  ('feat_version', 'unarmed-fighting-2024', null, 'reminder');
  select count(*) into matched from _cpt x
  where (x.source_kind = 'lineage_trait' and exists (select 1 from public.lineage_traits t join public.lineage_versions v on v.id = t.version_id
                                                      where t.id = x.source_id and v.content_version_id is null))
     or (x.source_kind = 'feat_version' and exists (select 1 from public.feat_versions f where f.id = x.source_id and f.content_version_id is null));
  if matched <> 157 then
    raise exception 'catalog_play_timing: % of 157 expected catalog ids matched; refusing to apply', matched;
  end if;
  insert into public.catalog_play_timing (source_kind, source_id, timing, play)
  select source_kind, source_id, nullif(timing, ''), play from _cpt
  on conflict (source_kind, source_id) do nothing;
  get diagnostics inserted = row_count;
  raise notice 'catalog_play_timing: matched %, inserted %, skipped (already present) %', matched, inserted, matched - inserted;
end $$;
