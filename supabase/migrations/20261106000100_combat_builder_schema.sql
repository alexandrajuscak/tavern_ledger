-- =============================================================================
-- Combat Builder, part 1: schema (docs/COMBAT_DATA_MODEL.md, docs/COMBAT_PERMISSIONS.md, docs/COMBAT_REALTIME.md).
-- Additive only: new tables, policies, grants, indexes and two catalog tables. No existing table, function or row changes.
-- Rollback: supabase/rollback/rollback_combat_builder_schema.sql (after rollback_combat_builder_functions.sql).
--
-- Existing data: nothing is read or rewritten. The catalog rows come from supabase/seed/combat_monsters.sql (idempotent).
--
-- Read cache (20261030000200): every public table must carry a trigger named tl_cache_rev (progressive_read_tests.sql).
--   * The catalog tables below use the normal 'global' counter: they only change when the seed is loaded.
--   * The combat runtime tables use tl_cache.combat_skip(): no cached character read reads them, so a turn, a monster's HP
--     or an effect must never invalidate the cached character reads of every user (that would reopen the 57014 path).
--     None of these tables has a character_id column (linked characters use linked_character_id), so the coverage
--     test's "character tables use the character counter" rule does not apply to them.
--   Linked player HP is written to public.characters by the HP RPCs; tl_cache.bump already ignores runtime-only columns.
--
-- Lock order of every combat mutation (docs/COMBAT_REALTIME.md "Concurrency"):
--   1. combat_encounters row (FOR NO KEY UPDATE for turn / structure changes, FOR SHARE for HP and effects)
--   2. combat_participants rows (FOR UPDATE, in id order when several)
--   3. the linked public.characters row (FOR UPDATE; the Wild Shape functions take the same lock first)
--   4. character_transformations / tl_cache / character_revisions (written by existing triggers and functions)
--   5. combat_effects, combat_events, combat_changes (inserts / updates last)
--   No trigger on characters or any character table touches combat tables, so the reverse order never happens.
-- =============================================================================

-- ------------------------------------------------------------------------------------------------- 1. catalogs (read only)

-- SRD 5.2.1 stat blocks (2024 rules). Combat-only: not part of public.creatures, so never a Wild Shape form or companion.
create table if not exists public.combat_monsters (
  id                   text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name                 text not null check (length(name) between 1 and 120),
  rules_version        text not null check (rules_version in ('2014', '2024')),
  size                 text not null check (size in ('Tiny', 'Small', 'Medium', 'Large', 'Huge', 'Gargantuan')),
  creature_type        text not null,
  subtype              text,
  alignment            text,
  armor_class          int not null check (armor_class between 0 and 40),
  hit_points           int not null check (hit_points between 1 and 2000),
  hit_dice             text,
  initiative_modifier  int not null default 0,
  initiative_score     int,
  speed                jsonb not null default '{}' check (jsonb_typeof(speed) = 'object'),
  challenge_rating     numeric(5,3) not null check (challenge_rating >= 0),
  xp                   int,
  proficiency_bonus    int,
  legendary_uses       int check (legendary_uses between 1 and 10),
  statblock            jsonb not null check (jsonb_typeof(statblock) = 'object'),
  source_label         text not null,
  source_ref           text not null,
  source_url           text,
  license              text not null,
  attribution_required boolean not null default true,
  archived_at          timestamptz,
  created_at           timestamptz not null default now()
);
comment on table public.combat_monsters is
  'Combat Builder monster catalog: SRD 5.2.1 stat blocks (CC-BY-4.0, attribution in docs/COMBAT_RULES_AND_LICENSING.md). Seed supabase/seed/combat_monsters.sql. Combat-only (not Wild Shape / companion forms).';
create index if not exists combat_monsters_cr on public.combat_monsters (challenge_rating);
create index if not exists combat_monsters_type on public.combat_monsters (creature_type);

-- SRD 5.1 Legendary Actions of creatures already in public.creatures (that table keeps only a legendary flag)
create table if not exists public.creature_legendary_actions (
  creature_id  text primary key references public.creatures (id) on delete cascade,
  uses         int not null default 3 check (uses between 1 and 10),
  actions      jsonb not null check (jsonb_typeof(actions) = 'array'),
  source_label text not null,
  license      text not null
);
comment on table public.creature_legendary_actions is 'SRD 5.1 Legendary Actions (CC-BY-4.0) for the Combat Builder. Seed supabase/seed/combat_monsters.sql.';

-- Conditions per ruleset: short project-authored summaries of the SRD definitions (docs/COMBAT_RULES_AND_LICENSING.md)
create table if not exists public.combat_conditions (
  ruleset        text not null check (ruleset in ('2014', '2024')),
  key            text not null check (key ~ '^[a-z]+$'),
  name           text not null,
  summary        text not null,
  incapacitating boolean not null default false,   -- implies Incapacitated: ends Concentration (after the DM confirms)
  initiative     text check (initiative in ('advantage', 'disadvantage')),   -- 2024 only: the roll at the start of combat
  leveled        boolean not null default false,   -- Exhaustion
  icon           text,
  source_ref     text not null,
  sort_order     int not null,
  primary key (ruleset, key)
);
comment on table public.combat_conditions is 'Combat Builder condition catalog (project-authored summaries of SRD 5.1 / SRD 5.2.1, CC-BY-4.0). Reminders, not automation.';

insert into public.combat_conditions (ruleset, key, name, summary, incapacitating, initiative, leveled, icon, source_ref, sort_order) values
 ('2024', 'blinded', 'Blinded', 'Can''t see; fails checks that need sight. Attacks against it have Advantage; its attacks have Disadvantage.', false, null, false, 'condition.blinded', 'SRD 5.2.1 Rules Glossary: Blinded', 1),
 ('2024', 'charmed', 'Charmed', 'Can''t attack or target the charmer with harmful effects. The charmer has Advantage on social checks against it.', false, null, false, 'condition.charmed', 'SRD 5.2.1 Rules Glossary: Charmed', 2),
 ('2024', 'deafened', 'Deafened', 'Can''t hear; fails checks that need hearing.', false, null, false, null, 'SRD 5.2.1 Rules Glossary: Deafened', 3),
 ('2024', 'exhaustion', 'Exhaustion', 'Cumulative levels: D20 Tests −2 × level, Speed −5 ft × level; level 6 is death. A Long Rest removes 1 level.', false, null, true, null, 'SRD 5.2.1 Rules Glossary: Exhaustion', 4),
 ('2024', 'frightened', 'Frightened', 'Disadvantage on checks and attacks while the source is in sight; can''t willingly move closer to it.', false, null, false, 'condition.frightened', 'SRD 5.2.1 Rules Glossary: Frightened', 5),
 ('2024', 'grappled', 'Grappled', 'Speed 0. Disadvantage on attacks against targets other than the grappler. The grappler can move it.', false, null, false, 'condition.grappled', 'SRD 5.2.1 Rules Glossary: Grappled', 6),
 ('2024', 'incapacitated', 'Incapacitated', 'No action, Bonus Action or Reaction; Concentration breaks; can''t speak. Disadvantage on Initiative.', true, 'disadvantage', false, null, 'SRD 5.2.1 Rules Glossary: Incapacitated', 7),
 ('2024', 'invisible', 'Invisible', 'Can''t be seen; attacks against it have Disadvantage, its attacks Advantage. Advantage on Initiative.', false, 'advantage', false, 'condition.invisible', 'SRD 5.2.1 Rules Glossary: Invisible', 8),
 ('2024', 'paralyzed', 'Paralyzed', 'Incapacitated, Speed 0; fails STR and DEX saves. Attacks against it have Advantage; hits within 5 ft are Critical Hits.', true, 'disadvantage', false, 'condition.paralyzed', 'SRD 5.2.1 Rules Glossary: Paralyzed', 9),
 ('2024', 'petrified', 'Petrified', 'Turned to stone: Incapacitated, Speed 0, fails STR and DEX saves, Resistance to all damage, immune to Poisoned.', true, 'disadvantage', false, 'condition.petrified', 'SRD 5.2.1 Rules Glossary: Petrified', 10),
 ('2024', 'poisoned', 'Poisoned', 'Disadvantage on attack rolls and ability checks.', false, null, false, 'condition.poisoned', 'SRD 5.2.1 Rules Glossary: Poisoned', 11),
 ('2024', 'prone', 'Prone', 'Crawl or spend half Speed to stand. Disadvantage on its attacks; attacks within 5 ft have Advantage, others Disadvantage.', false, null, false, null, 'SRD 5.2.1 Rules Glossary: Prone', 12),
 ('2024', 'restrained', 'Restrained', 'Speed 0. Attacks against it have Advantage, its attacks Disadvantage; Disadvantage on DEX saves.', false, null, false, 'condition.restrained', 'SRD 5.2.1 Rules Glossary: Restrained', 13),
 ('2024', 'stunned', 'Stunned', 'Incapacitated; fails STR and DEX saves. Attacks against it have Advantage.', true, 'disadvantage', false, 'condition.stunned', 'SRD 5.2.1 Rules Glossary: Stunned', 14),
 ('2024', 'unconscious', 'Unconscious', 'Incapacitated and Prone, drops what it holds, Speed 0, fails STR and DEX saves. Attacks have Advantage; hits within 5 ft are Critical Hits.', true, 'disadvantage', false, null, 'SRD 5.2.1 Rules Glossary: Unconscious', 15),
 ('2014', 'blinded', 'Blinded', 'Can''t see; fails checks that need sight. Attacks against it have advantage; its attacks have disadvantage.', false, null, false, 'condition.blinded', 'SRD 5.1 Appendix PH-A: Blinded', 1),
 ('2014', 'charmed', 'Charmed', 'Can''t attack or target the charmer with harmful effects. The charmer has advantage on social checks against it.', false, null, false, 'condition.charmed', 'SRD 5.1 Appendix PH-A: Charmed', 2),
 ('2014', 'deafened', 'Deafened', 'Can''t hear; fails checks that need hearing.', false, null, false, null, 'SRD 5.1 Appendix PH-A: Deafened', 3),
 ('2014', 'exhaustion', 'Exhaustion', 'Six levels: 1 disadvantage on checks, 2 speed halved, 3 disadvantage on attacks and saves, 4 HP maximum halved, 5 speed 0, 6 death.', false, null, true, null, 'SRD 5.1 Appendix PH-A: Exhaustion', 4),
 ('2014', 'frightened', 'Frightened', 'Disadvantage on checks and attacks while the source is in sight; can''t willingly move closer to it.', false, null, false, 'condition.frightened', 'SRD 5.1 Appendix PH-A: Frightened', 5),
 ('2014', 'grappled', 'Grappled', 'Speed 0; ends if the grappler is incapacitated or moved away.', false, null, false, 'condition.grappled', 'SRD 5.1 Appendix PH-A: Grappled', 6),
 ('2014', 'incapacitated', 'Incapacitated', 'Can''t take actions or reactions.', true, null, false, null, 'SRD 5.1 Appendix PH-A: Incapacitated', 7),
 ('2014', 'invisible', 'Invisible', 'Can''t be seen without special senses. Attacks against it have disadvantage; its attacks have advantage.', false, null, false, 'condition.invisible', 'SRD 5.1 Appendix PH-A: Invisible', 8),
 ('2014', 'paralyzed', 'Paralyzed', 'Incapacitated, can''t move or speak; fails STR and DEX saves. Attacks have advantage; hits within 5 ft are critical.', true, null, false, 'condition.paralyzed', 'SRD 5.1 Appendix PH-A: Paralyzed', 9),
 ('2014', 'petrified', 'Petrified', 'Turned to stone: incapacitated, can''t move or speak, fails STR and DEX saves, resistance to all damage.', true, null, false, 'condition.petrified', 'SRD 5.1 Appendix PH-A: Petrified', 10),
 ('2014', 'poisoned', 'Poisoned', 'Disadvantage on attack rolls and ability checks.', false, null, false, 'condition.poisoned', 'SRD 5.1 Appendix PH-A: Poisoned', 11),
 ('2014', 'prone', 'Prone', 'Crawl or spend half movement to stand. Disadvantage on its attacks; attacks within 5 ft have advantage, others disadvantage.', false, null, false, null, 'SRD 5.1 Appendix PH-A: Prone', 12),
 ('2014', 'restrained', 'Restrained', 'Speed 0. Attacks against it have advantage, its attacks disadvantage; disadvantage on DEX saves.', false, null, false, 'condition.restrained', 'SRD 5.1 Appendix PH-A: Restrained', 13),
 ('2014', 'stunned', 'Stunned', 'Incapacitated, can''t move, speaks falteringly; fails STR and DEX saves. Attacks against it have advantage.', true, null, false, 'condition.stunned', 'SRD 5.1 Appendix PH-A: Stunned', 14),
 ('2014', 'unconscious', 'Unconscious', 'Incapacitated, can''t move or speak, unaware, drops what it holds, falls prone; fails STR and DEX saves. Hits within 5 ft are critical.', true, null, false, null, 'SRD 5.1 Appendix PH-A: Unconscious', 15)
on conflict (ruleset, key) do update set name = excluded.name, summary = excluded.summary, incapacitating = excluded.incapacitating,
  initiative = excluded.initiative, leveled = excluded.leveled, icon = excluded.icon, source_ref = excluded.source_ref, sort_order = excluded.sort_order;

-- ------------------------------------------------------------------------------------------------- 2. per-user library state
create table if not exists public.combat_monster_favorites (
  user_id     uuid not null references public.profiles (id) on delete cascade,
  monster_ref text not null check (monster_ref ~ '^(srd52|creature):[a-z0-9-]+$'),
  created_at  timestamptz not null default now(),
  primary key (user_id, monster_ref)
);

-- ------------------------------------------------------------------------------------------------- 3. encounters (DM only)
create table if not exists public.combat_encounters (
  id                  uuid primary key default gen_random_uuid(),
  campaign_id         uuid not null references public.campaigns (id) on delete cascade,
  name                text not null check (length(btrim(name)) between 1 and 120),
  description         text not null default '' check (length(description) <= 4000),
  dm_notes            text not null default '' check (length(dm_notes) <= 8000),
  ruleset             text not null check (ruleset in ('2014', '2024')),
  ruleset_source      text not null default 'explicit' check (ruleset_source in ('explicit', 'campaign_default')),
  status              text not null default 'draft' check (status in ('draft', 'active', 'paused', 'completed')),
  is_template         boolean not null default false,
  round               int not null default 0 check (round >= 0),
  current_participant_id uuid,
  turn_rev            bigint not null default 0,
  rev                 bigint not null default 0,
  settings            jsonb not null default '{}' check (jsonb_typeof(settings) = 'object'),
  source_encounter_id uuid references public.combat_encounters (id) on delete set null,
  created_by          uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  started_at          timestamptz,
  paused_at           timestamptz,
  resumed_at          timestamptz,
  active_seconds      int not null default 0,
  completed_at        timestamptz,
  archived_at         timestamptz,
  finish_notes        text not null default '' check (length(finish_notes) <= 8000),
  summary             jsonb
);
comment on table public.combat_encounters is 'Combat Builder encounters (DM only; docs/COMBAT_DATA_MODEL.md). Changed only through combat_* RPCs.';
create index if not exists combat_encounters_campaign_status on public.combat_encounters (campaign_id, status, updated_at desc);
create index if not exists combat_encounters_running on public.combat_encounters (campaign_id) where status in ('active', 'paused');

-- one stat block snapshot per (encounter, source, version): all copies of a monster share it
create table if not exists public.combat_statblocks (
  id             uuid primary key default gen_random_uuid(),
  encounter_id   uuid not null references public.combat_encounters (id) on delete cascade,
  source_kind    text not null check (source_kind in ('srd2024', 'creature', 'homebrew', 'custom')),
  source_id      text,
  source_version text,
  rules_version  text check (rules_version in ('2014', '2024')),
  name           text not null,
  snapshot       jsonb not null check (jsonb_typeof(snapshot) = 'object'),
  created_at     timestamptz not null default now()
);
create unique index if not exists combat_statblocks_source on public.combat_statblocks (encounter_id, source_kind, source_id, source_version)
  where source_kind <> 'custom';

create table if not exists public.combat_participants (
  id                   uuid primary key default gen_random_uuid(),
  encounter_id         uuid not null references public.combat_encounters (id) on delete cascade,
  kind                 text not null check (kind in ('character', 'monster')),
  linked_character_id  uuid references public.characters (id) on delete set null,
  statblock_id         uuid references public.combat_statblocks (id) on delete set null,
  display_name         text not null check (length(btrim(display_name)) between 1 and 120),
  instance_label       text check (length(instance_label) <= 12),
  player_label         text check (length(player_label) <= 120),   -- what a future player view shows instead of the true name
  group_key            text check (length(group_key) <= 60),
  initiative           int check (initiative between -20 and 60),
  initiative_mod       int not null default 0 check (initiative_mod between -20 and 30),
  initiative_roll      int,
  initiative_mode      text check (initiative_mode in ('manual', 'rolled', 'fixed', 'player')),
  initiative_tiebreak  int not null default 10,
  initiative_order     int,
  hp_current           int check (hp_current >= 0),
  hp_max               int check (hp_max between 1 and 5000),
  hp_temp              int not null default 0 check (hp_temp between 0 and 5000),
  armor_class          int check (armor_class between 0 and 50),
  active               boolean not null default true,
  removed_at           timestamptz,
  hidden               boolean not null default false,
  revealed_at          timestamptz,
  joins_round          int check (joins_round >= 1),
  defeated             boolean not null default false,
  defeated_at          timestamptz,
  surprised            boolean not null default false,
  turns_taken          int not null default 0,
  reaction_used        boolean not null default false,
  legendary_max        int check (legendary_max between 0 and 10),
  legendary_left       int check (legendary_left between 0 and 10),
  notes                text not null default '' check (length(notes) <= 4000),
  rev                  bigint not null default 0,
  created_at           timestamptz not null default now(),
  -- a character participant keeps its row (name, history) when the character itself is deleted (linked_character_id -> null)
  check (kind = 'character' or (hp_current is not null and hp_max is not null))
);
comment on table public.combat_participants is
  'Encounter participants. Monsters: own HP / AC (instances, never the catalog). Characters: linked_character_id; HP lives on public.characters.';
create index if not exists combat_participants_encounter on public.combat_participants (encounter_id, initiative_order nulls last, created_at);
create index if not exists combat_participants_character on public.combat_participants (linked_character_id) where linked_character_id is not null;
create unique index if not exists combat_participants_one_per_character on public.combat_participants (encounter_id, linked_character_id)
  where linked_character_id is not null and removed_at is null;

alter table public.combat_encounters drop constraint if exists combat_encounters_current_fk;
alter table public.combat_encounters add constraint combat_encounters_current_fk
  foreign key (current_participant_id) references public.combat_participants (id) on delete set null;

create table if not exists public.combat_effects (
  id                     uuid primary key default gen_random_uuid(),
  encounter_id           uuid not null references public.combat_encounters (id) on delete cascade,
  target_participant_id  uuid references public.combat_participants (id) on delete cascade,
  source_participant_id  uuid references public.combat_participants (id) on delete set null,
  effect_type            text not null check (effect_type in ('condition', 'custom', 'advantage', 'concentration')),
  condition_key          text,
  exhaustion_level       int check (exhaustion_level between 1 and 6),
  display_name           text not null check (length(btrim(display_name)) between 1 and 120),
  description            text not null default '' check (length(description) <= 2000),
  visibility             text not null default 'players' check (visibility in ('players', 'dm')),
  application            text not null default 'reminder' check (application in ('reminder', 'applied')),
  applied_round          int not null default 0,
  applied_participant_id uuid,
  duration_type          text not null default 'indefinite'
                           check (duration_type in ('indefinite', 'rounds', 'until_turn_start', 'until_turn_end', 'minutes', 'save_ends')),
  duration_rounds        int check (duration_rounds between 1 and 1000),
  remaining_rounds       int check (remaining_rounds >= 0),
  duration_minutes       int check (duration_minutes between 1 and 100000),
  anchor_participant_id  uuid references public.combat_participants (id) on delete set null,
  expires_on             text check (expires_on in ('turn_start', 'turn_end')),
  save_ability           text check (save_ability in ('str', 'dex', 'con', 'int', 'wis', 'cha')),
  save_dc                int check (save_dc between 1 and 40),
  save_timing            text check (save_timing in ('turn_start', 'turn_end')),
  concentration_id       uuid references public.combat_effects (id) on delete set null,
  adv_mode               text check (adv_mode in ('advantage', 'disadvantage')),
  adv_scope              text check (adv_scope in ('next_attack', 'attacks_turn', 'attacks', 'melee_attacks', 'ranged_attacks',
                           'attacks_against_target', 'incoming_attacks', 'saves', 'save', 'checks', 'skill', 'initiative', 'custom')),
  adv_detail             text check (length(adv_detail) <= 60),
  adv_target_id          uuid references public.combat_participants (id) on delete set null,
  modifier_target        text check (modifier_target in ('ac', 'speed', 'attack', 'save', 'check', 'damage', 'other')),
  modifier_value         int check (modifier_value between -50 and 50),
  defense_kind           text check (defense_kind in ('resistance', 'immunity', 'vulnerability')),
  defense_type           text check (length(defense_type) <= 40),
  pending_checks         jsonb not null default '[]' check (jsonb_typeof(pending_checks) = 'array'),
  notes                  text not null default '' check (length(notes) <= 2000),
  active                 boolean not null default true,
  ended_at               timestamptz,
  ended_reason           text check (ended_reason in ('removed', 'expired', 'concentration_ended', 'save_succeeded',
                           'encounter_finished', 'carried_to_sheet', 'undo', 'source_removed')),
  rev                    bigint not null default 0,
  created_by             uuid default auth.uid(),
  created_at             timestamptz not null default now(),
  check (effect_type <> 'condition' or condition_key is not null),
  check (effect_type <> 'advantage' or (adv_mode is not null and adv_scope is not null)),
  check (effect_type <> 'concentration' or source_participant_id is not null or ended_at is not null),
  check (duration_type <> 'rounds' or (duration_rounds is not null and expires_on is not null)),
  check (duration_type <> 'save_ends' or (save_ability is not null and save_dc is not null))
);
comment on table public.combat_effects is
  'Conditions, custom effects, advantage states and concentration of an encounter. application = applied only for the supported calculations (AC, Speed in the tracker); everything else is a reminder.';
create index if not exists combat_effects_target_active on public.combat_effects (encounter_id, target_participant_id) where active;
create index if not exists combat_effects_concentration on public.combat_effects (concentration_id) where concentration_id is not null and active;
create index if not exists combat_effects_anchor on public.combat_effects (anchor_participant_id) where active and anchor_participant_id is not null;

create table if not exists public.combat_reminders (
  id                 uuid primary key default gen_random_uuid(),
  encounter_id       uuid not null references public.combat_encounters (id) on delete cascade,
  kind               text not null default 'custom' check (kind in ('lair', 'hazard', 'reinforcement', 'environment', 'custom')),
  title              text not null check (length(btrim(title)) between 1 and 120),
  note               text not null default '' check (length(note) <= 2000),
  trigger_round      int check (trigger_round >= 1),
  trigger_initiative int check (trigger_initiative between -20 and 60),
  repeat_every       int check (repeat_every between 1 and 100),
  hidden             boolean not null default true,
  active             boolean not null default true,
  last_fired_round   int,
  acknowledged_round int,
  rev                bigint not null default 0,
  created_at         timestamptz not null default now(),
  check (trigger_round is not null or trigger_initiative is not null)
);
create index if not exists combat_reminders_encounter on public.combat_reminders (encounter_id) where active;

-- history, audit, Undo and duplicate protection (one row per accepted mutation; request_id unique per encounter)
create table if not exists public.combat_events (
  id             bigint generated always as identity primary key,
  encounter_id   uuid not null references public.combat_encounters (id) on delete cascade,
  at             timestamptz not null default now(),
  actor          uuid default auth.uid(),
  kind           text not null,
  participant_id uuid references public.combat_participants (id) on delete set null,
  round          int,
  request_id     uuid,
  before         jsonb,
  after          jsonb,
  details        jsonb not null default '{}',
  result         jsonb,
  undoable       boolean not null default false,
  undone_by      bigint,
  undo_of        bigint
);
create index if not exists combat_events_encounter on public.combat_events (encounter_id, id desc);
create unique index if not exists combat_events_request on public.combat_events (encounter_id, request_id) where request_id is not null;

-- Realtime change log (docs/COMBAT_REALTIME.md): ids only, never names, HP or notes. One binding per open encounter.
create table if not exists public.combat_changes (
  id             bigint generated always as identity primary key,
  encounter_id   uuid not null references public.combat_encounters (id) on delete cascade,
  domain         text not null check (domain in ('encounter', 'turn', 'participants', 'hp', 'effects', 'reminders')),
  kind           text not null check (length(kind) <= 40),
  participant_id uuid,
  player_visible boolean not null default false,
  changed_at     timestamptz not null default now()
);
create index if not exists combat_changes_encounter on public.combat_changes (encounter_id, id desc);
create index if not exists combat_changes_changed_at on public.combat_changes (changed_at);
comment on table public.combat_changes is 'Combat Builder Realtime log: one row per committed change (encounter, domain, participant id, kind). Payload is never secret.';

-- --------------------------------------------------------------------------------------------- 4. read gate and policies
-- may the caller run this campaign's encounters (campaign DM or admin)
create or replace function public._combat_can_run(p_campaign uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and (public.is_admin() or public.is_campaign_dm(p_campaign));
$$;
create or replace function public._combat_can_see(p_encounter uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.combat_encounters e where e.id = p_encounter and public._combat_can_run(e.campaign_id));
$$;
revoke all on function public._combat_can_run(uuid), public._combat_can_see(uuid) from public, anon;
grant execute on function public._combat_can_run(uuid), public._combat_can_see(uuid) to authenticated;

do $$
declare t text;
begin
  foreach t in array array['combat_monsters', 'creature_legendary_actions', 'combat_conditions', 'combat_monster_favorites', 'combat_encounters',
    'combat_statblocks', 'combat_participants', 'combat_effects', 'combat_reminders', 'combat_events', 'combat_changes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
  end loop;
end $$;

drop policy if exists combat_monsters_read on public.combat_monsters;
create policy combat_monsters_read on public.combat_monsters for select to authenticated using (true);
drop policy if exists creature_legendary_actions_read on public.creature_legendary_actions;
create policy creature_legendary_actions_read on public.creature_legendary_actions for select to authenticated using (true);
drop policy if exists combat_conditions_read on public.combat_conditions;
create policy combat_conditions_read on public.combat_conditions for select to authenticated using (true);
drop policy if exists combat_monster_favorites_own on public.combat_monster_favorites;
create policy combat_monster_favorites_own on public.combat_monster_favorites for select to authenticated using (user_id = auth.uid());
grant select on public.combat_monsters, public.creature_legendary_actions, public.combat_conditions, public.combat_monster_favorites to authenticated;

-- runtime tables: SELECT for the campaign DM (and admins) only; players read the player-safe RPC (get_combat_player_view).
drop policy if exists combat_encounters_dm on public.combat_encounters;
create policy combat_encounters_dm on public.combat_encounters for select to authenticated using (public._combat_can_run(campaign_id));
do $$
declare t text;
begin
  foreach t in array array['combat_statblocks', 'combat_participants', 'combat_effects', 'combat_reminders', 'combat_events', 'combat_changes'] loop
    execute format('drop policy if exists %I on public.%I', t || '_dm', t);
    execute format('create policy %I on public.%I for select to authenticated using (public._combat_can_see(encounter_id))', t || '_dm', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;
grant select on public.combat_encounters to authenticated;
-- no INSERT / UPDATE / DELETE grants: every change goes through the combat_* RPCs (security definer, role checked)

-- ------------------------------------------------------------------------------------------------- 5. read-cache counters
create or replace function tl_cache.combat_skip()
returns trigger language plpgsql as $$
begin
  return null;   -- combat runtime rows feed no cached character read (see the header): nothing to invalidate
end $$;
revoke all on function tl_cache.combat_skip() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['combat_monsters', 'creature_legendary_actions', 'combat_conditions'] loop
    execute format('drop trigger if exists tl_cache_rev on public.%I', t);
    execute format('create trigger tl_cache_rev after insert or update or delete on public.%I for each row execute function tl_cache.bump(%L)', t, 'global');
  end loop;
  foreach t in array array['combat_monster_favorites', 'combat_encounters', 'combat_statblocks', 'combat_participants', 'combat_effects',
    'combat_reminders', 'combat_events', 'combat_changes'] loop
    execute format('drop trigger if exists tl_cache_rev on public.%I', t);
    execute format('create trigger tl_cache_rev after insert or update or delete on public.%I for each row execute function tl_cache.combat_skip()', t);
  end loop;
end $$;

-- ------------------------------------------------------------------------------------------------- 6. Realtime
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'combat_changes') then
    execute 'alter publication supabase_realtime add table public.combat_changes';
  end if;
end $$;
