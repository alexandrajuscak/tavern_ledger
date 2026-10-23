-- =============================================================================
-- Campaign governance (docs/DM_GOVERNANCE.md, CHARACTER_LOCKS.md, CAMPAIGN_CONTENT_POLICY.md).
--
-- Every governed character action has a key (governance_actions). A campaign resolves each key to one decision:
--   player_managed     the owner may do it immediately
--   approval_required  the owner sends a change request (20261019000200); nothing changes until a DM approves
--   dm_only            only a DM of the campaign (or an admin)
--   disabled           nobody in the campaign
-- Presets relaxed / standard / strict give the defaults, campaign_policy_overrides change single actions (preset
-- "custom"). Character locks and the initial-setup state refine the decision per character.
--
-- Enforcement is in the database:
--   * _gov_gate(character, action) at the top of every governed SECURITY DEFINER RPC (injected below from the live
--     definitions; the RPC bodies are otherwise unchanged);
--   * characters_governance / *_governance triggers for direct table writes of the authenticated role (writes made
--     inside SECURITY DEFINER functions run as the function owner and are gated by that function).
-- Campaign DMs and admins pass every gate (an archived character is read-only for everyone until a DM restores it).
-- Characters without a campaign have no DM and are not governed. Campaigns that existed before this migration get an
-- explicit "relaxed" row (the old behavior) and a report row; a campaign created by a signed-in user starts "standard";
-- a campaign without a row (created by SQL, seeds, tests) resolves as "relaxed" and is reported as not configured.
-- Error codes: TLAPR approval required, TLDMO DM only, TLDIS disabled, TLLCK locked (PostgREST passes them as "code").
-- Rollback: supabase/rollback/rollback_campaign_governance.sql.
-- =============================================================================

-- ---- action catalog --------------------------------------------------------------------------------------------------
create function public._gov_rank(p_decision text)
returns int
language sql immutable
set search_path = public, pg_temp
as $$ select case p_decision when 'player_managed' then 0 when 'approval_required' then 1 when 'dm_only' then 2
                             when 'disabled' then 3 end $$;

create table public.governance_actions (
  action_key  text primary key check (action_key ~ '^[a-z]+\.[a-z_]+$'),
  category    text not null check (category in ('identity', 'core_build', 'feats_choices', 'spells', 'inventory', 'runtime',
                                                'content', 'dm_control')),
  label       text not null check (length(label) between 1 and 80),
  description text not null default '',
  lock_class  text not null check (lock_class in ('identity', 'runtime', 'inventory_instance', 'inventory_acquire', 'build',
                                                  'progression', 'content', 'dm')),
  relaxed     text not null,
  standard    text not null,
  strict      text not null,
  max_player  text not null default 'player_managed',   -- the most permissive decision a campaign may choose
  can_request boolean not null default true,             -- approval_required is meaningful (a player can propose it)
  sort_order  int not null default 0,
  check (public._gov_rank(relaxed) is not null and public._gov_rank(standard) is not null and public._gov_rank(strict) is not null
         and public._gov_rank(max_player) is not null),
  check (public._gov_rank(relaxed) >= public._gov_rank(max_player) and public._gov_rank(standard) >= public._gov_rank(max_player)
         and public._gov_rank(strict) >= public._gov_rank(max_player))
);

insert into public.governance_actions (action_key, category, lock_class, relaxed, standard, strict, max_player, can_request, sort_order, label, description) values
  ('identity.name',            'identity', 'identity', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 10, 'Character name', ''),
  ('identity.portrait',        'identity', 'identity', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 11, 'Portrait', ''),
  ('identity.descriptive',     'identity', 'identity', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 12, 'Alignment and descriptive fields', 'Alignment, experience, the display texts of race, class and background.'),
  ('identity.notes',           'identity', 'identity', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 13, 'Notes and free-text features', 'Biography, session notes, free-text features.'),
  ('build.ability_scores',     'core_build', 'build', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 20, 'Base ability scores', ''),
  ('build.lineage',            'core_build', 'progression', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 21, 'Lineage', 'Choosing, changing or clearing the lineage and its choices.'),
  ('build.background',         'core_build', 'progression', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 22, 'Background', 'Choosing, changing or clearing the background, its choices and its equipment.'),
  ('build.class_add',          'core_build', 'progression', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 23, 'Add a class (multiclass)', ''),
  ('build.class_level',        'core_build', 'progression', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 24, 'Class level', 'Level up or down, the first class of a character.'),
  ('build.class_version',      'core_build', 'progression', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 25, 'Class rules version', ''),
  ('build.subclass',           'core_build', 'progression', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 26, 'Subclass', ''),
  ('build.class_remove',       'core_build', 'progression', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 27, 'Remove a class', ''),
  ('build.primary_class',      'core_build', 'progression', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 28, 'Primary class', ''),
  ('build.manual_proficiency', 'core_build', 'build', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 29, 'Manual proficiencies', 'Skills, saves, armor, weapons, tools and languages marked by hand.'),
  ('build.hp_max',             'core_build', 'build', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 30, 'Maximum HP', 'The stored base maximum (feats and features are added on top automatically).'),
  ('build.manual_stats',       'core_build', 'build', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 31, 'Manual overrides', 'AC override, speed, initiative bonus, hit die, custom attacks, manual resources and manual slots.'),
  ('build.companion',          'core_build', 'build', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 32, 'Permanent companion', 'Adding or removing a companion.'),
  ('build.move_campaign',      'core_build', 'dm', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 33, 'Move to another campaign', 'Moving the character out of the campaign or giving it to another player.'),
  ('choice.asi',               'feats_choices', 'progression', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 40, 'Ability Score Improvement', ''),
  ('choice.feat',              'feats_choices', 'progression', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 41, 'Feats', 'Taking, changing or removing a feat and its choices.'),
  ('choice.class_feature',     'feats_choices', 'progression', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 42, 'Class feature choices', 'Fighting Style, Expertise, Metamagic, Invocations, maneuvers and other class choices.'),
  ('choice.optional_feature',  'feats_choices', 'progression', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 43, 'Optional and replacement features', ''),
  ('spell.prepare',            'spells', 'runtime', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 50, 'Prepare and unprepare spells', ''),
  ('spell.learn_known',        'spells', 'build', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 51, 'Learn a known spell', ''),
  ('spell.remove',             'spells', 'build', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 52, 'Remove or replace a known spell', ''),
  ('spell.spellbook_add',      'spells', 'build', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 53, 'Add a spell to a spellbook', ''),
  ('spell.always_prepared',    'spells', 'build', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 54, 'Always-prepared spells', ''),
  ('spell.add_manual',         'spells', 'build', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 55, 'Manual and free-text spells', ''),
  ('spell.assign_custom',      'spells', 'build', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 56, 'Campaign custom spells', ''),
  ('spell.change_source',      'spells', 'build', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 57, 'Spellcasting source settings', 'Casting ability, manual sources, ritual settings.'),
  ('spell.notes',              'spells', 'identity', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 58, 'Spell notes', ''),
  ('inventory.quantity',       'inventory', 'inventory_instance', 'player_managed', 'player_managed', 'approval_required', 'player_managed', true, 60, 'Quantity of an owned stack', ''),
  ('inventory.currency',       'inventory', 'inventory_instance', 'player_managed', 'player_managed', 'approval_required', 'player_managed', true, 61, 'Coins', ''),
  ('inventory.add_mundane',    'inventory', 'inventory_acquire', 'player_managed', 'player_managed', 'approval_required', 'player_managed', true, 62, 'Add an official mundane item', 'Also starting equipment and linking a legacy item to the catalog.'),
  ('inventory.add_magic',      'inventory', 'inventory_acquire', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 63, 'Add a magic item', ''),
  ('inventory.assign_custom',  'inventory', 'inventory_acquire', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 64, 'Add a campaign custom item', ''),
  ('inventory.transfer',       'inventory', 'inventory_acquire', 'player_managed', 'player_managed', 'approval_required', 'player_managed', true, 65, 'Transfer an item', ''),
  ('inventory.delete',         'inventory', 'inventory_acquire', 'player_managed', 'player_managed', 'approval_required', 'player_managed', true, 66, 'Delete an item', ''),
  ('inventory.organize',       'inventory', 'inventory_instance', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 67, 'Split, merge and move items', ''),
  ('inventory.equip',          'inventory', 'inventory_instance', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 68, 'Equip and unequip', ''),
  ('inventory.attune',         'inventory', 'inventory_instance', 'player_managed', 'player_managed', 'approval_required', 'player_managed', true, 69, 'Attunement', ''),
  ('inventory.instance_notes', 'inventory', 'identity', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 70, 'Item custom name and notes', ''),
  ('runtime.hp',               'runtime', 'runtime', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 80, 'Current HP, temporary HP, death saves', 'Also Hit Dice spent and Heroic Inspiration.'),
  ('runtime.conditions',       'runtime', 'runtime', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 81, 'Visible conditions', ''),
  ('runtime.resources',        'runtime', 'runtime', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 82, 'Resources, spell slots and charges', ''),
  ('runtime.states',           'runtime', 'runtime', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 83, 'Active states and infusions', 'Rage and other active states, Artificer infusions.'),
  ('runtime.short_rest',       'runtime', 'runtime', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 84, 'Short rest', ''),
  ('runtime.long_rest',        'runtime', 'runtime', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 85, 'Long rest', ''),
  ('runtime.wild_shape',       'runtime', 'runtime', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 86, 'Wild Shape and transformations', ''),
  ('runtime.companion',        'runtime', 'runtime', 'player_managed', 'player_managed', 'player_managed', 'player_managed', true, 87, 'Companion HP and notes', ''),
  ('runtime.mark_seen_form',   'runtime', 'build', 'player_managed', 'approval_required', 'approval_required', 'player_managed', true, 88, 'Mark a beast as seen', 'Wild Shape forms the Druid has seen.'),
  ('content.create_spell',     'content', 'content', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 90, 'Create custom spells', ''),
  ('content.create_item',      'content', 'content', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 91, 'Create custom items', ''),
  ('content.create_feat',      'content', 'content', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 92, 'Create custom feats', ''),
  ('content.create_background','content', 'content', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 93, 'Create custom backgrounds', ''),
  ('content.create_lineage',   'content', 'content', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 94, 'Create custom lineages', ''),
  ('content.create_creature',  'content', 'content', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 95, 'Create custom creatures and Wild Shape forms', ''),
  ('content.create_companion', 'content', 'content', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 96, 'Create companion templates', ''),
  ('content.create_condition', 'content', 'content', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 97, 'Create custom conditions and effects', ''),
  ('content.publish',          'content', 'content', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 98, 'Publish campaign content', ''),
  ('content.archive',          'content', 'content', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 99, 'Archive campaign content', ''),
  ('dm.hidden_data',           'dm_control', 'dm', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 110, 'Hidden notes, effects and curses', ''),
  ('dm.identify_items',        'dm_control', 'dm', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 111, 'Identify items and reveal properties', ''),
  ('dm.prerequisite_override', 'dm_control', 'dm', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 112, 'Prerequisite overrides', 'Confirming a prerequisite or rule exception.'),
  ('dm.seen_form_grant',       'dm_control', 'dm', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 113, 'Wild Shape grants and exceptions', 'Granting forms and changing who may mark forms as seen.'),
  ('dm.character_lock',        'dm_control', 'dm', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 114, 'Character locks and initial setup', ''),
  ('dm.campaign_policy',       'dm_control', 'dm', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 115, 'Campaign rules and content policy', ''),
  ('dm.approval_decision',     'dm_control', 'dm', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 116, 'Approval decisions', ''),
  ('dm.forced_correction',     'dm_control', 'dm', 'dm_only', 'dm_only', 'dm_only', 'dm_only', false, 117, 'Forced corrections', '');

-- ---- campaign settings, overrides, character state -------------------------------------------------------------------
create table public.campaign_governance (
  campaign_id             uuid primary key references public.campaigns (id) on delete cascade,
  preset                  text not null default 'standard' check (preset in ('relaxed', 'standard', 'strict', 'custom')),
  custom_base             text not null default 'standard' check (custom_base in ('relaxed', 'standard', 'strict')),
  unmet_prerequisites     text not null default 'propose' check (unmet_prerequisites in ('block', 'propose', 'dm_override')),
  require_approval_note   boolean not null default false,
  allow_edit_and_approve  boolean not null default true,
  content_rulesets        text[] not null default '{2014,2024}',
  content_allow_legacy    boolean not null default true,
  content_allow_playtest  boolean not null default false,
  content_allow_setting   boolean not null default true,
  content_allow_custom    boolean not null default true,
  content_excluded_sources text[] not null default '{}',
  migrated_from           text check (migrated_from in ('pre_governance')),
  revision                int not null default 1,
  updated_by              uuid references public.profiles (id) on delete set null,
  updated_at              timestamptz not null default now(),
  created_at              timestamptz not null default now(),
  check (content_rulesets <@ array['2014', '2024']::text[])
);

create table public.campaign_policy_overrides (
  campaign_id uuid not null references public.campaigns (id) on delete cascade,
  action_key  text not null references public.governance_actions (action_key) on delete cascade,
  decision    text not null check (public._gov_rank(decision) is not null),
  updated_by  uuid references public.profiles (id) on delete set null,
  updated_at  timestamptz not null default now(),
  primary key (campaign_id, action_key)
);

create table public.character_governance (
  character_id        uuid primary key references public.characters (id) on delete cascade,
  lock_mode           text not null default 'unlocked'
                        check (lock_mode in ('unlocked', 'progression_locked', 'build_locked', 'fully_locked', 'archived')),
  lock_reason         text check (length(lock_reason) <= 300),
  locked_by           uuid references public.profiles (id) on delete set null,
  locked_at           timestamptz,
  setup_complete      boolean not null default false,
  setup_completed_by  uuid references public.profiles (id) on delete set null,
  setup_completed_at  timestamptz,
  updated_at          timestamptz not null default now()
);

create table public.governance_migration_report (
  campaign_id   uuid primary key references public.campaigns (id) on delete cascade,
  campaign_name text not null,
  preset        text not null,
  characters    int not null,
  note          text not null,
  created_at    timestamptz not null default now()
);

-- campaign audit timeline (requests link here in 20261019000200)
create table public.campaign_audit_events (
  id           uuid primary key default gen_random_uuid(),
  campaign_id  uuid references public.campaigns (id) on delete cascade,
  character_id uuid references public.characters (id) on delete cascade,
  actor_id     uuid references public.profiles (id) on delete set null,
  event_type   text not null check (event_type ~ '^[a-z_]+$'),
  summary      text not null check (length(summary) between 1 and 300),
  before       jsonb,
  after        jsonb,
  reason       text check (length(reason) <= 1000),
  request_id   uuid,
  visibility   text not null default 'party' check (visibility in ('party', 'owner', 'dm')),
  created_at   timestamptz not null default now()
);
create index campaign_audit_events_campaign on public.campaign_audit_events (campaign_id, created_at desc);
create index campaign_audit_events_character on public.campaign_audit_events (character_id, created_at desc);

-- existing campaigns keep the old behavior (relaxed) with an explicit row; existing characters count as set up
insert into public.campaign_governance (campaign_id, preset, migrated_from, content_allow_playtest)
select id, 'relaxed', 'pre_governance', true from public.campaigns;
insert into public.governance_migration_report (campaign_id, campaign_name, preset, characters, note)
select c.id, c.name, 'relaxed', (select count(*) from public.characters x where x.campaign_id = c.id),
       'Existed before campaign governance: kept the previous behavior (players manage their characters; creating mechanical '
       || 'content and DM controls are DM-only). Review the settings in DM Space > Campaign Rules.'
from public.campaigns c;
insert into public.character_governance (character_id, setup_complete, setup_completed_at)
select id, true, now() from public.characters where campaign_id is not null;

-- new campaigns created by a signed-in user start with the recommended preset
create function public.campaigns_governance_default()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is not null then
    insert into public.campaign_governance (campaign_id, preset, updated_by) values (new.id, 'standard', auth.uid())
    on conflict (campaign_id) do nothing;
  end if;
  return new;
end;
$$;
revoke all on function public.campaigns_governance_default() from public, anon, authenticated;
create trigger campaigns_governance_default after insert on public.campaigns
  for each row execute function public.campaigns_governance_default();

-- ---- decision engine ---------------------------------------------------------------------------------------------------
-- the campaign's decision for an action (preset or override); campaigns without settings resolve as relaxed
create function public._gov_policy(p_campaign uuid, p_action text)
returns text
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select o.decision from public.campaign_policy_overrides o where o.campaign_id = p_campaign and o.action_key = p_action),
    (select case case when g.preset = 'custom' then g.custom_base else coalesce(g.preset, 'relaxed') end
              when 'strict' then a.strict when 'standard' then a.standard else a.relaxed end
     from public.governance_actions a left join public.campaign_governance g on g.campaign_id = p_campaign
     where a.action_key = p_action));
$$;

create function public._gov_lock_blocks(p_mode text, p_lock_class text)
returns boolean
language sql immutable
set search_path = public, pg_temp
as $$
  select case coalesce(p_mode, 'unlocked')
    when 'unlocked' then false
    when 'progression_locked' then p_lock_class = 'progression'
    when 'build_locked' then p_lock_class in ('progression', 'build', 'inventory_acquire')
    else true end;
$$;

-- The decision for the current user: {decision, code, campaign_id, campaign_name, lock_mode, message}.
-- decision: allow (DM, admin, ungoverned, SQL) | player_managed | approval_required | dm_only | disabled | locked.
create function public._gov_decide(p_character uuid, p_action text)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  a public.governance_actions; ch record; g public.character_governance; d text; camp_name text;
  applying text := nullif(current_setting('tavern.gov_apply', true), '');
begin
  select * into a from public.governance_actions where action_key = p_action;
  if a.action_key is null then raise exception 'Unknown governed action "%"', p_action using errcode = '22023'; end if;
  if auth.uid() is null then return jsonb_build_object('decision', 'allow', 'code', 'system'); end if;
  select c.id, c.owner_id, c.campaign_id into ch from public.characters c where c.id = p_character;
  if ch.id is null then return jsonb_build_object('decision', 'allow', 'code', 'unknown_character'); end if;  -- the RPC refuses
  select * into g from public.character_governance where character_id = p_character;
  select name into camp_name from public.campaigns where id = ch.campaign_id;
  if g.lock_mode = 'archived' and p_action <> 'dm.character_lock' then
    return jsonb_build_object('decision', 'locked', 'code', 'archived', 'lock_mode', 'archived', 'campaign_id', ch.campaign_id,
                              'campaign_name', camp_name);
  end if;
  if public.is_admin() or (ch.campaign_id is not null and public.is_campaign_dm(ch.campaign_id)) then
    -- an approved request is applied under the lock that is in force now (the DM unlocks or rejects)
    if applying is not null and public._gov_lock_blocks(g.lock_mode, a.lock_class) then
      return jsonb_build_object('decision', 'locked', 'code', 'lock_during_apply', 'lock_mode', g.lock_mode,
                                'campaign_id', ch.campaign_id, 'campaign_name', camp_name);
    end if;
    return jsonb_build_object('decision', 'allow', 'code', 'dm', 'campaign_id', ch.campaign_id);
  end if;
  if ch.campaign_id is null then return jsonb_build_object('decision', 'allow', 'code', 'no_campaign'); end if;
  if ch.owner_id is distinct from auth.uid() then
    return jsonb_build_object('decision', 'allow', 'code', 'not_owner');      -- the RPC's own access check refuses
  end if;
  d := public._gov_policy(ch.campaign_id, p_action);
  if public._gov_lock_blocks(g.lock_mode, a.lock_class) and d <> 'disabled' then
    return jsonb_build_object('decision', 'locked', 'code', g.lock_mode, 'lock_mode', g.lock_mode, 'lock_reason', g.lock_reason,
                              'campaign_id', ch.campaign_id, 'campaign_name', camp_name);
  end if;
  -- initial setup: a new character may be built freely until the DM marks the setup complete
  if d = 'approval_required' and a.lock_class in ('build', 'progression') and not coalesce(g.setup_complete, false) then
    return jsonb_build_object('decision', 'player_managed', 'code', 'initial_setup', 'campaign_id', ch.campaign_id,
                              'campaign_name', camp_name);
  end if;
  return jsonb_build_object('decision', d, 'code', 'policy', 'campaign_id', ch.campaign_id, 'campaign_name', camp_name,
                            'lock_mode', coalesce(g.lock_mode, 'unlocked'));
end;
$$;

-- Raise unless the current user may perform the action now. Inside a request preview (tavern.gov_preview = the
-- character id, set only by the preview function) approval_required passes; the preview is always rolled back.
create function public._gov_gate(p_character uuid, p_action text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare r jsonb := public._gov_decide(p_character, p_action); lbl text; camp text;
begin
  if r ->> 'decision' in ('allow', 'player_managed') then return; end if;
  select label into lbl from public.governance_actions where action_key = p_action;
  camp := coalesce(r ->> 'campaign_name', 'this campaign');
  case r ->> 'decision'
    when 'approval_required' then
      if current_setting('tavern.gov_preview', true) = p_character::text then return; end if;
      raise exception '% needs your DM''s approval in %. Send it as a request.', lbl, camp
        using errcode = 'TLAPR', detail = p_action, hint = 'request';
    when 'dm_only' then
      raise exception 'Only the DM of % can change this (%).', camp, lower(lbl) using errcode = 'TLDMO', detail = p_action;
    when 'disabled' then
      raise exception '% is turned off in %.', lbl, camp using errcode = 'TLDIS', detail = p_action;
    else
      raise exception '%', case r ->> 'code'
          when 'archived' then 'This character is archived and read-only. A DM can restore it.'
          when 'lock_during_apply' then 'This character is ' || replace(r ->> 'lock_mode', '_', ' ')
                                         || ' now. Unlock it before applying the request, or reject it.'
          when 'fully_locked' then 'Your DM has locked this character. Only the DM can change it now.'
          when 'build_locked' then 'Your DM has locked this character''s build. Gameplay still works; permanent changes are paused.'
          else 'Your DM has locked this character''s progression. Gameplay still works; level, feats and choices are paused.' end
        || coalesce(' Reason: ' || nullif(r ->> 'lock_reason', ''), '')
        using errcode = 'TLLCK', detail = p_action;
  end case;
end;
$$;

-- the item / inventory / class-row / spell-row variants resolve the character first
create function public._gov_gate_inventory(p_inventory uuid, p_action text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare inv public.inventories;
begin
  select * into inv from public.inventories where id = p_inventory;
  if inv.kind = 'character' and inv.character_id is not null then perform public._gov_gate(inv.character_id, p_action); end if;
end;
$$;

create function public._gov_gate_item(p_item uuid, p_action text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare inv uuid;
begin
  select inventory_id into inv from public.inventory_items where id = p_item;
  if inv is not null then perform public._gov_gate_inventory(inv, p_action); end if;
end;
$$;

-- content creation is not about a character: the DM of the target campaign, or (private library) a DM of any campaign
create function public._gov_content_gate(p_campaign uuid, p_action text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare d text; camp text;
begin
  if auth.uid() is null or public.is_admin() then return; end if;
  if p_campaign is null then
    if not exists (select 1 from public.campaign_members where user_id = auth.uid() and role = 'dm') then
      raise exception 'Only a DM can create custom game content. Ask your DM to add it to the campaign.'
        using errcode = 'TLDMO', detail = p_action;
    end if;
    return;
  end if;
  select name into camp from public.campaigns where id = p_campaign;
  if not public.is_campaign_dm(p_campaign) then
    raise exception 'Only the DM of % can create or change its game content.', coalesce(camp, 'this campaign')
      using errcode = 'TLDMO', detail = p_action;
  end if;
  d := public._gov_policy(p_campaign, p_action);
  if d = 'disabled' then
    raise exception 'This kind of custom content is turned off in %.', coalesce(camp, 'this campaign') using errcode = 'TLDIS', detail = p_action;
  end if;
end;
$$;

-- may the current user author mechanical content at all (DM of a campaign, or admin)?
create function public.can_author_content(p_campaign uuid default null)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select auth.uid() is not null and (public.is_admin()
    or (p_campaign is null and exists (select 1 from public.campaign_members where user_id = auth.uid() and role = 'dm'))
    or (p_campaign is not null and public.is_campaign_dm(p_campaign)));
$$;

-- ---- campaign content policy --------------------------------------------------------------------------------------------
-- null = allowed, else the reason. Used by the gate helpers of class / lineage / background / spell / item / feat writes
-- (players only; a DM may assign anything and the assignment is audited).
create function public._content_policy_reason(p_campaign uuid, p_ruleset text, p_legacy boolean, p_playtest boolean,
                                              p_setting text, p_custom boolean, p_source_book text default null)
returns text
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare g public.campaign_governance;
begin
  if p_campaign is null then return null; end if;
  select * into g from public.campaign_governance where campaign_id = p_campaign;
  if g.campaign_id is null then return null; end if;                 -- not configured: everything (old behavior)
  if p_ruleset in ('2014', '2024') and not p_ruleset = any (g.content_rulesets) then
    return 'The ' || p_ruleset || ' rules are not used in this campaign';
  end if;
  if coalesce(p_playtest, false) and not g.content_allow_playtest then return 'Playtest (Unearthed Arcana) content is not allowed in this campaign'; end if;
  if coalesce(p_legacy, false) and not g.content_allow_legacy then return 'Legacy content is not allowed in this campaign'; end if;
  if p_setting is not null and p_setting <> '' and not g.content_allow_setting then return 'Setting-specific content is not allowed in this campaign'; end if;
  if coalesce(p_custom, false) and not g.content_allow_custom then return 'Custom campaign content is turned off in this campaign'; end if;
  if p_source_book is not null and p_source_book = any (g.content_excluded_sources) then return 'This source book is not used in this campaign'; end if;
  return null;
end;
$$;

create function public._gov_content_check(p_character uuid, p_reason text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare ch record;
begin
  if p_reason is null or auth.uid() is null or public.is_admin() then return; end if;
  select owner_id, campaign_id into ch from public.characters where id = p_character;
  if ch.campaign_id is null or public.is_campaign_dm(ch.campaign_id) then return; end if;
  raise exception '%. Ask your DM.', p_reason using errcode = 'TLDIS', detail = 'content_policy';
end;
$$;

-- ---- gate helpers of the composite RPCs ----------------------------------------------------------------------------------
create function public._gov_gate_class(p_character uuid, p_class_version text, p_level int, p_subclass_version text,
                                       p_is_primary boolean, p_character_class uuid)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v public.class_versions; r public.character_classes; sv public.subclass_versions;
begin
  select * into v from public.class_versions where id = p_class_version;
  if p_character_class is not null then
    select * into r from public.character_classes where id = p_character_class and character_id = p_character;
  end if;
  if r.id is null and v.id is not null then
    select * into r from public.character_classes where character_id = p_character and class_id = v.class_id;
  end if;
  if r.id is null then
    if exists (select 1 from public.character_classes where character_id = p_character) then
      perform public._gov_gate(p_character, 'build.class_add');
    else
      perform public._gov_gate(p_character, 'build.class_level');
    end if;
    if p_subclass_version is not null then perform public._gov_gate(p_character, 'build.subclass'); end if;
  else
    if r.class_version_id is distinct from p_class_version then perform public._gov_gate(p_character, 'build.class_version'); end if;
    if r.level is distinct from p_level then perform public._gov_gate(p_character, 'build.class_level'); end if;
    if r.subclass_version_id is distinct from p_subclass_version then perform public._gov_gate(p_character, 'build.subclass'); end if;
    if p_is_primary is not null and p_is_primary is distinct from r.is_primary then
      perform public._gov_gate(p_character, 'build.primary_class');
    end if;
  end if;
  if v.id is not null and (r.id is null or r.class_version_id is distinct from p_class_version) then
    perform public._gov_content_check(p_character, public._content_policy_reason(
      (select campaign_id from public.characters where id = p_character), v.rules_edition, v.status = 'legacy',
      v.status = 'playtest' or v.content_scope = 'playtest', v.setting, false, v.source_book_id));
  end if;
  if p_subclass_version is not null and (r.id is null or r.subclass_version_id is distinct from p_subclass_version) then
    select * into sv from public.subclass_versions where id = p_subclass_version;
    if sv.id is not null then
      perform public._gov_content_check(p_character, public._content_policy_reason(
        (select campaign_id from public.characters where id = p_character), null, sv.status = 'legacy',
        sv.source_status = 'playtest' or sv.status = 'playtest', sv.setting, false, sv.source_book_id));
    end if;
  end if;
end;
$$;

create function public._gov_gate_class_row(p_character_class uuid, p_action text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare c uuid;
begin
  select character_id into c from public.character_classes where id = p_character_class;
  if c is not null then perform public._gov_gate(c, p_action); end if;
end;
$$;

-- class feature choices: ASI / feat / prerequisite confirmation / other choices
create function public._gov_gate_feature_choice(p_character uuid, p_choice text, p_values text[], p_manual_status text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare k text;
begin
  select kind into k from public.class_feature_choices where id = p_choice;
  if k = 'asi' then
    perform public._gov_gate(p_character, 'choice.asi');
    if exists (select 1 from unnest(coalesce(p_values, '{}')) v where v like 'feat:%') then
      perform public._gov_gate(p_character, 'choice.feat');
    end if;
  else
    perform public._gov_gate(p_character, 'choice.class_feature');
  end if;
  if p_manual_status = 'confirmed' then perform public._gov_gate(p_character, 'dm.prerequisite_override'); end if;
end;
$$;

create function public._gov_gate_lineage(p_character uuid, p_version text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v public.lineage_versions;
begin
  perform public._gov_gate(p_character, 'build.lineage');
  select * into v from public.lineage_versions where id = p_version;
  if v.id is not null and not exists (select 1 from public.character_lineages where character_id = p_character and version_id = p_version) then
    perform public._gov_content_check(p_character, public._content_policy_reason(
      (select campaign_id from public.characters where id = p_character), null, v.status = 'legacy', false, v.setting,
      false, v.source_book_id));
  end if;
end;
$$;

create function public._gov_gate_background(p_character uuid, p_version text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v public.background_versions;
begin
  perform public._gov_gate(p_character, 'build.background');
  select * into v from public.background_versions where id = p_version;
  if v.id is not null and not exists (select 1 from public.character_backgrounds where character_id = p_character and version_id = p_version) then
    perform public._gov_content_check(p_character, public._content_policy_reason(
      (select campaign_id from public.characters where id = p_character), v.ruleset, v.legacy, v.status = 'playtest', v.setting,
      false, v.source_book_id));
  end if;
end;
$$;

-- set_character_spell: what the call changes decides the action
create function public._gov_gate_spell(p_character uuid, p_source uuid, p_spell_version text, p_known boolean,
                                       p_prepared boolean, p_always_prepared boolean, p_casting_ability text,
                                       p_ritual_allowed boolean)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare r public.character_spells; s public.character_spellcasting_sources; v public.spell_versions; cs public.catalog_spells;
begin
  select * into s from public.character_spellcasting_sources where id = p_source and character_id = p_character;
  select * into r from public.character_spells where source_id = p_source and spell_version_id = p_spell_version;
  select * into v from public.spell_versions where id = p_spell_version;
  select * into cs from public.catalog_spells where id = v.spell_id;
  if r.id is null then
    if cs.owner_id is not null then perform public._gov_gate(p_character, 'spell.assign_custom'); end if;
    if coalesce(p_always_prepared, false) then perform public._gov_gate(p_character, 'spell.always_prepared');
    elsif s.preparation_mode = 'spellbook' then perform public._gov_gate(p_character, 'spell.spellbook_add');
    elsif s.source_type in ('manual', 'other') then perform public._gov_gate(p_character, 'spell.add_manual');
    elsif coalesce(p_known, true) and s.preparation_mode <> 'prepared' then perform public._gov_gate(p_character, 'spell.learn_known');
    else perform public._gov_gate(p_character, 'spell.prepare');
    end if;
    if v.id is not null then
      perform public._gov_content_check(p_character, public._content_policy_reason(
        (select campaign_id from public.characters where id = p_character), null, v.status = 'legacy',
        v.rule_status = 'playtest', v.setting, cs.owner_id is not null, v.source_book_id));
    end if;
  else
    if p_always_prepared is not null and p_always_prepared is distinct from r.always_prepared then
      perform public._gov_gate(p_character, 'spell.always_prepared');
    end if;
    if p_known is not null and p_known is distinct from r.known then
      perform public._gov_gate(p_character, case when p_known then 'spell.learn_known' else 'spell.remove' end);
    end if;
    if p_prepared is not null and p_prepared is distinct from r.prepared then perform public._gov_gate(p_character, 'spell.prepare'); end if;
    if (p_casting_ability is not null and p_casting_ability is distinct from r.casting_ability)
       or (p_ritual_allowed is not null and p_ritual_allowed is distinct from r.ritual_allowed) then
      perform public._gov_gate(p_character, 'spell.change_source');
    end if;
  end if;
end;
$$;

create function public._gov_gate_spell_row(p_character_spell uuid, p_action text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare c uuid;
begin
  select character_id into c from public.character_spells where id = p_character_spell;
  if c is not null then perform public._gov_gate(c, p_action); end if;
end;
$$;

create function public._gov_gate_source_row(p_source uuid, p_action text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare c uuid;
begin
  select character_id into c from public.character_spellcasting_sources where id = p_source;
  if c is not null then perform public._gov_gate(c, p_action); end if;
end;
$$;

-- add_inventory_item: mundane official / magic / campaign custom (plus the content policy)
create function public._gov_gate_add_item(p_inventory uuid, p_item text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare inv public.inventories; it public.items;
begin
  select * into inv from public.inventories where id = p_inventory;
  if inv.kind <> 'character' or inv.character_id is null then return; end if;
  select * into it from public.items where id = p_item;
  if it.owner_id is not null then perform public._gov_gate(inv.character_id, 'inventory.assign_custom');
  elsif coalesce(it.is_magic, false) then perform public._gov_gate(inv.character_id, 'inventory.add_magic');
  else perform public._gov_gate(inv.character_id, 'inventory.add_mundane');
  end if;
  if it.id is not null then
    perform public._gov_content_check(inv.character_id, public._content_policy_reason(
      (select campaign_id from public.characters where id = inv.character_id), null, false, false, null,
      it.owner_id is not null, it.source_book_id));
  end if;
end;
$$;

create function public._gov_gate_item_quantity(p_item uuid, p_quantity int)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items;
begin
  select * into r from public.inventory_items where id = p_item;
  if r.id is null then return; end if;
  perform public._gov_gate_inventory(r.inventory_id, case when p_quantity = 0 then 'inventory.delete' else 'inventory.quantity' end);
end;
$$;

create function public._gov_gate_companion(p_companion uuid, p_action text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare c uuid;
begin
  select character_id into c from public.character_companions where id = p_companion;
  if c is not null then perform public._gov_gate(c, p_action); end if;
end;
$$;

create function public._gov_gate_resource_row(p_resource uuid, p_action text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare c uuid;
begin
  select character_id into c from public.character_resources where id = p_resource;
  if c is not null then perform public._gov_gate(c, p_action); end if;
end;
$$;

-- Wild Shape settings: loosening the seen-form check (enforce -> warn) follows the policy of marking forms as seen;
-- "unrestricted" stays DM-only in set_wild_shape_settings itself
create function public._gov_gate_wild_shape_settings(p_character uuid, p_seen_mode text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare cur text; rank_of constant jsonb := '{"enforce": 0, "warn": 1, "unrestricted": 2}';
begin
  select seen_mode into cur from public.character_wild_shape_settings where character_id = p_character;
  if p_seen_mode is not null and coalesce((rank_of ->> p_seen_mode)::int, 0) > coalesce((rank_of ->> coalesce(cur, 'enforce'))::int, 0) then
    perform public._gov_gate(p_character, 'runtime.mark_seen_form');
  end if;
  perform public._gov_gate(p_character, 'runtime.wild_shape');
end;
$$;

-- ---- direct table writes of the authenticated role ------------------------------------------------------------------------
-- SECURITY INVOKER on purpose: current_user is the role of the statement ('authenticated' for PostgREST writes, the
-- function owner inside SECURITY DEFINER RPCs, which gate themselves).
create function public.characters_governance()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare acts text[] := '{}'; a text;
begin
  if current_user <> 'authenticated' then return new; end if;
  if new.name is distinct from old.name then acts := array_append(acts, 'identity.name'); end if;
  if new.portrait_url is distinct from old.portrait_url then acts := array_append(acts, 'identity.portrait'); end if;
  if (new.alignment, new.race, new.class_name, new.subclass, new.background, new.experience, new.pending_choices)
     is distinct from (old.alignment, old.race, old.class_name, old.subclass, old.background, old.experience, old.pending_choices) then
    acts := array_append(acts, 'identity.descriptive');
  end if;
  if (new.strength, new.dexterity, new.constitution, new.intelligence, new.wisdom, new.charisma)
     is distinct from (old.strength, old.dexterity, old.constitution, old.intelligence, old.wisdom, old.charisma) then
    acts := array_append(acts, 'build.ability_scores');
  end if;
  if new.level is distinct from old.level then acts := array_append(acts, 'build.class_level'); end if;
  if new.hp_max is distinct from old.hp_max then acts := array_append(acts, 'build.hp_max'); end if;
  if (new.save_proficiencies, new.skill_proficiencies, new.proficiencies, new.equipment_proficiencies)
     is distinct from (old.save_proficiencies, old.skill_proficiencies, old.proficiencies, old.equipment_proficiencies) then
    acts := array_append(acts, 'build.manual_proficiency');
  end if;
  if (new.ac, new.ac_override, new.speed, new.initiative_bonus, new.hit_die)
     is distinct from (old.ac, old.ac_override, old.speed, old.initiative_bonus, old.hit_die) then
    acts := array_append(acts, 'build.manual_stats');
  end if;
  if (new.hp_current, new.hp_temp, new.death_successes, new.death_failures, new.inspiration, new.hit_dice_current)
     is distinct from (old.hp_current, old.hp_temp, old.death_successes, old.death_failures, old.inspiration, old.hit_dice_current) then
    acts := array_append(acts, 'runtime.hp');
  end if;
  if new.conditions is distinct from old.conditions then acts := array_append(acts, 'runtime.conditions'); end if;
  if (new.cp, new.sp, new.ep, new.gp, new.pp) is distinct from (old.cp, old.sp, old.ep, old.gp, old.pp) then
    acts := array_append(acts, 'inventory.currency');
  end if;
  if new.spellcasting_ability is distinct from old.spellcasting_ability then acts := array_append(acts, 'spell.change_source'); end if;
  if (old.campaign_id is not null and new.campaign_id is distinct from old.campaign_id) or new.owner_id is distinct from old.owner_id then
    acts := array_append(acts, 'build.move_campaign');
  end if;
  foreach a in array acts loop perform public._gov_gate(old.id, a); end loop;
  return new;
end;
$$;
create trigger characters_governance before update on public.characters
  for each row execute function public.characters_governance();

-- legacy free-text child tables
create function public.character_children_governance()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare cid uuid; act text;
begin
  if current_user <> 'authenticated' then return coalesce(new, old); end if;
  cid := coalesce(new.character_id, old.character_id);
  -- one branch per table: a record field is only resolved for the table that has it
  if tg_table_name in ('notes', 'features') then
    act := 'identity.notes';
  elsif tg_table_name = 'attacks' then
    act := 'build.manual_stats';
  elsif tg_table_name = 'spells' then
    act := case when tg_op = 'UPDATE' and (to_jsonb(new) - 'prepared' - 'sort_order') = (to_jsonb(old) - 'prepared' - 'sort_order')
                then 'spell.prepare' else 'spell.add_manual' end;
  elsif tg_table_name = 'feature_trackers' then
    act := case when tg_op = 'UPDATE' and (to_jsonb(new) - 'current' - 'sort_order') = (to_jsonb(old) - 'current' - 'sort_order')
                then 'runtime.resources' else 'build.manual_stats' end;
  elsif tg_table_name = 'spell_slots' then
    act := case when tg_op = 'UPDATE' and (to_jsonb(new) ->> 'total') = (to_jsonb(old) ->> 'total') then 'runtime.resources' else 'build.manual_stats' end;
  end if;
  -- slot rows and note rows are created by the character insert trigger (not a governed change)
  if tg_op = 'INSERT' and tg_table_name in ('spell_slots', 'notes') then return new; end if;
  perform public._gov_gate(cid, act);
  return coalesce(new, old);
end;
$$;
do $$
declare t text;
begin
  foreach t in array array['notes', 'features', 'attacks', 'spells', 'feature_trackers', 'spell_slots'] loop
    execute format('create trigger %1$s_governance before insert or update or delete on public.%1$I
                      for each row execute function public.character_children_governance()', t);
  end loop;
end $$;

-- mechanical item modifiers: authored by DMs only from now on (existing rows are kept)
drop policy if exists "item_modifiers_homebrew_write" on public.item_modifiers;
create policy "item_modifiers_homebrew_write" on public.item_modifiers for all to authenticated
  using (public.can_edit_owned(owner_id, campaign_id) and public.can_author_content(campaign_id))
  with check (public.can_edit_owned(owner_id, campaign_id) and public.can_author_content(campaign_id)
              and (campaign_id is null or public.is_admin() or public.is_campaign_member(campaign_id)));

-- ---- audit helper ------------------------------------------------------------------------------------------------------
create function public._audit(p_campaign uuid, p_character uuid, p_type text, p_summary text, p_before jsonb default null,
                              p_after jsonb default null, p_reason text default null, p_request uuid default null,
                              p_visibility text default 'party')
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare i uuid;
begin
  insert into public.campaign_audit_events (campaign_id, character_id, actor_id, event_type, summary, before, after, reason,
                                            request_id, visibility)
  values (coalesce(p_campaign, (select campaign_id from public.characters where id = p_character)), p_character, auth.uid(),
          p_type, left(p_summary, 300), p_before, p_after, left(p_reason, 1000), p_request, p_visibility)
  returning id into i;
  return i;
end;
$$;

-- ---- read models and DM operations ----------------------------------------------------------------------------------------
create function public._campaign_governance_json(p_campaign uuid)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'campaign_id', c.id, 'campaign_name', c.name, 'configured', g.campaign_id is not null,
    'preset', coalesce(g.preset, 'relaxed'), 'custom_base', coalesce(g.custom_base, 'standard'),
    'migrated_from', g.migrated_from, 'revision', coalesce(g.revision, 0),
    'unmet_prerequisites', coalesce(g.unmet_prerequisites, 'propose'),
    'require_approval_note', coalesce(g.require_approval_note, false),
    'allow_edit_and_approve', coalesce(g.allow_edit_and_approve, true),
    'content', jsonb_build_object('rulesets', to_jsonb(coalesce(g.content_rulesets, '{2014,2024}')),
      'allow_legacy', coalesce(g.content_allow_legacy, true), 'allow_playtest', coalesce(g.content_allow_playtest, true),
      'allow_setting', coalesce(g.content_allow_setting, true), 'allow_custom', coalesce(g.content_allow_custom, true),
      'excluded_sources', to_jsonb(coalesce(g.content_excluded_sources, '{}'))),
    'updated_at', g.updated_at, 'updated_by', g.updated_by,
    'actions', (select jsonb_agg(jsonb_build_object('key', a.action_key, 'category', a.category, 'label', a.label,
                  'description', a.description, 'lock_class', a.lock_class, 'max_player', a.max_player,
                  'can_request', a.can_request, 'decision', public._gov_policy(c.id, a.action_key),
                  'preset_decision', case case when g.preset = 'custom' then g.custom_base else coalesce(g.preset, 'relaxed') end
                                       when 'strict' then a.strict when 'standard' then a.standard else a.relaxed end,
                  'overridden', o.decision is not null,
                  'relaxed', a.relaxed, 'standard', a.standard, 'strict', a.strict) order by a.sort_order)
                from public.governance_actions a
                left join public.campaign_policy_overrides o on o.campaign_id = c.id and o.action_key = a.action_key),
    'report', (select to_jsonb(r) - 'campaign_id' from public.governance_migration_report r where r.campaign_id = c.id))
  from public.campaigns c left join public.campaign_governance g on g.campaign_id = c.id
  where c.id = p_campaign;
$$;

create function public.get_campaign_governance(p_campaign uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not (public.is_admin() or public.is_campaign_member(p_campaign)) then
    raise exception 'Campaign not found' using errcode = '42501';
  end if;
  return public._campaign_governance_json(p_campaign)
    || jsonb_build_object('can_edit', public.is_admin() or public.is_campaign_dm(p_campaign));
end;
$$;

-- p_settings: preset, custom_base, unmet_prerequisites, require_approval_note, allow_edit_and_approve,
--   content {rulesets[], allow_legacy, allow_playtest, allow_setting, allow_custom, excluded_sources[]},
--   overrides {action_key: decision | null (remove)}. A non-empty overrides object turns the preset into "custom".
create function public.set_campaign_governance(p_campaign uuid, p_settings jsonb, p_expected_revision int default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare g public.campaign_governance; before jsonb; k text; v jsonb; a public.governance_actions; ct jsonb;
  allowed constant text[] := array['preset', 'custom_base', 'unmet_prerequisites', 'require_approval_note', 'allow_edit_and_approve',
                                   'content', 'overrides'];
begin
  if auth.uid() is null or not (public.is_admin() or public.is_campaign_dm(p_campaign)) then
    raise exception 'Only a DM of this campaign can change its rules' using errcode = '42501';
  end if;
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then raise exception 'Settings are missing' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_settings) loop
    if not k = any (allowed) then raise exception 'Unknown setting "%"', k using errcode = '22023'; end if;
  end loop;
  insert into public.campaign_governance (campaign_id, preset, updated_by) values (p_campaign, 'relaxed', auth.uid())
  on conflict (campaign_id) do nothing;
  select * into g from public.campaign_governance where campaign_id = p_campaign for update;
  if p_expected_revision is not null and p_expected_revision <> g.revision then
    raise exception 'Someone else changed these rules meanwhile. Reload and try again.' using errcode = '40001';
  end if;
  before := public._campaign_governance_json(p_campaign);
  if p_settings ? 'preset' then
    if p_settings ->> 'preset' not in ('relaxed', 'standard', 'strict', 'custom') then raise exception 'Unknown preset' using errcode = '22023'; end if;
    g.preset := p_settings ->> 'preset';
    if g.preset <> 'custom' and not p_settings ? 'overrides' then
      delete from public.campaign_policy_overrides where campaign_id = p_campaign;   -- a named preset resets single changes
    end if;
  end if;
  if p_settings ? 'custom_base' then
    if p_settings ->> 'custom_base' not in ('relaxed', 'standard', 'strict') then raise exception 'Unknown base preset' using errcode = '22023'; end if;
    g.custom_base := p_settings ->> 'custom_base';
  end if;
  if p_settings ? 'unmet_prerequisites' then
    if p_settings ->> 'unmet_prerequisites' not in ('block', 'propose', 'dm_override') then
      raise exception 'Unknown prerequisite mode' using errcode = '22023';
    end if;
    g.unmet_prerequisites := p_settings ->> 'unmet_prerequisites';
  end if;
  if p_settings ? 'require_approval_note' then g.require_approval_note := public._j_bool(p_settings, 'require_approval_note', false); end if;
  if p_settings ? 'allow_edit_and_approve' then g.allow_edit_and_approve := public._j_bool(p_settings, 'allow_edit_and_approve', true); end if;
  if p_settings ? 'content' then
    ct := p_settings -> 'content';
    if jsonb_typeof(ct) <> 'object' then raise exception 'content must be an object' using errcode = '22023'; end if;
    if ct ? 'rulesets' then
      g.content_rulesets := array(select jsonb_array_elements_text(ct -> 'rulesets'));
      if not g.content_rulesets <@ array['2014', '2024'] or cardinality(g.content_rulesets) = 0 then
        raise exception 'Choose the 2014 rules, the 2024 rules or both' using errcode = '22023';
      end if;
    end if;
    if ct ? 'allow_legacy' then g.content_allow_legacy := public._j_bool(ct, 'allow_legacy', true); end if;
    if ct ? 'allow_playtest' then g.content_allow_playtest := public._j_bool(ct, 'allow_playtest', false); end if;
    if ct ? 'allow_setting' then g.content_allow_setting := public._j_bool(ct, 'allow_setting', true); end if;
    if ct ? 'allow_custom' then g.content_allow_custom := public._j_bool(ct, 'allow_custom', true); end if;
    if ct ? 'excluded_sources' then
      g.content_excluded_sources := array(select jsonb_array_elements_text(ct -> 'excluded_sources'));
      if exists (select 1 from unnest(g.content_excluded_sources) s where not exists (select 1 from public.source_books b where b.id = s)) then
        raise exception 'Unknown source book' using errcode = '22023';
      end if;
    end if;
  end if;
  if p_settings ? 'overrides' then
    if jsonb_typeof(p_settings -> 'overrides') <> 'object' then raise exception 'overrides must be an object' using errcode = '22023'; end if;
    for k, v in select * from jsonb_each(p_settings -> 'overrides') loop
      select * into a from public.governance_actions where action_key = k;
      if a.action_key is null then raise exception 'Unknown action "%"', k using errcode = '22023'; end if;
      if jsonb_typeof(v) = 'null' then
        delete from public.campaign_policy_overrides where campaign_id = p_campaign and action_key = k;
      else
        if public._gov_rank(v #>> '{}') is null then raise exception 'Unknown decision for %', a.label using errcode = '22023'; end if;
        if public._gov_rank(v #>> '{}') < public._gov_rank(a.max_player) then
          raise exception '% cannot be given to players (at most: %)', a.label, replace(a.max_player, '_', ' ') using errcode = '22023';
        end if;
        if v #>> '{}' = 'approval_required' and not a.can_request then
          raise exception '% cannot be requested by players', a.label using errcode = '22023';
        end if;
        insert into public.campaign_policy_overrides (campaign_id, action_key, decision, updated_by)
        values (p_campaign, k, v #>> '{}', auth.uid())
        on conflict (campaign_id, action_key) do update set decision = excluded.decision, updated_by = excluded.updated_by, updated_at = now();
      end if;
    end loop;
    if exists (select 1 from public.campaign_policy_overrides where campaign_id = p_campaign) and g.preset <> 'custom' then
      g.custom_base := case when g.preset in ('relaxed', 'standard', 'strict') then g.preset else g.custom_base end;
      g.preset := 'custom';
    end if;
  end if;
  update public.campaign_governance set preset = g.preset, custom_base = g.custom_base, unmet_prerequisites = g.unmet_prerequisites,
    require_approval_note = g.require_approval_note, allow_edit_and_approve = g.allow_edit_and_approve,
    content_rulesets = g.content_rulesets, content_allow_legacy = g.content_allow_legacy,
    content_allow_playtest = g.content_allow_playtest, content_allow_setting = g.content_allow_setting,
    content_allow_custom = g.content_allow_custom, content_excluded_sources = g.content_excluded_sources,
    revision = g.revision + 1, updated_by = auth.uid(), updated_at = now()
  where campaign_id = p_campaign;
  perform public._audit(p_campaign, null, 'governance_changed', 'Campaign rules changed (preset: ' || g.preset || ')',
                        before - 'actions' - 'report', public._campaign_governance_json(p_campaign) - 'actions' - 'report', null, null, 'party');
  return public.get_campaign_governance(p_campaign);
end;
$$;

-- what the sheet needs: the effective decision of every action for the current user on this character
create function public.get_character_governance(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare ch record; g public.character_governance; dec jsonb := '{}'; a public.governance_actions; r jsonb;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  select c.id, c.campaign_id, c.owner_id, cp.name as campaign_name into ch
  from public.characters c left join public.campaigns cp on cp.id = c.campaign_id where c.id = p_character;
  select * into g from public.character_governance where character_id = p_character;
  for a in select * from public.governance_actions order by sort_order loop
    r := public._gov_decide(p_character, a.action_key);
    dec := dec || jsonb_build_object(a.action_key, case when r ->> 'decision' = 'allow' then 'player_managed' else r ->> 'decision' end);
  end loop;
  return jsonb_build_object(
    'character_id', p_character, 'campaign_id', ch.campaign_id, 'campaign_name', ch.campaign_name,
    'governed', ch.campaign_id is not null,
    'is_dm', public.is_admin() or (ch.campaign_id is not null and public.is_campaign_dm(ch.campaign_id)),
    'preset', (select coalesce(preset, 'relaxed') from public.campaign_governance where campaign_id = ch.campaign_id),
    'lock_mode', coalesce(g.lock_mode, 'unlocked'), 'lock_reason', g.lock_reason, 'locked_at', g.locked_at,
    'setup_complete', coalesce(g.setup_complete, false), 'decisions', dec);
end;
$$;

create function public.set_character_lock(p_character uuid, p_mode text, p_reason text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare ch record; old_mode text;
begin
  select id, campaign_id into ch from public.characters where id = p_character;
  if ch.id is null or auth.uid() is null or not (public.is_admin() or (ch.campaign_id is not null and public.is_campaign_dm(ch.campaign_id))) then
    raise exception 'Only a DM of the character''s campaign can lock it' using errcode = '42501';
  end if;
  if p_mode not in ('unlocked', 'progression_locked', 'build_locked', 'fully_locked', 'archived') then
    raise exception 'Unknown lock mode' using errcode = '22023';
  end if;
  perform 1 from public.characters where id = p_character for update;   -- serializes with request application (_cr_apply)
  insert into public.character_governance (character_id) values (p_character) on conflict (character_id) do nothing;
  select lock_mode into old_mode from public.character_governance where character_id = p_character for update;
  update public.character_governance set lock_mode = p_mode, lock_reason = nullif(btrim(coalesce(p_reason, '')), ''),
    locked_by = auth.uid(), locked_at = now(), updated_at = now() where character_id = p_character;
  perform public._audit(ch.campaign_id, p_character, 'character_lock_changed',
                        'Lock: ' || replace(old_mode, '_', ' ') || ' → ' || replace(p_mode, '_', ' '),
                        jsonb_build_object('lock_mode', old_mode), jsonb_build_object('lock_mode', p_mode), p_reason, null, 'party');
  return public.get_character_governance(p_character);
end;
$$;

create function public.set_character_setup_complete(p_character uuid, p_complete boolean)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare ch record;
begin
  select id, campaign_id into ch from public.characters where id = p_character;
  if ch.id is null or auth.uid() is null or not (public.is_admin() or (ch.campaign_id is not null and public.is_campaign_dm(ch.campaign_id))) then
    raise exception 'Only a DM of the character''s campaign can finish its setup' using errcode = '42501';
  end if;
  insert into public.character_governance (character_id) values (p_character) on conflict (character_id) do nothing;
  update public.character_governance set setup_complete = coalesce(p_complete, true),
    setup_completed_by = auth.uid(), setup_completed_at = now(), updated_at = now() where character_id = p_character;
  perform public._audit(ch.campaign_id, p_character, 'setup_changed',
                        case when coalesce(p_complete, true) then 'Initial setup marked complete' else 'Initial setup reopened' end,
                        null, null, null, null, 'party');
  return public.get_character_governance(p_character);
end;
$$;

-- ---- RLS and grants --------------------------------------------------------------------------------------------------------
alter table public.governance_actions enable row level security;
alter table public.campaign_governance enable row level security;
alter table public.campaign_policy_overrides enable row level security;
alter table public.character_governance enable row level security;
alter table public.governance_migration_report enable row level security;
alter table public.campaign_audit_events enable row level security;
revoke all on public.governance_actions, public.campaign_governance, public.campaign_policy_overrides, public.character_governance,
  public.governance_migration_report, public.campaign_audit_events from anon, authenticated;
create policy "governance_actions_read" on public.governance_actions for select to authenticated using (true);
create policy "campaign_governance_read" on public.campaign_governance for select to authenticated
  using (public.is_admin() or public.is_campaign_member(campaign_id));
create policy "campaign_policy_overrides_read" on public.campaign_policy_overrides for select to authenticated
  using (public.is_admin() or public.is_campaign_member(campaign_id));
create policy "character_governance_read" on public.character_governance for select to authenticated
  using (public.can_access_character(character_id));
create policy "governance_migration_report_read" on public.governance_migration_report for select to authenticated
  using (public.is_admin() or public.is_campaign_dm(campaign_id));
create policy "campaign_audit_events_read" on public.campaign_audit_events for select to authenticated
  using (public.is_admin() or public.is_campaign_dm(campaign_id)
         or (visibility <> 'dm' and character_id is not null
             and exists (select 1 from public.characters c where c.id = character_id and c.owner_id = auth.uid())));
grant select on public.governance_actions, public.campaign_governance, public.campaign_policy_overrides, public.character_governance,
  public.governance_migration_report, public.campaign_audit_events to authenticated;

do $$
declare t text;
begin
  foreach t in array array['campaign_governance', 'character_governance'] loop
    execute format('alter table public.%I replica identity full', t);
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

revoke all on function public._gov_rank(text), public._gov_policy(uuid, text), public._gov_lock_blocks(text, text),
  public._gov_decide(uuid, text), public._gov_gate(uuid, text), public._gov_gate_inventory(uuid, text),
  public._gov_gate_item(uuid, text), public._gov_content_gate(uuid, text), public._content_policy_reason(uuid, text, boolean, boolean, text, boolean, text),
  public._gov_content_check(uuid, text), public._gov_gate_class(uuid, text, int, text, boolean, uuid),
  public._gov_gate_class_row(uuid, text), public._gov_gate_feature_choice(uuid, text, text[], text),
  public._gov_gate_lineage(uuid, text), public._gov_gate_background(uuid, text),
  public._gov_gate_spell(uuid, uuid, text, boolean, boolean, boolean, text, boolean), public._gov_gate_spell_row(uuid, text),
  public._gov_gate_source_row(uuid, text), public._gov_gate_add_item(uuid, text), public._gov_gate_item_quantity(uuid, int),
  public._gov_gate_companion(uuid, text), public._gov_gate_resource_row(uuid, text), public._gov_gate_wild_shape_settings(uuid, text),
  public._audit(uuid, uuid, text, text, jsonb, jsonb, text, uuid, text), public._campaign_governance_json(uuid)
  from public, anon, authenticated;
revoke all on function public.get_campaign_governance(uuid), public.set_campaign_governance(uuid, jsonb, int),
  public.get_character_governance(uuid), public.set_character_lock(uuid, text, text), public.set_character_setup_complete(uuid, boolean),
  public.can_author_content(uuid)
  from public, anon;
grant execute on function public.get_campaign_governance(uuid), public.set_campaign_governance(uuid, jsonb, int),
  public.get_character_governance(uuid), public.set_character_lock(uuid, text, text), public.set_character_setup_complete(uuid, boolean),
  public.can_author_content(uuid)
  to authenticated;
-- the direct-write triggers are SECURITY INVOKER (see above) and call the gate as the writing role; the gate only checks
-- and raises, and reveals no more than get_character_governance
grant execute on function public._gov_gate(uuid, text) to authenticated;

-- ---- governed RPCs (live definitions + one gate statement each) --------------------------------------------------

-- set_character_class(uuid,text,integer,text,boolean,uuid,text)
CREATE OR REPLACE FUNCTION public.set_character_class(p_character uuid, p_class_version text, p_level integer, p_subclass_version text DEFAULT NULL::text, p_is_primary boolean DEFAULT NULL::boolean, p_character_class uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cv public.class_versions; sv public.subclass_versions; cc public.character_classes; existing public.character_classes;
  others int; casts boolean; src uuid;
begin
  perform public._gov_gate_class(p_character, p_class_version, p_level, p_subclass_version, p_is_primary, p_character_class);   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  select * into cv from public.class_versions where id = p_class_version;
  if not found then raise exception 'Unknown class version "%"', p_class_version using errcode = '22023'; end if;
  if p_level is null or p_level not between 1 and 20 then
    raise exception 'A class level is between 1 and 20' using errcode = '22023';
  end if;
  if p_subclass_version is not null then
    select * into sv from public.subclass_versions where id = p_subclass_version;
    if not found or sv.class_id <> cv.class_id then
      raise exception 'Subclass "%" does not belong to %', p_subclass_version, cv.name using errcode = '22023';
    end if;
  end if;
  if length(p_notes) > 500 then raise exception 'Notes are too long' using errcode = '22023'; end if;
  perform 1 from public.characters where id = p_character for update;          -- one class change per character at a time

  if p_character_class is not null then
    select * into existing from public.character_classes where id = p_character_class and character_id = p_character;
    if not found then raise exception 'Character class not found' using errcode = '42501'; end if;
    if existing.class_id <> cv.class_id then
      raise exception 'A class row keeps its class; add % as a new class instead', cv.name using errcode = '22023';
    end if;
  else
    select * into existing from public.character_classes where character_id = p_character and class_id = cv.class_id;
    if found and existing.class_version_id <> cv.id then          -- a version change must name the class row explicitly
      raise exception 'This character already has % (%); change the version of that class instead', cv.name, existing.class_version_id
        using errcode = '22023';
    end if;
  end if;
  select coalesce(sum(level), 0) into others from public.character_classes
  where character_id = p_character and id is distinct from existing.id;
  if others + p_level > 20 then
    raise exception 'Class levels would add up to %; the total character level is at most 20', others + p_level using errcode = '22023';
  end if;

  if existing.id is null then
    insert into public.character_classes (character_id, class_id, class_version_id, subclass_version_id, level, is_primary,
                                          started_at_level, notes, created_by)
    values (p_character, cv.class_id, cv.id, p_subclass_version, p_level, false, others + 1, nullif(btrim(p_notes), ''), auth.uid())
    returning * into cc;
  else
    update public.character_classes set class_version_id = cv.id, subclass_version_id = p_subclass_version, level = p_level,
                                        notes = coalesce(nullif(btrim(p_notes), ''), notes)
    where id = existing.id returning * into cc;
  end if;
  if coalesce(p_is_primary, false) or not exists (select 1 from public.character_classes where character_id = p_character and is_primary) then
    update public.character_classes set is_primary = false where character_id = p_character and is_primary and id <> cc.id;
    update public.character_classes set is_primary = true where id = cc.id;
  end if;

  -- the class spellcasting source: linked to the class row; an unlinked preview source of the same class version is adopted
  casts := cv.multiclass_contribution <> 'none' or coalesce(sv.multiclass_contribution, 'none') <> 'none';
  select id into src from public.character_spellcasting_sources where character_class_id = cc.id;
  if casts and src is null then
    select id into src from public.character_spellcasting_sources
    where character_id = p_character and character_class_id is null and source_type = 'class'
      and class_version_id in (select id from public.class_versions where class_id = cv.class_id)
    order by created_at limit 1;
    if src is not null then
      update public.character_spellcasting_sources set character_class_id = cc.id, casting_ability = null, class_version_id = cv.id
      where id = src;
    else
      insert into public.character_spellcasting_sources (character_id, source_type, label, character_class_id, class_version_id,
                                                         enforce_spell_list, created_by)
      values (p_character, 'class', case when coalesce(sv.multiclass_contribution, 'none') <> 'none' then sv.name else cv.name end,
              cc.id, cv.id, true, auth.uid());
    end if;
  elsif src is not null then
    update public.character_spellcasting_sources set class_version_id = cv.id where id = src;   -- version change follows the class
  end if;
  return public.get_character_class_summary(p_character);
end;
$function$;

-- remove_character_class(uuid,boolean)
CREATE OR REPLACE FUNCTION public.remove_character_class(p_character_class uuid, p_confirm boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cc public.character_classes; n int; cname text;
begin
  perform public._gov_gate_class_row(p_character_class, 'build.class_remove');   -- campaign governance (20261019000100)
  select * into cc from public.character_classes where id = p_character_class;
  if auth.uid() is null or cc.id is null or not public.can_access_character(cc.character_id) then
    raise exception 'Character class not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = cc.character_id for update;
  select name into cname from public.classes where id = cc.class_id;
  select count(*) into n from public.character_spells g join public.character_spellcasting_sources s on s.id = g.source_id
  where s.character_class_id = cc.id;
  if n > 0 and not coalesce(p_confirm, false) then
    raise exception 'Removing % also removes its spellcasting source and % spell(s); confirm to continue', cname, n
      using errcode = '22023', hint = 'confirm_required';
  end if;
  delete from public.character_classes where id = cc.id;              -- its source, spells and resources go with it
  if cc.is_primary then
    update public.character_classes set is_primary = true
    where id = (select id from public.character_classes where character_id = cc.character_id order by level desc, created_at limit 1);
  end if;
  return public.get_character_class_summary(cc.character_id);
end;
$function$;

-- set_character_subclass(uuid,uuid,text)
CREATE OR REPLACE FUNCTION public.set_character_subclass(p_character uuid, p_character_class uuid, p_subclass_version text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cc public.character_classes;
begin
  perform public._gov_gate(p_character, 'build.subclass');   -- campaign governance (20261019000100)
  cc := public._cf_class_row(p_character, p_character_class);
  perform public.set_character_class(p_character, cc.class_version_id, cc.level, nullif(btrim(p_subclass_version), ''), null, cc.id);
  return public.get_character_class_features(p_character);
end;
$function$;

-- set_character_feature_choice(uuid,uuid,text,text,text[],text,boolean)
CREATE OR REPLACE FUNCTION public.set_character_feature_choice(p_character uuid, p_character_class uuid, p_unlock text, p_choice text, p_values text[] DEFAULT '{}'::text[], p_manual_status text DEFAULT NULL::text, p_allow_partial boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cc public.character_classes; ch record; cf public.class_feature_choices; err text; n int; vals text[]; cid uuid;
  pre jsonb; full_state jsonb; opt record;
begin
  perform public._gov_gate_feature_choice(p_character, p_choice, p_values, p_manual_status);   -- campaign governance (20261019000100)
  cc := public._cf_class_row(p_character, p_character_class);
  select * into ch from public._character_feature_choice_rows(p_character) x
  where x.character_class_id = p_character_class and x.unlock_id = p_unlock and x.choice_id = p_choice;
  if not found then raise exception 'This choice does not belong to this class' using errcode = '22023'; end if;
  select * into cf from public.class_feature_choices where id = p_choice;
  if p_manual_status is not null and p_manual_status not in ('applied_manually', 'confirmed') then
    raise exception 'Unknown manual status "%"', p_manual_status using errcode = '22023';
  end if;
  if p_manual_status = 'applied_manually' and cf.kind <> 'asi' then
    raise exception 'Only an ability score improvement can be marked as already applied' using errcode = '22023';
  end if;
  vals := coalesce((select array_agg(btrim(v)) from unnest(p_values) v where btrim(v) <> ''), '{}');
  n := cardinality(vals);
  if n > 0 or p_manual_status is not null then
    if not ch.unlock_active then
      raise exception '% is not active for this character (%)', ch.feature_name, ch.unlock_status using errcode = '22023';
    end if;
    if not ch.applicable then
      raise exception '% applies only to the % class', ch.label, case when ch.applies_to = 'primary_class' then 'primary' else 'non-primary' end
        using errcode = '22023';
    end if;
    if not ch.enabled then raise exception '% depends on another choice; make that choice first', ch.label using errcode = '22023'; end if;
    if ch.class_level < ch.choice_level then
      raise exception '% opens at % level %', ch.label, ch.class_name, ch.choice_level using errcode = '22023';
    end if;
    err := public._cf_choice_error(p_character, p_character_class, p_unlock, cf, vals, ch.max_picks, true);
    if err is not null then raise exception '%: %', ch.label, err using errcode = '22023'; end if;
    if n < ch.min_picks and not coalesce(p_allow_partial, false) and not (cf.kind = 'asi' and p_manual_status = 'applied_manually') then
      raise exception '%: choose at least %', ch.label, ch.min_picks using errcode = '22023';
    end if;
    -- option prerequisites: an evaluable unmet prerequisite blocks; text prerequisites need a confirmation (warning)
    for opt in select o.* from public.class_feature_choice_options o where o.choice_id = p_choice and o.option_id = any (vals) loop
      pre := public._cf_prereq(opt.prerequisites, jsonb_build_object('class_level', cc.level,
               'total_level', (select sum(level) from public.character_classes where character_id = p_character),
               'subclass_version_id', cc.subclass_version_id,
               'chosen', (select coalesce(jsonb_agg(c2.choice_id || ':' || v2.value), '[]') from public.character_feature_choices c2
                          join public.character_feature_choice_values v2 on v2.character_choice_id = c2.id
                          where c2.character_class_id = p_character_class),
               'abilities', (select jsonb_object_agg(k, (d -> 'abilities' -> k ->> 'score')::int)
                             from (select public.get_character_derived_stats(p_character) as d) dd, jsonb_object_keys(dd.d -> 'abilities') k),
               'spells', (select coalesce(jsonb_agg(distinct g.spell_version_id), '[]') from public.character_spells g where g.character_id = p_character),
               'features', (select coalesce(jsonb_agg(distinct u.feature_id), '[]') from public._character_feature_unlocks(p_character) u where u.active),
               'confirmed', p_manual_status = 'confirmed'));
      if pre ->> 'status' = 'unmet' then
        raise exception '% needs %', opt.label, (select string_agg(i ->> 'label', ', ') from jsonb_array_elements(pre -> 'items') i
                                                 where i ->> 'status' = 'unmet') using errcode = '22023';
      end if;
    end loop;
  end if;

  if n = 0 and p_manual_status is null then
    delete from public.character_feature_choices where character_class_id = p_character_class and unlock_id = p_unlock and choice_id = p_choice;
  else
    insert into public.character_feature_choices (character_id, character_class_id, unlock_id, choice_id, manual_status, created_by)
    values (p_character, p_character_class, p_unlock, p_choice, p_manual_status, auth.uid())
    on conflict (character_class_id, unlock_id, choice_id) do update set manual_status = excluded.manual_status, updated_at = now()
    returning id into cid;
    delete from public.character_feature_choice_values where character_choice_id = cid;
    insert into public.character_feature_choice_values (character_choice_id, pick, value)
    select cid, ord, v from unnest(vals) with ordinality u(v, ord);
  end if;
  return public.get_character_class_features(p_character);
end;
$function$;

-- set_character_optional_feature(uuid,uuid,text,boolean)
CREATE OR REPLACE FUNCTION public.set_character_optional_feature(p_character uuid, p_character_class uuid, p_unlock text, p_enabled boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cc public.character_classes; u public.class_feature_unlocks;
begin
  perform public._gov_gate(p_character, 'choice.optional_feature');   -- campaign governance (20261019000100)
  cc := public._cf_class_row(p_character, p_character_class);
  select * into u from public.class_feature_unlocks where id = p_unlock;
  if not found or not (u.class_version_id = cc.class_version_id or u.subclass_version_id = cc.subclass_version_id) then
    raise exception 'This feature does not belong to this class' using errcode = '22023';
  end if;
  if not u.is_optional then raise exception 'This feature is not optional' using errcode = '22023'; end if;
  if coalesce(p_enabled, false) then
    if cc.level < u.level then
      raise exception 'This optional feature opens at class level %', u.level using errcode = '22023';
    end if;
    insert into public.character_optional_features (character_id, character_class_id, unlock_id, created_by)
    values (p_character, p_character_class, p_unlock, auth.uid()) on conflict do nothing;
  else
    delete from public.character_optional_features where character_class_id = p_character_class and unlock_id = p_unlock;
  end if;
  return public.get_character_class_features(p_character);
end;
$function$;

-- import_character_class_features(uuid,jsonb)
CREATE OR REPLACE FUNCTION public.import_character_class_features(p_character uuid, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare e jsonb; cc public.character_classes; cf public.class_feature_choices; vals text[]; err text; cid uuid; ccid uuid;
  applied_c int := 0; applied_o int := 0; applied_r int := 0; unresolved jsonb := '[]'; warnings jsonb := '[]'; me jsonb;
  mods jsonb; exp int; cap int; rid text;
begin
  perform public._gov_gate(p_character, 'build.class_level');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if jsonb_typeof(p_payload) <> 'object' then raise exception 'The class feature data must be an object' using errcode = '22023'; end if;
  perform 1 from public.characters where id = p_character for update;

  -- optional features first (a replacement decides which features are active)
  for e in select * from jsonb_array_elements(coalesce(p_payload -> 'optionalFeatures', '[]')) loop
    cc := null;
    ccid := case when p_payload -> 'classRows' ->> (e ->> 'classKey') ~ '^[0-9a-f-]{36}$'
                 then (p_payload -> 'classRows' ->> (e ->> 'classKey'))::uuid end;
    select * into cc from public.character_classes where id = ccid and character_id = p_character;
    if cc.id is null or not exists (select 1 from public.class_feature_unlocks u where u.id = e ->> 'unlock' and u.is_optional
                                      and (u.class_version_id = cc.class_version_id or u.subclass_version_id = cc.subclass_version_id)) then
      unresolved := unresolved || jsonb_build_object('kind', 'optional_feature', 'entry', e, 'reason', 'unknown class row or feature');
      continue;
    end if;
    insert into public.character_optional_features (character_id, character_class_id, unlock_id, created_by)
    values (p_character, cc.id, e ->> 'unlock', auth.uid()) on conflict do nothing;
    applied_o := applied_o + 1;
  end loop;

  for e in select * from jsonb_array_elements(coalesce(p_payload -> 'choices', '[]')) loop
    cc := null; cf := null;
    ccid := case when p_payload -> 'classRows' ->> (e ->> 'classKey') ~ '^[0-9a-f-]{36}$'
                 then (p_payload -> 'classRows' ->> (e ->> 'classKey'))::uuid end;
    select * into cc from public.character_classes where id = ccid and character_id = p_character;
    select c.* into cf from public.class_feature_choices c join public.class_feature_unlocks u on u.feature_version_id = c.feature_version_id
    where c.id = e ->> 'choice' and u.id = e ->> 'unlock'
      and (u.class_version_id = cc.class_version_id or u.subclass_version_id = cc.subclass_version_id);
    if cc.id is null or cf.id is null then
      unresolved := unresolved || jsonb_build_object('kind', 'choice', 'entry', e, 'reason', 'unknown class row, feature or choice');
      continue;
    end if;
    continue when cf.kind = 'subclass';                                          -- the subclass comes with the class row
    vals := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(e -> 'values', '[]')) x where btrim(x) <> ''), '{}');
    err := public._cf_choice_error(p_character, cc.id, e ->> 'unlock', cf, vals, 20, false);
    if err is null and e ->> 'manualStatus' is not null and e ->> 'manualStatus' not in ('applied_manually', 'confirmed') then
      err := 'unknown manual status';
    end if;
    if err is not null then
      unresolved := unresolved || jsonb_build_object('kind', 'choice', 'entry', e, 'reason', err);
      continue;
    end if;
    if cardinality(vals) > cf.max_picks then
      warnings := warnings || jsonb_build_object('code', 'over_selected', 'message', format('%s: %s values imported, %s allowed (kept for review)',
                                                  cf.label, cardinality(vals), cf.max_picks));
    end if;
    insert into public.character_feature_choices (character_id, character_class_id, unlock_id, choice_id, manual_status, created_by)
    values (p_character, cc.id, e ->> 'unlock', cf.id, e ->> 'manualStatus', auth.uid())
    on conflict (character_class_id, unlock_id, choice_id) do update set manual_status = excluded.manual_status
    returning id into cid;
    delete from public.character_feature_choice_values where character_choice_id = cid;
    insert into public.character_feature_choice_values (character_choice_id, pick, value)
    select cid, ord, v from unnest(vals) with ordinality u(v, ord);
    applied_c := applied_c + 1;
  end loop;

  mods := public._character_mods(p_character);
  perform set_config('tavern.resource_engine', 'on', true);
  for e in select * from jsonb_array_elements(coalesce(p_payload -> 'resources', '[]')) loop
    me := null;
    ccid := case when p_payload -> 'classRows' ->> (e ->> 'classKey') ~ '^[0-9a-f-]{36}$'
                 then (p_payload -> 'classRows' ->> (e ->> 'classKey'))::uuid end;
    rid := e ->> 'resource';
    select x into me from jsonb_array_elements(public._character_feature_resources(p_character, mods)) x
    where x ->> 'character_class_id' = ccid::text and x ->> 'resource_id' = rid;
    if me is null then
      unresolved := unresolved || jsonb_build_object('kind', 'resource', 'entry', e, 'reason', 'this class does not grant the resource now');
      continue;
    end if;
    exp := coalesce((e ->> 'expended')::int, 0);
    cap := case when (me ->> 'unlimited')::boolean or not (me ->> 'max_known')::boolean then null
                else greatest(coalesce((me ->> 'base_max')::int, 0) + least(greatest(coalesce((e ->> 'maxAdjustment')::int, 0), -20), 20), 0)
                     + least(greatest(coalesce((e ->> 'temporaryBonus')::int, 0), 0), 99) end;
    if exp < 0 or (cap is not null and exp > cap) then
      warnings := warnings || jsonb_build_object('code', 'resource_clamped', 'resource', rid,
        'message', format('%s: %s used was adjusted to %s (maximum %s)', me ->> 'name', exp,
                          least(greatest(exp, 0), coalesce(cap, 99)), coalesce(cap::text, '?')));
      exp := least(greatest(exp, 0), coalesce(cap, 99));
    end if;
    insert into public.character_resources (character_id, resource_key, name, source_type, source_id, character_class_id,
                                            feature_resource_id, recharge, created_by)
    values (p_character, 'cf-' || rid, me ->> 'name', case when me ->> 'origin' = 'subclass' then 'subclass' else 'class' end,
            me ->> 'feature_version_id', ccid, rid, me ->> 'recharge', auth.uid())
    on conflict (character_class_id, feature_resource_id) where feature_resource_id is not null do nothing;
    update public.character_resources set expended = exp,
           temporary_bonus = least(greatest(coalesce((e ->> 'temporaryBonus')::int, 0), 0), 99),
           max_adjustment = least(greatest(coalesce((e ->> 'maxAdjustment')::int, 0), -20), 20)
    where character_class_id = ccid and feature_resource_id = rid;
    insert into public.character_resource_events (character_id, event_type, pool, feature_resource_id, expended_after, reason)
    values (p_character, 'manual_set', 'resource', rid, exp, 'Imported from JSON');
    applied_r := applied_r + 1;
  end loop;
  perform set_config('tavern.resource_engine', 'off', true);
  return jsonb_build_object('applied', jsonb_build_object('choices', applied_c, 'optional_features', applied_o, 'resources', applied_r),
                            'unresolved', unresolved, 'warnings', warnings);
end;
$function$;

-- set_character_lineage(uuid,text,text,jsonb,boolean,boolean)
CREATE OR REPLACE FUNCTION public.set_character_lineage(p_character uuid, p_version text, p_subversion text DEFAULT NULL::text, p_choices jsonb DEFAULT '{}'::jsonb, p_ability_bonuses_included boolean DEFAULT false, p_require_complete boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v public.lineage_versions; s public.lineage_versions; ch public.lineage_choices; k text; vals text[]; err text;
  res jsonb; missing text;
begin
  perform public._gov_gate_lineage(p_character, p_version);   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  select * into v from public.lineage_versions where id = p_version;
  if not found then raise exception 'Unknown lineage version "%"', p_version using errcode = '22023'; end if;
  if v.kind <> 'base' then raise exception '"%" is a sub-lineage; choose its parent version first', v.name using errcode = '22023'; end if;
  if p_subversion is not null then
    select * into s from public.lineage_versions where id = p_subversion;
    if not found or s.parent_version_id is distinct from v.id then
      raise exception '"%" is not a sub-lineage of %', p_subversion, v.name using errcode = '22023';
    end if;
  elsif v.requires_child then
    raise exception '% needs a sub-lineage', v.name using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(p_choices, '{}')) <> 'object' then
    raise exception 'Choices must be an object {choice_id: [values]}' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('lineage:' || p_character::text));

  for k in select jsonb_object_keys(coalesce(p_choices, '{}')) loop
    select * into ch from public.lineage_choices where id = k and version_id in (v.id, p_subversion);
    if not found then raise exception 'Choice "%" does not belong to this lineage', k using errcode = '22023'; end if;
    if jsonb_typeof(p_choices -> k) <> 'array' then
      raise exception '%: values must be a list', ch.label using errcode = '22023';
    end if;
    select coalesce(array_agg(x), '{}') into vals from jsonb_array_elements_text(p_choices -> k) x;
    err := public._lineage_choice_error(ch, vals);
    if err is not null then raise exception '%: %', ch.label, err using errcode = '22023'; end if;
  end loop;

  insert into public.character_lineages (character_id, lineage_id, version_id, subversion_id, ability_bonuses_included, updated_by)
  values (p_character, v.lineage_id, v.id, p_subversion, coalesce(p_ability_bonuses_included, false), auth.uid())
  on conflict (character_id) do update set lineage_id = excluded.lineage_id, version_id = excluded.version_id,
    subversion_id = excluded.subversion_id, ability_bonuses_included = excluded.ability_bonuses_included,
    updated_by = excluded.updated_by;
  delete from public.character_lineage_choices where character_id = p_character;
  insert into public.character_lineage_choices (character_id, choice_id, pick, value)
  select p_character, kv.key, x.ord, x.val
  from jsonb_each(coalesce(p_choices, '{}')) kv, jsonb_array_elements_text(kv.value) with ordinality x(val, ord);

  -- drop values of choices the final selection disables (a replaced trait, an option that was not chosen)
  res := public.get_character_lineage(p_character);
  delete from public.character_lineage_choices
  where character_id = p_character
    and choice_id in (select c ->> 'id' from jsonb_array_elements(res -> 'choices') c where c ->> 'status' = 'disabled');
  if found then res := public.get_character_lineage(p_character); end if;

  if p_require_complete then
    select string_agg(c ->> 'label', ', ') into missing from jsonb_array_elements(res -> 'choices') c where c ->> 'status' = 'missing';
    if missing is not null then raise exception 'Incomplete lineage choices: %', missing using errcode = '22023'; end if;
  end if;
  return res;
end;
$function$;

-- clear_character_lineage(uuid)
CREATE OR REPLACE FUNCTION public.clear_character_lineage(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform public._gov_gate(p_character, 'build.lineage');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  delete from public.character_lineages where character_id = p_character;
  return jsonb_build_object('character_id', p_character, 'cleared', found);
end;
$function$;

-- set_character_background(uuid,text,jsonb,jsonb,jsonb,jsonb)
CREATE OR REPLACE FUNCTION public.set_character_background(p_character uuid, p_version text, p_ability jsonb DEFAULT NULL::jsonb, p_choices jsonb DEFAULT '{}'::jsonb, p_replacements jsonb DEFAULT '[]'::jsonb, p_options jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v public.background_versions; c public.background_choices; vals text[]; val text; okind text; oid text; n int; mode text;
  alloc jsonb := '{}'; k text; opt_count int; picked text[]; r jsonb; prev text; chars jsonb;
begin
  perform public._gov_gate_background(p_character, p_version);   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  select * into v from public.background_versions where id = p_version;
  if not found then raise exception 'Unknown background version "%"', p_version using errcode = '22023'; end if;
  if v.dm_permission and not coalesce((p_options ->> 'allow_playtest')::boolean, false) then
    raise exception '% is % content: confirm that your DM allows it', v.name, case when v.status = 'playtest' then 'playtest (Unearthed Arcana)' else 'restricted' end
      using errcode = '22023';
  end if;

  -- ability increases: only the 2024 package, only the three listed abilities, +2 / +1 to different ones or +1 to all three
  mode := nullif(p_ability ->> 'mode', '');
  if v.ruleset = '2014' then
    if mode is not null or coalesce(p_ability -> 'allocation', '{}') <> '{}' then
      raise exception 'A legacy background has no ability score increases (they come from the lineage)' using errcode = '22023';
    end if;
  elsif mode is not null then
    for k in select jsonb_object_keys(coalesce(p_ability -> 'allocation', '{}')) loop
      if not exists (select 1 from public.background_ability_options where version_id = v.id and ability = k) then
        raise exception '% can only increase %', v.name,
          (select string_agg(upper(ability), ', ') from public.background_ability_options where version_id = v.id) using errcode = '22023';
      end if;
      if (p_ability -> 'allocation' ->> k) !~ '^[12]$' then raise exception 'An increase is +1 or +2' using errcode = '22023'; end if;
      alloc := alloc || jsonb_build_object(k, (p_ability -> 'allocation' ->> k)::int);
    end loop;
    if mode = 'plus2_plus1' then
      if not (jsonb_typeof(alloc) = 'object' and (select count(*) from jsonb_object_keys(alloc)) = 2
              and (select array_agg(x::int order by x::int) from jsonb_each_text(alloc) e(ak, x)) = array[1, 2]) then
        raise exception 'Choose +2 for one listed ability and +1 for a different one' using errcode = '22023';
      end if;
    elsif mode = 'plus1_x3' then
      if not ((select count(*) from jsonb_object_keys(alloc)) = 3 and (select bool_and(x::int = 1) from jsonb_each_text(alloc) e(ak, x))) then
        raise exception 'Choose +1 for each of the three listed abilities' using errcode = '22023';
      end if;
    else
      raise exception 'Unknown ability mode "%"', mode using errcode = '22023';
    end if;
  end if;

  chars := coalesce(p_options -> 'characteristics', '{}');
  if jsonb_typeof(chars) <> 'object' or length(chars::text) > 6000 then
    raise exception 'Characteristics must be short texts' using errcode = '22023';
  end if;

  select version_id into prev from public.character_backgrounds where character_id = p_character;
  insert into public.character_backgrounds as cb (character_id, version_id, ability_mode, ability_allocation, bonuses_included, characteristics, notes)
  values (p_character, v.id, mode, alloc, coalesce((p_options ->> 'bonuses_included')::boolean, false), chars, coalesce(p_options ->> 'notes', ''))
  on conflict (character_id) do update set version_id = excluded.version_id, ability_mode = excluded.ability_mode,
    ability_allocation = excluded.ability_allocation, bonuses_included = excluded.bonuses_included,
    characteristics = excluded.characteristics, notes = excluded.notes;
  delete from public.character_background_choices where character_id = p_character;
  delete from public.character_background_replacements where character_id = p_character;

  -- choices: every value must be an option of that choice; a choice may stay open (fewer picks), never exceed its count
  for k in select jsonb_object_keys(coalesce(p_choices, '{}')) loop
    select * into c from public.background_choices where version_id = v.id and key = k;
    if not found then raise exception '% has no choice "%"', v.name, k using errcode = '22023'; end if;
    select array_agg(x) into vals from jsonb_array_elements_text(p_choices -> k) x;
    vals := coalesce(vals, '{}');
    if cardinality(vals) > c.pick_count then
      raise exception '%: choose at most %', c.label, c.pick_count using errcode = '22023';
    end if;
    n := 0;
    foreach val in array vals loop
      n := n + 1;
      okind := case when val like '%:%' then split_part(val, ':', 1) end;
      oid := case when val like '%:%' then split_part(val, ':', 2) else val end;
      select o.option_kind into okind from public.background_choice_options o
      where o.choice_id = c.id and o.option_id = oid and (okind is null or o.option_kind = okind) limit 1;
      if not found then raise exception '%: "%" is not one of the options', c.label, oid using errcode = '22023'; end if;
      begin
        insert into public.character_background_choices (character_id, choice_id, pick, option_kind, option_id) values (p_character, c.id, n, okind, oid);
      exception when unique_violation then
        raise exception '%: "%" is chosen twice', c.label, oid using errcode = '22023';
      end;
    end loop;
  end loop;

  -- replacements of duplicated grants (same kind; the original must be a grant of this background)
  for r in select x from jsonb_array_elements(coalesce(p_replacements, '[]')) x loop
    if r ->> 'kind' not in ('skill', 'tool') then raise exception 'Only skill or tool proficiencies can be replaced' using errcode = '22023'; end if;
    if not exists (select 1 from public._character_background_grants(p_character) g where g.kind = r ->> 'kind' and g.target_id = r ->> 'original') then
      raise exception '"%" is not a % this background gives', r ->> 'original', r ->> 'kind' using errcode = '22023';
    end if;
    if (r ->> 'kind' = 'skill' and not exists (select 1 from public.skills where id = r ->> 'replacement'))
       or (r ->> 'kind' = 'tool' and not exists (select 1 from public.items where id = r ->> 'replacement' and kind_id = 'tool' and owner_id is null)) then
      raise exception '"%" is not a % proficiency', r ->> 'replacement', r ->> 'kind' using errcode = '22023';
    end if;
    if exists (select 1 from public._character_background_grants(p_character) g where g.kind = r ->> 'kind' and g.target_id = r ->> 'replacement') then
      raise exception 'The background already gives "%"', r ->> 'replacement' using errcode = '22023';
    end if;
    insert into public.character_background_replacements (character_id, kind, original_id, replacement_id)
    values (p_character, r ->> 'kind', r ->> 'original', r ->> 'replacement');
  end loop;

  return public.get_character_background(p_character);
end;
$function$;

-- clear_character_background(uuid)
CREATE OR REPLACE FUNCTION public.clear_character_background(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform public._gov_gate(p_character, 'build.background');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  delete from public.character_backgrounds where character_id = p_character;     -- choices and replacements go with it
  return public.get_character_background(p_character);                           -- equipment already added stays in the inventory
end;
$function$;

-- apply_background_equipment(uuid,text,jsonb)
CREATE OR REPLACE FUNCTION public.apply_background_equipment(p_character uuid, p_package text, p_picks jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cb public.character_backgrounds; pv jsonb; e jsonb; inv uuid; ids uuid[] := '{}'; noted jsonb := '[]'; item text; coins jsonb; b text; name text;
begin
  perform public._gov_gate(p_character, 'build.background');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;            -- one application at a time
  select * into cb from public.character_backgrounds where character_id = p_character;
  if not found then raise exception 'Choose a background first' using errcode = '22023'; end if;
  if exists (select 1 from public.character_background_equipment where character_id = p_character and version_id = cb.version_id) then
    raise exception 'The equipment of this background was already added' using errcode = '23505';
  end if;
  pv := public.preview_background_equipment(p_character, p_package);
  select id into inv from public.inventories where character_id = p_character and kind = 'character';
  name := (select b2.name from public.background_versions v2 join public.backgrounds b2 on b2.id = v2.background_id where v2.id = cb.version_id);
  for e in select x from jsonb_array_elements(pv -> 'entries') x loop
    item := case e ->> 'status' when 'resolved' then e ->> 'item_id'
                                when 'pick' then p_picks ->> (e ->> 'seq') end;
    if e ->> 'status' = 'needs_choice' then
      raise exception '%: make the background choice first', e ->> 'label' using errcode = '22023';
    end if;
    if e ->> 'status' = 'pick' then
      if item is null or not exists (select 1 from jsonb_array_elements(e -> 'pick_options') o where o ->> 'id' = item) then
        raise exception '%: pick one of the listed items', e ->> 'label' using errcode = '22023';
      end if;
    end if;
    if item is null then
      noted := noted || jsonb_build_array(jsonb_build_object('label', e ->> 'label', 'quantity', (e ->> 'quantity')::int, 'note', e ->> 'note'));
    else
      ids := ids || public.add_inventory_item(inv, item, (e ->> 'quantity')::int, null, format('Background equipment (%s)', name), '{}'::jsonb);
    end if;
  end loop;
  coins := pv -> 'coins';
  for b in select jsonb_object_keys(coins) loop
    if b not in ('cp', 'sp', 'ep', 'gp', 'pp') then raise exception 'Unknown coin "%"', b using errcode = '22023'; end if;
    execute format('update public.characters set %I = %I + $1 where id = $2', b, b) using (coins ->> b)::int, p_character;
  end loop;
  insert into public.character_background_equipment (character_id, version_id, package_key, inventory_item_ids, coins, noted, applied_by)
  values (p_character, cb.version_id, p_package, ids, coins, noted, auth.uid());
  return jsonb_build_object('added', cardinality(ids), 'coins', coins, 'noted', noted);
end;
$function$;

-- apply_class_starting_equipment(uuid,text,jsonb)
CREATE OR REPLACE FUNCTION public.apply_class_starting_equipment(p_character uuid, p_class_version text, p_selections jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare inv uuid; grp record; opt public.class_starting_equipment; key text; x jsonb; n int; pick jsonb; ids text[]; cands jsonb;
  added jsonb := '[]'; skipped jsonb := '[]'; cname text; iid text;
begin
  perform public._gov_gate(p_character, 'inventory.add_mundane');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if jsonb_typeof(p_selections) is distinct from 'object' then raise exception 'Selections must be an object' using errcode = '22023'; end if;
  perform 1 from public.characters where id = p_character for update;          -- one application at a time
  if not exists (select 1 from public.character_classes where character_id = p_character and class_version_id = p_class_version and is_primary) then
    raise exception 'Starting equipment comes with the first (primary) class only' using errcode = '22023';
  end if;
  if exists (select 1 from public.character_starting_equipment where character_id = p_character) then
    raise exception 'Starting equipment was already added to this character' using errcode = '23505';
  end if;
  select i.id into inv from public.inventories i where i.character_id = p_character and i.kind = 'character';
  if inv is null then raise exception 'This character has no inventory' using errcode = '22023'; end if;
  select name into cname from public.class_versions where id = p_class_version;

  for grp in select choice_group, count(*) as n_opt from public.class_starting_equipment where class_version_id = p_class_version
             group by 1 order by 1 loop
    key := p_selections -> 'options' ->> grp.choice_group::text;
    if key is null and grp.n_opt = 1 then
      select option_key into key from public.class_starting_equipment where class_version_id = p_class_version and choice_group = grp.choice_group;
    end if;
    select * into opt from public.class_starting_equipment
    where class_version_id = p_class_version and choice_group = grp.choice_group and option_key = key;
    if not found then raise exception 'Choose an option for starting equipment group %', grp.choice_group using errcode = '22023'; end if;
    for x, n in select t.x, t.n from jsonb_array_elements(opt.items) with ordinality t(x, n) loop
      if x ? 'unresolved' then
        skipped := skipped || jsonb_build_object('group', grp.choice_group, 'option', key, 'text', x ->> 'unresolved');
        continue;
      end if;
      if x ? 'item_id' then
        perform public.add_inventory_item(inv, x ->> 'item_id', coalesce((x ->> 'quantity')::int, 1), null,
                                          format('Starting equipment (%s)', cname), '{}'::jsonb);
        added := added || jsonb_build_object('item_id', x ->> 'item_id', 'quantity', coalesce((x ->> 'quantity')::int, 1));
        continue;
      end if;
      pick := p_selections -> 'picks' -> format('%s:%s:%s', grp.choice_group, key, n - 1);
      ids := case jsonb_typeof(pick) when 'string' then array_fill(pick #>> '{}', array[coalesce((x ->> 'quantity')::int, 1)])
                                     when 'array' then array(select jsonb_array_elements_text(pick)) end;
      if ids is null or cardinality(ids) <> coalesce((x ->> 'quantity')::int, 1) then
        raise exception 'Choose % for "%"', coalesce((x ->> 'quantity')::int, 1), coalesce(x ->> 'label', opt.label) using errcode = '22023';
      end if;
      cands := public._starting_equipment_candidates(x);
      foreach iid in array ids loop
        if not exists (select 1 from jsonb_array_elements(cands) c where c ->> 'id' = iid) then
          raise exception '"%" is not a choice for "%"', iid, coalesce(x ->> 'label', opt.label) using errcode = '22023';
        end if;
        perform public.add_inventory_item(inv, iid, 1, null, format('Starting equipment (%s)', cname), '{}'::jsonb);
        added := added || jsonb_build_object('item_id', iid, 'quantity', 1);
      end loop;
    end loop;
  end loop;

  insert into public.character_starting_equipment (character_id, class_version_id, selections, added, skipped, applied_by)
  values (p_character, p_class_version, p_selections, added, skipped, auth.uid());
  return jsonb_build_object('class_version_id', p_class_version, 'added', added, 'skipped', skipped);
end;
$function$;

-- set_character_proficiency(uuid,text,text,boolean,text)
CREATE OR REPLACE FUNCTION public.set_character_proficiency(p_character uuid, p_group text DEFAULT NULL::text, p_item text DEFAULT NULL::text, p_enabled boolean DEFAULT true, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_type text; v_id uuid; changed boolean;
begin
  perform public._gov_gate(p_character, 'build.manual_proficiency');   -- campaign governance (20261019000100)
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
$function$;

-- add_character_companion(uuid,text,text,text,integer)
CREATE OR REPLACE FUNCTION public.add_character_companion(p_character uuid, p_creature text DEFAULT NULL::text, p_name text DEFAULT NULL::text, p_source text DEFAULT NULL::text, p_hp_max integer DEFAULT NULL::integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c public.creatures; hp int; nid uuid;
begin
  perform public._gov_gate(p_character, 'build.companion');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if p_creature is not null then
    select * into c from public.creatures where id = p_creature;
    if not found then raise exception 'Unknown creature "%"', p_creature using errcode = '22023'; end if;
  elsif coalesce(btrim(p_name), '') = '' or p_hp_max is null then
    raise exception 'A custom companion needs a name and hit points' using errcode = '22023';
  end if;
  hp := coalesce(p_hp_max, c.hit_points);
  if hp not between 1 and 2000 then raise exception 'Hit points must be 1-2000' using errcode = '22023'; end if;
  if (select count(*) from public.character_companions where character_id = p_character) >= 50 then
    raise exception 'A character can have at most 50 companions' using errcode = '22023';
  end if;
  insert into public.character_companions (character_id, creature_id, name, source, hp_max, hp_current, created_by)
  values (p_character, c.id, coalesce(nullif(btrim(p_name), ''), c.name), nullif(btrim(p_source), ''), hp, hp, auth.uid())
  returning id into nid;
  return nid;
end;
$function$;

-- remove_character_companion(uuid)
CREATE OR REPLACE FUNCTION public.remove_character_companion(p_companion uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cid uuid;
begin
  perform public._gov_gate_companion(p_companion, 'build.companion');   -- campaign governance (20261019000100)
  select character_id into cid from public.character_companions where id = p_companion for update;
  if cid is null or auth.uid() is null or not public.can_access_character(cid) then
    raise exception 'Companion not found' using errcode = '42501';
  end if;
  delete from public.character_companions where id = p_companion;
end;
$function$;

-- update_character_companion(uuid,jsonb)
CREATE OR REPLACE FUNCTION public.update_character_companion(p_companion uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare x public.character_companions;
begin
  perform public._gov_gate_companion(p_companion, 'runtime.companion');   -- campaign governance (20261019000100)
  select * into x from public.character_companions where id = p_companion for update;
  if not found or auth.uid() is null or not public.can_access_character(x.character_id) then
    raise exception 'Companion not found' using errcode = '42501';
  end if;
  if jsonb_typeof(p_patch) is distinct from 'object' then raise exception 'Changes must be an object' using errcode = '22023'; end if;
  if p_patch ? 'hp_max' and coalesce((p_patch ->> 'hp_max')::int, 0) not between 1 and 2000 then
    raise exception 'Hit points must be 1-2000' using errcode = '22023'; end if;
  if p_patch ? 'name' and coalesce(btrim(p_patch ->> 'name'), '') = '' then raise exception 'A companion needs a name' using errcode = '22023'; end if;
  update public.character_companions set
    name = coalesce(nullif(btrim(p_patch ->> 'name'), ''), name),
    notes = case when p_patch ? 'notes' then nullif(btrim(p_patch ->> 'notes'), '') else notes end,
    hp_max = coalesce((p_patch ->> 'hp_max')::int, hp_max),
    hp_current = least(greatest(coalesce((p_patch ->> 'hp_current')::int, hp_current), 0), coalesce((p_patch ->> 'hp_max')::int, hp_max)),
    active = coalesce((p_patch ->> 'active')::boolean, active)
  where id = p_companion returning * into x;
  return to_jsonb(x);
end;
$function$;

-- set_character_spell(uuid,uuid,text,boolean,boolean,boolean,text,boolean,text)
CREATE OR REPLACE FUNCTION public.set_character_spell(p_character uuid, p_source uuid, p_spell_version text, p_known boolean DEFAULT true, p_prepared boolean DEFAULT false, p_always_prepared boolean DEFAULT false, p_casting_ability text DEFAULT NULL::text, p_ritual_allowed boolean DEFAULT NULL::boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s public.character_spellcasting_sources; v public.spell_versions; r public.character_spells;
begin
  perform public._gov_gate_spell(p_character, p_source, p_spell_version, p_known, p_prepared, p_always_prepared, p_casting_ability, p_ritual_allowed);   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  select * into s from public.character_spellcasting_sources where id = p_source and character_id = p_character;
  if not found then raise exception 'Spellcasting source not found' using errcode = '42501'; end if;
  select * into v from public.spell_versions where id = p_spell_version;
  if not found or not public.can_view_spell(v.spell_id) then
    raise exception 'Unknown spell "%"', p_spell_version using errcode = '22023';
  end if;
  if not (coalesce(p_known, false) or coalesce(p_prepared, false) or coalesce(p_always_prepared, false)) then
    raise exception 'A spell must be known, prepared or always prepared' using errcode = '22023';
  end if;
  if coalesce(p_always_prepared, false) and not s.always_prepared_allowed then
    raise exception '% cannot mark spells as always prepared', s.label using errcode = '22023';
  end if;
  if s.enforce_spell_list and s.spell_list_id is not null and not exists (
       select 1 from public.class_spell_list_entries e where e.list_id = s.spell_list_id and e.spell_version_id = v.id)
     and not public._expanded_spell(s.character_class_id, v.id) then
    raise exception '% is not on the spell list of %', v.name, s.label using errcode = '22023';
  end if;
  if p_casting_ability is not null and not p_casting_ability = any (s.allowed_abilities) then
    raise exception 'This source does not let a spell use %', upper(p_casting_ability) using errcode = '22023';
  end if;
  if length(p_notes) > 500 then raise exception 'Notes are too long' using errcode = '22023'; end if;
  insert into public.character_spells (character_id, source_id, spell_version_id, known, prepared, always_prepared,
                                       counts_against_known_limit, counts_against_prepared_limit, uses_spell_slot, ritual_allowed,
                                       casting_ability, notes)
  values (p_character, s.id, v.id, coalesce(p_known, false), coalesce(p_prepared, false), coalesce(p_always_prepared, false),
          not coalesce(p_always_prepared, false), not coalesce(p_always_prepared, false), s.uses_spell_slots and v.level > 0,
          coalesce(p_ritual_allowed, false), p_casting_ability, nullif(btrim(p_notes), ''))
  on conflict (source_id, spell_version_id) do update set
    known = excluded.known, prepared = excluded.prepared, always_prepared = excluded.always_prepared,
    counts_against_known_limit = excluded.counts_against_known_limit, counts_against_prepared_limit = excluded.counts_against_prepared_limit,
    ritual_allowed = excluded.ritual_allowed, casting_ability = excluded.casting_ability, notes = excluded.notes
  returning * into r;
  return to_jsonb(r);
end;
$function$;

-- set_character_spell_prepared(uuid,boolean)
CREATE OR REPLACE FUNCTION public.set_character_spell_prepared(p_character_spell uuid, p_prepared boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.character_spells;
begin
  perform public._gov_gate_spell_row(p_character_spell, 'spell.prepare');   -- campaign governance (20261019000100)
  select * into r from public.character_spells where id = p_character_spell;
  if auth.uid() is null or r.id is null or not public.can_access_character(r.character_id) then
    raise exception 'Spell not found' using errcode = '42501';
  end if;
  if not coalesce(p_prepared, false) and not r.known and not r.always_prepared then
    raise exception 'This spell is only prepared; remove it instead' using errcode = '22023';
  end if;
  update public.character_spells set prepared = coalesce(p_prepared, false) where id = p_character_spell returning * into r;
  return to_jsonb(r);
end;
$function$;

-- remove_character_spell(uuid)
CREATE OR REPLACE FUNCTION public.remove_character_spell(p_character_spell uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cid uuid;
begin
  perform public._gov_gate_spell_row(p_character_spell, 'spell.remove');   -- campaign governance (20261019000100)
  select character_id into cid from public.character_spells where id = p_character_spell;
  if auth.uid() is null or cid is null or not public.can_access_character(cid) then
    raise exception 'Spell not found' using errcode = '42501';
  end if;
  delete from public.character_spells where id = p_character_spell;
  return jsonb_build_object('deleted', true, 'id', p_character_spell);
end;
$function$;

-- set_character_spell_acquisition(uuid,text,integer,text)
CREATE OR REPLACE FUNCTION public.set_character_spell_acquisition(p_character_spell uuid, p_acquisition text, p_level integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare g public.character_spells;
begin
  perform public._gov_gate_spell_row(p_character_spell, 'spell.notes');   -- campaign governance (20261019000100)
  select * into g from public.character_spells where id = p_character_spell;
  if not found or auth.uid() is null or not public.can_access_character(g.character_id) then
    raise exception 'Spell not found' using errcode = '42501';
  end if;
  if p_acquisition is not null and p_acquisition not in ('starting', 'level_up', 'copied', 'scroll', 'feature', 'other') then
    raise exception 'Unknown acquisition "%"', p_acquisition using errcode = '22023';
  end if;
  update public.character_spells set acquisition = p_acquisition, acquired_at_level = p_level,
         acquisition_notes = nullif(btrim(p_notes), ''), updated_at = now()
  where id = p_character_spell;
  return public.get_character_spellbook(g.character_id);
end;
$function$;

-- save_character_spellcasting_source(uuid,jsonb)
CREATE OR REPLACE FUNCTION public.save_character_spellcasting_source(p_character uuid, p_source jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_id uuid; r public.character_spellcasting_sources; k text;
  allowed constant text[] := array['id', 'source_type', 'label', 'class_version_id', 'spell_list_id', 'casting_ability', 'allowed_abilities',
    'fixed_dc', 'fixed_attack_bonus', 'dc_bonus', 'attack_bonus', 'preparation_mode', 'ritual_mode', 'uses_spell_slots', 'class_level',
    'progression_id', 'enforce_spell_list', 'always_prepared_allowed', 'notes'];
begin
  perform public._gov_gate(p_character, 'spell.change_source');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if jsonb_typeof(p_source) <> 'object' then raise exception 'The source must be an object' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_source) loop
    if not k = any (allowed) then raise exception 'Field "%" cannot be set on a spellcasting source', k using errcode = '22023'; end if;
  end loop;
  if coalesce(p_source ->> 'source_type', '') not in ('class', 'subclass', 'feat', 'item', 'manual', 'other') then
    raise exception 'Unknown source type "%"', p_source ->> 'source_type' using errcode = '22023';
  end if;
  if coalesce(btrim(p_source ->> 'label'), '') = '' then raise exception 'Give the source a name' using errcode = '22023'; end if;
  if p_source ? 'class_version_id' and p_source ->> 'class_version_id' is not null
     and not exists (select 1 from public.class_versions where id = p_source ->> 'class_version_id') then
    raise exception 'Unknown class version "%"', p_source ->> 'class_version_id' using errcode = '22023';
  end if;
  if p_source ->> 'spell_list_id' is not null and not exists (select 1 from public.class_spell_lists where id = p_source ->> 'spell_list_id') then
    raise exception 'Unknown spell list "%"', p_source ->> 'spell_list_id' using errcode = '22023';
  end if;
  if p_source ->> 'progression_id' is not null and not exists (select 1 from public.spell_slot_progressions where id = p_source ->> 'progression_id') then
    raise exception 'Unknown slot progression "%"', p_source ->> 'progression_id' using errcode = '22023';
  end if;
  v_id := nullif(p_source ->> 'id', '')::uuid;
  if v_id is not null and not exists (select 1 from public.character_spellcasting_sources where id = v_id and character_id = p_character) then
    raise exception 'Spellcasting source not found' using errcode = '42501';
  end if;
  begin
    if v_id is null then
      insert into public.character_spellcasting_sources (character_id, source_type, label, created_by) values
        (p_character, p_source ->> 'source_type', btrim(p_source ->> 'label'), auth.uid()) returning id into v_id;
    end if;
    update public.character_spellcasting_sources set
      source_type = p_source ->> 'source_type', label = btrim(p_source ->> 'label'),
      class_version_id = p_source ->> 'class_version_id', spell_list_id = p_source ->> 'spell_list_id',
      casting_ability = p_source ->> 'casting_ability',
      allowed_abilities = coalesce((select array_agg(x) from jsonb_array_elements_text(p_source -> 'allowed_abilities') x), '{}'),
      fixed_dc = (p_source ->> 'fixed_dc')::int, fixed_attack_bonus = (p_source ->> 'fixed_attack_bonus')::int,
      dc_bonus = coalesce((p_source ->> 'dc_bonus')::int, 0), attack_bonus = coalesce((p_source ->> 'attack_bonus')::int, 0),
      preparation_mode = coalesce(p_source ->> 'preparation_mode', (select preparation_mode from public.class_versions
                                                                     where id = p_source ->> 'class_version_id'), 'known'),
      ritual_mode = coalesce(p_source ->> 'ritual_mode', (select ritual_mode from public.class_versions
                                                         where id = p_source ->> 'class_version_id'), 'none'),
      uses_spell_slots = coalesce((p_source ->> 'uses_spell_slots')::boolean, true), class_level = (p_source ->> 'class_level')::int,
      progression_id = p_source ->> 'progression_id', enforce_spell_list = coalesce((p_source ->> 'enforce_spell_list')::boolean, false),
      always_prepared_allowed = coalesce((p_source ->> 'always_prepared_allowed')::boolean, false), notes = nullif(btrim(p_source ->> 'notes'), '')
    where id = v_id
    returning * into r;
  exception
    when check_violation or invalid_text_representation or numeric_value_out_of_range then
      raise exception 'Invalid spellcasting source: %', sqlerrm using errcode = '22023';
  end;
  return to_jsonb(r) - 'created_by';
end;
$function$;

-- delete_character_spellcasting_source(uuid)
CREATE OR REPLACE FUNCTION public.delete_character_spellcasting_source(p_source uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cid uuid;
begin
  perform public._gov_gate_source_row(p_source, 'spell.change_source');   -- campaign governance (20261019000100)
  select character_id into cid from public.character_spellcasting_sources where id = p_source;
  if auth.uid() is null or cid is null or not public.can_access_character(cid) then
    raise exception 'Spellcasting source not found' using errcode = '42501';
  end if;
  delete from public.character_spellcasting_sources where id = p_source;   -- its spell grants go with it
  return jsonb_build_object('deleted', true, 'id', p_source);
end;
$function$;

-- add_inventory_item(uuid,text,integer,text,text,jsonb)
CREATE OR REPLACE FUNCTION public.add_inventory_item(p_inventory uuid, p_item text, p_quantity integer DEFAULT 1, p_custom_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_state jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare it public.items; remaining int := p_quantity; chunk int; rid uuid; last_id uuid;
begin
  perform public._gov_gate_add_item(p_inventory, p_item);   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  if p_quantity is null or p_quantity < 1 then raise exception 'Quantity must be at least 1'; end if;
  if not public.can_deposit_inventory(p_inventory) then raise exception 'Not allowed to add items to this inventory' using errcode = '42501'; end if;
  if not public.can_view_item(p_item) then raise exception 'Unknown item' using errcode = 'P0002'; end if;
  select * into it from public.items where id = p_item;
  if it.archived_at is not null then raise exception 'This homebrew item is archived and cannot be added' using errcode = '22023'; end if;

  while remaining > 0 loop
    chunk := case when it.stackable then least(remaining, coalesce(it.stack_max, remaining)) else 1 end;
    insert into public.inventory_items (inventory_id, item_id, quantity, custom_name, notes, state)
    values (p_inventory, p_item, chunk, nullif(btrim(p_custom_name), ''), nullif(btrim(p_notes), ''), coalesce(p_state, '{}'::jsonb))
    returning id into rid;
    last_id := public._try_auto_merge(rid);
    remaining := remaining - chunk;
  end loop;
  perform public.log_inventory_event(p_inventory, last_id, 'add', p_quantity, p_item, '{"via":"rpc"}');
  perform public._rpc_end(); return last_id;
end;
$function$;

-- remove_inventory_item(uuid,integer)
CREATE OR REPLACE FUNCTION public.remove_inventory_item(p_item uuid, p_quantity integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; q int; gone boolean;
begin
  perform public._gov_gate_item(p_item, 'inventory.delete');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  q := coalesce(p_quantity, r.quantity);
  gone := p_quantity is null or q = r.quantity;
  if not gone and (q < 1 or q > r.quantity) then raise exception 'Invalid quantity % (have %)', q, r.quantity; end if;
  if gone then
    delete from public.inventory_items where id = r.id;
  else
    update public.inventory_items set quantity = quantity - q where id = r.id;
  end if;
  perform public.log_inventory_event(r.inventory_id, case when gone then null else r.id end, 'remove', -q, r.item_id,
    jsonb_build_object('previous_quantity', r.quantity, 'deleted', gone, 'name', coalesce(r.custom_name, r.name), 'legacy', r.item_id is null,
                       'legacy_description', case when r.item_id is null then r.description end));
  perform public._rpc_end(); return jsonb_build_object('removed', q, 'remaining', case when gone then 0 else r.quantity - q end, 'deleted', gone);
end;
$function$;

-- set_inventory_item_quantity(uuid,integer)
CREATE OR REPLACE FUNCTION public.set_inventory_item_quantity(p_item uuid, p_quantity integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; stk boolean; res jsonb;
begin
  perform public._gov_gate_item_quantity(p_item, p_quantity);   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  if p_quantity is null or p_quantity < 1 then
    raise exception 'Quantity must be at least 1 (remove the item instead)' using errcode = '22023';
  end if;
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id is not null and p_quantity > 1 then
    select stackable into stk from public.items where id = r.item_id;
    if not stk then raise exception 'This item does not stack; add separate pieces instead' using errcode = '22023'; end if;
  end if;
  if p_quantity <> r.quantity then
    update public.inventory_items set quantity = p_quantity where id = r.id;      -- the row trigger still enforces equip/attune rules
    perform public.log_inventory_event(r.inventory_id, r.id, case when p_quantity > r.quantity then 'add' else 'remove' end,
                                       p_quantity - r.quantity, r.item_id, jsonb_build_object('previous_quantity', r.quantity));
  end if;
  res := jsonb_build_object('inventory_item_id', r.id, 'previous_quantity', r.quantity, 'quantity', p_quantity);
  perform public._rpc_end(); return res;
end;
$function$;

-- transfer_inventory_item(uuid,uuid,integer)
CREATE OR REPLACE FUNCTION public.transfer_inventory_item(p_item uuid, p_to_inventory uuid, p_quantity integer DEFAULT NULL::integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; q int; moving uuid; from_inv uuid; res uuid;
begin
  perform public._gov_gate_item(p_item, 'inventory.transfer'); perform public._gov_gate_inventory(p_to_inventory, 'inventory.transfer');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  from_inv := r.inventory_id;
  if from_inv = p_to_inventory then raise exception 'Source and target inventory are the same'; end if;
  if not public.can_write_inventory(from_inv) then raise exception 'Not allowed to take items from this inventory' using errcode = '42501'; end if;
  if not public.can_deposit_inventory(p_to_inventory) then raise exception 'Not allowed to add items to the target inventory' using errcode = '42501'; end if;
  if exists (select 1 from public.character_equipment where inventory_item_id = p_item) then
    raise exception 'Unequip the item before transferring it';
  end if;
  if exists (select 1 from public.inventory_items where container_item_id = p_item) then
    raise exception 'The container is not empty';
  end if;
  q := coalesce(p_quantity, r.quantity);
  if q < 1 or q > r.quantity then raise exception 'Invalid quantity % (have %)', q, r.quantity; end if;
  if q < r.quantity then moving := public._split_off(p_item, q); else moving := p_item; end if;

  update public.inventory_items
  set inventory_id = p_to_inventory, container_item_id = null, is_attuned = false, sort_order = 0
  where id = moving;
  perform public.log_inventory_event(from_inv, null, 'transfer', -q, r.item_id, jsonb_build_object('to', p_to_inventory));
  perform public.log_inventory_event(p_to_inventory, moving, 'transfer', q, r.item_id, jsonb_build_object('from', from_inv));
  res := public._try_auto_merge(moving);
  perform public._rpc_end(); return res;
end;
$function$;

-- split_inventory_stack(uuid,integer)
CREATE OR REPLACE FUNCTION public.split_inventory_stack(p_item uuid, p_quantity integer DEFAULT 1)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; nid uuid;
begin
  perform public._gov_gate_item(p_item, 'inventory.organize');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  nid := public._split_off(p_item, p_quantity);
  perform public.log_inventory_event(r.inventory_id, nid, 'split', 0, r.item_id,
                                     jsonb_build_object('from', r.id, 'quantity', p_quantity));
  perform public._rpc_end(); return nid;
end;
$function$;

-- merge_inventory_stacks(uuid,uuid)
CREATE OR REPLACE FUNCTION public.merge_inventory_stacks(p_target uuid, p_source uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare a public.inventory_items; b public.inventory_items; smax int;
begin
  perform public._gov_gate_item(p_target, 'inventory.organize');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  if p_target = p_source then raise exception 'Cannot merge a stack with itself'; end if;
  -- lock in id order to avoid deadlocks
  if p_target < p_source then a := public._lock_item(p_target); b := public._lock_item(p_source);
  else b := public._lock_item(p_source); a := public._lock_item(p_target); end if;
  if not public.can_write_inventory(a.inventory_id) or not public.can_write_inventory(b.inventory_id) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if a.inventory_id <> b.inventory_id then raise exception 'Stacks are in different inventories'; end if;
  if a.stack_key is null or a.stack_key is distinct from b.stack_key then
    raise exception 'These items are not identical and cannot be merged';
  end if;
  select stack_max into smax from public.items where id = a.item_id;
  if smax is not null and a.quantity + b.quantity > smax then raise exception 'Stack limit (%) exceeded', smax; end if;
  update public.inventory_items set quantity = a.quantity + b.quantity where id = a.id;
  delete from public.inventory_items where id = b.id;
  perform public.log_inventory_event(a.inventory_id, a.id, 'merge', b.quantity, a.item_id, jsonb_build_object('merged_from', b.id));
  perform public._rpc_end(); return a.id;
end;
$function$;

-- move_inventory_item(uuid,uuid)
CREATE OR REPLACE FUNCTION public.move_inventory_item(p_item uuid, p_container uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; res uuid;
begin
  perform public._gov_gate_item(p_item, 'inventory.organize');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if p_container is not null and exists (select 1 from public.character_equipment where inventory_item_id = p_item) then
    raise exception 'Unequip the item before putting it into a container' using errcode = '22023';
  end if;
  if p_container is not distinct from r.container_item_id then
    perform public._rpc_end(); return p_item;
  end if;
  update public.inventory_items set container_item_id = p_container where id = p_item;
  perform public.log_inventory_event(r.inventory_id, r.id, 'move', null, r.item_id,
                                     jsonb_build_object('from_container', r.container_item_id, 'to_container', p_container));
  res := public._try_auto_merge(p_item);
  perform public._rpc_end(); return res;
end;
$function$;

-- equip_item(uuid,text,boolean)
CREATE OR REPLACE FUNCTION public.equip_item(p_item uuid, p_slot text, p_replace boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; inv public.inventories; target uuid; occ uuid; split_from uuid;
begin
  perform public._gov_gate_item(p_item, 'inventory.equip');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  select * into inv from public.inventories where id = r.inventory_id;
  if inv.kind <> 'character' then raise exception 'Only character inventories have equipment'; end if;
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id is null then raise exception 'Only catalog items can be equipped'; end if;
  perform pg_advisory_xact_lock(hashtext(inv.character_id::text));

  select inventory_item_id into occ from public.character_equipment where character_id = inv.character_id and slot_id = p_slot;
  if occ is not null and occ <> p_item then
    if not p_replace then raise exception 'Slot % is already occupied', p_slot; end if;
    delete from public.character_equipment where character_id = inv.character_id and slot_id = p_slot;
    perform public._try_auto_merge(occ);
  end if;
  -- moving an already equipped single piece to another slot
  delete from public.character_equipment where inventory_item_id = p_item;

  if r.quantity > 1 then
    target := public._split_off(p_item, 1);
    split_from := p_item;
    perform public.log_inventory_event(r.inventory_id, target, 'split', 0, r.item_id,
                                       jsonb_build_object('from', p_item, 'quantity', 1, 'reason', 'equip'));
  else
    target := p_item;
  end if;
  insert into public.character_equipment (character_id, slot_id, inventory_item_id) values (inv.character_id, p_slot, target);
  perform public._rpc_end(); return jsonb_build_object('inventory_item_id', target, 'split_from', split_from, 'slot', p_slot);
end;
$function$;

-- unequip_item(uuid)
CREATE OR REPLACE FUNCTION public.unequip_item(p_item uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; res uuid;
begin
  perform public._gov_gate_item(p_item, 'inventory.equip');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if not exists (select 1 from public.character_equipment where inventory_item_id = p_item) then
    raise exception 'The item is not equipped';
  end if;
  delete from public.character_equipment where inventory_item_id = p_item;
  res := public._try_auto_merge(p_item);        -- the single piece rejoins an identical stack if there is one
  perform public._rpc_end(); return res;
end;
$function$;

-- attune_item(uuid)
CREATE OR REPLACE FUNCTION public.attune_item(p_item uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; target uuid;
begin
  perform public._gov_gate_item(p_item, 'inventory.attune');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id is null then raise exception 'Only catalog items can be attuned'; end if;
  if r.is_attuned then perform public._rpc_end(); return p_item; end if;
  if r.quantity > 1 then
    target := public._split_off(p_item, 1);
    perform public.log_inventory_event(r.inventory_id, target, 'split', 0, r.item_id,
                                       jsonb_build_object('from', p_item, 'quantity', 1, 'reason', 'attune'));
  else
    target := p_item;
  end if;
  update public.inventory_items set is_attuned = true where id = target;   -- trigger enforces the limit and logs 'attune'
  perform public._rpc_end(); return target;
end;
$function$;

-- unattune_item(uuid)
CREATE OR REPLACE FUNCTION public.unattune_item(p_item uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; res uuid;
begin
  perform public._gov_gate_item(p_item, 'inventory.attune');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if not r.is_attuned then perform public._rpc_end(); return p_item; end if;
  update public.inventory_items set is_attuned = false where id = p_item;   -- trigger logs 'unattune'
  res := public._try_auto_merge(p_item);
  perform public._rpc_end(); return res;
end;
$function$;

-- update_inventory_item_details(uuid,jsonb)
CREATE OR REPLACE FUNCTION public.update_inventory_item_details(p_item uuid, p_details jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  r public.inventory_items; k text; res jsonb;
  allowed constant text[] := array['custom_name','notes','is_quest_item','durability','charges_current','charges_max',
                                   'charges_recharge','state','consumable_override'];
begin
  perform public._gov_gate_item(p_item, 'inventory.instance_notes');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  if p_details is null or jsonb_typeof(p_details) <> 'object' then raise exception 'Nothing to change' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_details) loop
    if not k = any (allowed) then raise exception 'Field "%" cannot be changed on an inventory item', k using errcode = '22023'; end if;
  end loop;
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if p_details ? 'state' and (jsonb_typeof(p_details -> 'state') <> 'object' or length((p_details -> 'state')::text) > 4000) then
    raise exception 'State must be a small JSON object' using errcode = '22023';
  end if;
  update public.inventory_items set
    custom_name        = case when p_details ? 'custom_name' then public._j_text(p_details, 'custom_name', 120, 'Custom name') else custom_name end,
    notes              = case when p_details ? 'notes' then public._j_text(p_details, 'notes', 4000, 'Notes') else notes end,
    is_quest_item      = case when p_details ? 'is_quest_item' then public._j_bool(p_details, 'is_quest_item', false) else is_quest_item end,
    durability         = case when p_details ? 'durability' then public._j_int(p_details, 'durability', 0, 1000000, 'Durability') else durability end,
    charges_current    = case when p_details ? 'charges_current' then public._j_int(p_details, 'charges_current', 0, 1000, 'Charges') else charges_current end,
    charges_max        = case when p_details ? 'charges_max' then public._j_int(p_details, 'charges_max', 0, 1000, 'Maximum charges') else charges_max end,
    charges_recharge   = case when p_details ? 'charges_recharge' then public._j_text(p_details, 'charges_recharge', 100, 'Recharge') else charges_recharge end,
    state              = case when p_details ? 'state' then p_details -> 'state' else state end,
    consumable_override = case when p_details ? 'consumable_override' then
                            case when jsonb_typeof(p_details -> 'consumable_override') = 'null' then null else public._j_bool(p_details, 'consumable_override', null) end
                          else consumable_override end
  where id = r.id;
  select to_jsonb(d) into res from public.v_inventory_detail d where d.id = r.id;
  perform public._rpc_end(); return res;
end;
$function$;

-- use_inventory_item(uuid,integer)
CREATE OR REPLACE FUNCTION public.use_inventory_item(p_item uuid, p_quantity integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; it public.items; consumable boolean; remaining int; gone boolean := false; fx jsonb; res jsonb;
begin
  perform public._gov_gate_item(p_item, 'runtime.resources');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  if p_quantity is null or p_quantity < 1 then raise exception 'Quantity must be at least 1'; end if;
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id is null then raise exception 'Only catalog items can be used'; end if;
  if r.quantity < 1 then raise exception 'Nothing left to use' using errcode = '22003'; end if;
  select * into it from public.items where id = r.item_id;
  consumable := coalesce(r.consumable_override, it.is_consumable);
  select coalesce(jsonb_agg(jsonb_build_object(
           'effect_type', e.effect_type, 'dice_expression', e.dice_expression, 'flat_value', e.flat_value,
           'damage_type_id', e.damage_type_id, 'duration', e.duration, 'target_type', e.target_type, 'effect_data', e.effect_data)
           order by e.seq), '[]'::jsonb) into fx
  from public.consumable_effects e where e.item_id = r.item_id;

  if not consumable then
    perform public.log_inventory_event(r.inventory_id, r.id, 'use', 0, r.item_id,
                                       jsonb_build_object('consumed', false, 'previous_quantity', r.quantity));
    res := jsonb_build_object('item_id', r.item_id, 'kind_id', it.kind_id, 'name', coalesce(r.custom_name, r.name), 'consumed', false,
                              'quantity_used', 0, 'previous_quantity', r.quantity, 'remaining', r.quantity, 'deleted', false,
                              'state', r.state, 'effects', fx);
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
  res := jsonb_build_object('item_id', r.item_id, 'kind_id', it.kind_id, 'name', coalesce(r.custom_name, r.name), 'consumed', true,
                            'quantity_used', p_quantity, 'previous_quantity', r.quantity, 'remaining', remaining, 'deleted', gone,
                            'state', r.state, 'effects', fx);
  perform public._rpc_end(); return res;
end;
$function$;

-- link_inventory_item(uuid,text)
CREATE OR REPLACE FUNCTION public.link_inventory_item(p_item uuid, p_catalog_item text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; it public.items; res jsonb;
begin
  perform public._gov_gate_item(p_item, 'inventory.add_mundane');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  r := public._legacy_row_for_link(p_item);
  select * into it from public.items where id = p_catalog_item;
  if it.id is null or not public.can_view_owned(it.owner_id, it.campaign_id) then raise exception 'Unknown catalog item' using errcode = 'P0002'; end if;
  if it.archived_at is not null then raise exception 'This homebrew item is archived' using errcode = '22023'; end if;
  res := public._apply_link(r, it, 'linked_by_user');
  perform public._rpc_end(); return res;
end;
$function$;

-- resolve_equipment_review(uuid)
CREATE OR REPLACE FUNCTION public.resolve_equipment_review(p_item uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; n int;
begin
  perform public._gov_gate_item(p_item, 'inventory.equip');   -- campaign governance (20261019000100)
  select * into r from public.inventory_items where id = p_item;
  if r.id is null or not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  update public.legacy_inventory_review set status = 'resolved', resolved_at = now(), detail = detail || '{"resolution": "not equipped"}'
  where inventory_item_id = p_item and category like 'equipped%' and status in ('pending', 'manual_review');
  get diagnostics n = row_count;
  return n;
end;
$function$;

-- import_inventory_items(uuid,jsonb)
CREATE OR REPLACE FUNCTION public.import_inventory_items(p_character uuid, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  inv uuid; ch public.characters; e jsonb; v_name text; v_qty int; v_desc text; v_weight numeric; hit text; n int; hb text;
  matched int := 0; created int := 0; skipped jsonb := '[]'::jsonb; cat_name text;
begin
  perform public._gov_gate(p_character, 'inventory.add_magic');   -- campaign governance (20261019000100)
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  select * into ch from public.characters where id = p_character;
  select id into inv from public.inventories where character_id = p_character;
  if inv is null or not public.can_write_inventory(inv) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_items, '[]'::jsonb)) > 500 then
    raise exception 'Expected a list of at most 500 items' using errcode = '22023';
  end if;
  for e in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_name := left(nullif(btrim(coalesce(e ->> 'name', '')), ''), 120);
    if v_name is null then skipped := skipped || to_jsonb('(unnamed)'::text); continue; end if;
    v_qty := greatest(1, coalesce(public._j_int(e, 'quantity', 0, 100000, 'Quantity of ' || v_name), 1));
    v_desc := left(nullif(btrim(coalesce(e ->> 'description', '')), ''), 4000);
    v_weight := coalesce(public._j_num(e, 'weight', 0, 100000, 'Weight of ' || v_name), 0);
    select count(*), min(id), min(name) into n, hit, cat_name from public.items
    where archived_at is null and public.can_view_owned(owner_id, campaign_id) and public._norm_name(name) = public._norm_name(v_name);
    if n = 1 then
      perform public.add_inventory_item(inv, hit, v_qty, case when lower(v_name) <> lower(cat_name) then v_name end, v_desc);
      matched := matched + 1;
    elsif ch.campaign_id is not null or ch.owner_id = auth.uid() then
      hb := 'hb-' || gen_random_uuid()::text;
      perform public._write_homebrew(hb, jsonb_build_object('name', v_name, 'kind_id', 'gear', 'category_id', 'general',
        'description', v_desc, 'weight_lb', nullif(v_weight, 0), 'campaign_id', ch.campaign_id), '{}'::jsonb, true);
      insert into public.homebrew_item_events (item_id, actor_id, action, changes) values (hb, auth.uid(), 'import', e);
      perform public.add_inventory_item(inv, hb, v_qty);
      created := created + 1;
    else
      skipped := skipped || to_jsonb(v_name);
    end if;
  end loop;
  perform public._rpc_end();
  return jsonb_build_object('matched', matched, 'homebrew_created', created, 'skipped', skipped);
end;
$function$;

-- convert_legacy_item_to_homebrew(uuid,uuid,jsonb,jsonb)
CREATE OR REPLACE FUNCTION public.convert_legacy_item_to_homebrew(p_item uuid, p_request_id uuid, p_definition jsonb, p_stats jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; it public.items; v_id text; res jsonb;
begin
  perform public._gov_content_gate(nullif(p_definition ->> 'campaign_id', '')::uuid, 'content.create_item');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  if p_request_id is null then raise exception 'A request id is required' using errcode = '22023'; end if;
  v_id := 'hb-' || p_request_id::text;
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id = v_id then   -- retry of a request that already succeeded
    res := jsonb_build_object('item', public._homebrew_json(v_id), 'link', (select detail from public.legacy_inventory_review
             where inventory_item_id = r.id and category = 'converted_to_homebrew' order by id desc limit 1), 'replayed', true);
    perform public._rpc_end(); return res;
  end if;
  r := public._legacy_row_for_link(p_item);
  if exists (select 1 from public.items where id = v_id) then raise exception 'This request id was already used' using errcode = '23505'; end if;
  perform public._write_homebrew(v_id, p_definition, p_stats, true);
  select * into it from public.items where id = v_id;
  insert into public.homebrew_item_events (item_id, actor_id, action, changes)
  values (v_id, auth.uid(), 'convert', jsonb_build_object('legacy_inventory_item', r.id, 'legacy_name', r.name, 'legacy_description', r.description,
                                                          'legacy_weight', r.weight, 'definition', p_definition, 'stats', p_stats));
  res := jsonb_build_object('item', public._homebrew_json(v_id), 'link', public._apply_link(r, it, 'converted_to_homebrew'));
  perform public._rpc_end(); return res;
end;
$function$;

-- create_homebrew_item(uuid,jsonb,jsonb)
CREATE OR REPLACE FUNCTION public.create_homebrew_item(p_request_id uuid, p_definition jsonb, p_stats jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_id text; ex public.items;
begin
  perform public._gov_content_gate(nullif(p_definition ->> 'campaign_id', '')::uuid, 'content.create_item');   -- campaign governance (20261019000100)
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  if p_request_id is null then raise exception 'A request id is required' using errcode = '22023'; end if;
  v_id := 'hb-' || p_request_id::text;
  select * into ex from public.items where id = v_id;
  if ex.id is not null then
    if ex.owner_id = auth.uid() then return public._homebrew_json(v_id) || '{"replayed": true}'; end if;
    raise exception 'This request id was already used' using errcode = '23505';
  end if;
  perform public._write_homebrew(v_id, p_definition, p_stats, true);
  insert into public.homebrew_item_events (item_id, actor_id, action, changes)
  values (v_id, auth.uid(), 'create', jsonb_build_object('definition', p_definition, 'stats', p_stats));
  return public._homebrew_json(v_id);
end;
$function$;

-- update_homebrew_item(text,jsonb,jsonb)
CREATE OR REPLACE FUNCTION public.update_homebrew_item(p_item text, p_definition jsonb, p_stats jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare it public.items; before jsonb;
begin
  perform public._gov_content_gate((select campaign_id from public.items where id = p_item), 'content.create_item');   -- campaign governance (20261019000100)
  it := public._lock_homebrew(p_item);
  if it.archived_at is not null then raise exception 'Restore the item before editing it' using errcode = '22023'; end if;
  before := public._homebrew_json(p_item);
  perform public._write_homebrew(p_item, p_definition || jsonb_build_object('kind_id', coalesce(p_definition ->> 'kind_id', it.kind_id)), p_stats, false);
  insert into public.homebrew_item_events (item_id, actor_id, action, changes)
  values (p_item, auth.uid(), 'update', jsonb_build_object('before', before, 'definition', p_definition, 'stats', p_stats));
  return public._homebrew_json(p_item);
end;
$function$;

-- long_rest_character(uuid,uuid)
CREATE OR REPLACE FUNCTION public.long_rest_character(p_character uuid, p_rest_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r jsonb;
begin
  perform public._gov_gate(p_character, 'runtime.long_rest');   -- campaign governance (20261019000100)
  r := public._rest(p_character, 'long', p_rest_id);
  return r || jsonb_build_object('states_ended', public._end_states_on_rest(p_character));
end;
$function$;

-- short_rest_character(uuid,uuid)
CREATE OR REPLACE FUNCTION public.short_rest_character(p_character uuid, p_rest_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r jsonb;
begin
  perform public._gov_gate(p_character, 'runtime.short_rest');   -- campaign governance (20261019000100)
  r := public._rest(p_character, 'short', p_rest_id);
  return r || jsonb_build_object('states_ended', public._end_states_on_rest(p_character));
end;
$function$;

-- change_character_resource(uuid,integer,text)
CREATE OR REPLACE FUNCTION public.change_character_resource(p_resource uuid, p_delta integer, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.character_resources; rows jsonb; me jsonb; before int; after int;
begin
  perform public._gov_gate_resource_row(p_resource, 'runtime.resources');   -- campaign governance (20261019000100)
  select * into r from public.character_resources where id = p_resource;
  if auth.uid() is null or r.id is null or not public.can_access_character(r.character_id) then
    raise exception 'Resource not found' using errcode = '42501';
  end if;
  if p_delta is null or p_delta = 0 then raise exception 'Nothing to change' using errcode = '22023'; end if;
  perform 1 from public.characters where id = r.character_id for update;
  select * into r from public.character_resources where id = p_resource for update;
  rows := public._character_resource_rows(r.character_id, public._character_mods(r.character_id));
  select e into me from jsonb_array_elements(rows) e where e ->> 'id' = p_resource::text;
  if not (me ->> 'active')::boolean or not (me ->> 'unlocked')::boolean then
    raise exception '% is not available', r.name using errcode = '22023';
  end if;
  before := r.expended;
  if p_delta > 0 and not (me ->> 'unlimited')::boolean and before + p_delta > (me ->> 'max')::int then
    raise exception 'Not enough % left (% of %)', r.name, greatest((me ->> 'max')::int - before, 0), me ->> 'max' using errcode = '22023';
  end if;
  if p_delta < 0 and before + p_delta < 0 then raise exception 'Nothing of % to restore', r.name using errcode = '22023'; end if;
  after := case when (me ->> 'unlimited')::boolean then 0 else before + p_delta end;
  update public.character_resources set expended = after where id = p_resource;
  insert into public.character_resource_events (character_id, event_type, pool, resource_id, amount, expended_before, expended_after, reason)
  values (r.character_id, case when p_delta > 0 then 'expend' else 'restore' end, 'resource', p_resource, abs(p_delta), before, after,
          nullif(btrim(p_reason), ''));
  select e into me from jsonb_array_elements(public._character_resource_rows(r.character_id, public._character_mods(r.character_id))) e
  where e ->> 'id' = p_resource::text;
  return me;
end;
$function$;

-- save_character_resource(uuid,jsonb)
CREATE OR REPLACE FUNCTION public.save_character_resource(p_character uuid, p_resource jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k text; r public.character_resources; v_id uuid;
  allowed constant text[] := array['id', 'resource_key', 'name', 'source_type', 'source_id', 'character_class_id', 'max_formula', 'minimum',
    'die', 'recharge', 'unlock_level', 'spell_version_id', 'cast_level', 'active', 'notes'];
begin
  perform public._gov_gate(p_character, 'build.manual_stats');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if jsonb_typeof(p_resource) <> 'object' then raise exception 'The resource must be an object' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_resource) loop
    if not k = any (allowed) then raise exception 'Field "%" cannot be set on a resource', k using errcode = '22023'; end if;
  end loop;
  if p_resource ? 'max_formula' then
    perform public._resource_max(p_resource -> 'max_formula', '{"total_level": 1, "class_level": 1, "proficiency_bonus": 2, "mods": {}}');
  end if;
  if p_resource ->> 'character_class_id' is not null and not exists (
       select 1 from public.character_classes where id = (p_resource ->> 'character_class_id')::uuid and character_id = p_character) then
    raise exception 'Character class not found' using errcode = '22023';
  end if;
  v_id := nullif(p_resource ->> 'id', '')::uuid;
  if v_id is not null and not exists (select 1 from public.character_resources where id = v_id and character_id = p_character) then
    raise exception 'Resource not found' using errcode = '42501';
  end if;
  begin
    if v_id is null then
      insert into public.character_resources (character_id, resource_key, name, created_by)
      values (p_character, p_resource ->> 'resource_key', btrim(p_resource ->> 'name'), auth.uid()) returning id into v_id;
    end if;
    update public.character_resources set
      resource_key = coalesce(p_resource ->> 'resource_key', resource_key), name = coalesce(btrim(p_resource ->> 'name'), name),
      source_type = coalesce(p_resource ->> 'source_type', source_type), source_id = coalesce(p_resource ->> 'source_id', source_id),
      character_class_id = coalesce((p_resource ->> 'character_class_id')::uuid, character_class_id),
      max_formula = coalesce(p_resource -> 'max_formula', max_formula), minimum = coalesce((p_resource ->> 'minimum')::int, minimum),
      die = coalesce(p_resource ->> 'die', die), recharge = coalesce(p_resource ->> 'recharge', recharge),
      unlock_level = coalesce((p_resource ->> 'unlock_level')::int, unlock_level),
      spell_version_id = coalesce(p_resource ->> 'spell_version_id', spell_version_id),
      cast_level = coalesce((p_resource ->> 'cast_level')::int, cast_level),
      active = coalesce((p_resource ->> 'active')::boolean, active), notes = coalesce(nullif(btrim(p_resource ->> 'notes'), ''), notes)
    where id = v_id returning * into r;
  exception
    when check_violation or not_null_violation or invalid_text_representation or foreign_key_violation or unique_violation then
      raise exception 'Invalid resource: %', sqlerrm using errcode = '22023';
  end;
  return to_jsonb(r) - 'created_by';
end;
$function$;

-- delete_character_resource(uuid)
CREATE OR REPLACE FUNCTION public.delete_character_resource(p_resource uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cid uuid;
begin
  perform public._gov_gate_resource_row(p_resource, 'build.manual_stats');   -- campaign governance (20261019000100)
  select character_id into cid from public.character_resources where id = p_resource;
  if auth.uid() is null or cid is null or not public.can_access_character(cid) then
    raise exception 'Resource not found' using errcode = '42501';
  end if;
  delete from public.character_resources where id = p_resource;
  return jsonb_build_object('deleted', true, 'id', p_resource);
end;
$function$;

-- set_spell_slot_state(uuid,text,integer,integer,text)
CREATE OR REPLACE FUNCTION public.set_spell_slot_state(p_character uuid, p_pool text, p_slot_level integer, p_expended integer, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare prog jsonb; mx int; before int; lvl int := case when p_pool = 'pact' then 0 else p_slot_level end;
begin
  perform public._gov_gate(p_character, 'runtime.resources');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if p_pool not in ('standard', 'pact') then raise exception 'Unknown slot pool "%"', p_pool using errcode = '22023'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A manual correction needs a reason' using errcode = '22023'; end if;
  perform 1 from public.characters where id = p_character for update;
  prog := public._class_progress(p_character, public._character_mods(p_character));
  mx := case when p_pool = 'pact' then (prog -> 'pact' ->> 'slots')::int else (prog -> 'standard_max' ->> p_slot_level::text)::int end;
  if mx is null then raise exception 'This character has no such spell slots' using errcode = '22023'; end if;
  if p_expended is null or p_expended < 0 or p_expended > mx then
    raise exception 'Expended slots must be between 0 and %', mx using errcode = '22023';
  end if;
  insert into public.character_spell_slot_state (character_id, pool, slot_level) values (p_character, p_pool, lvl) on conflict do nothing;
  select expended into before from public.character_spell_slot_state where character_id = p_character and pool = p_pool and slot_level = lvl for update;
  if before is distinct from p_expended then                      -- a correction that changes nothing is not logged
    update public.character_spell_slot_state set expended = p_expended where character_id = p_character and pool = p_pool and slot_level = lvl;
    insert into public.character_resource_events (character_id, event_type, pool, slot_level, expended_before, expended_after, reason)
    values (p_character, 'manual_set', p_pool, p_slot_level, before, p_expended, btrim(p_reason));
  end if;
  return public.get_character_spell_slots(p_character);
end;
$function$;

-- recover_spell_slots(uuid,text,integer[],text)
CREATE OR REPLACE FUNCTION public.recover_spell_slots(p_character uuid, p_resource_key text, p_slot_levels integer[], p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare me jsonb; budget int; maxl int; total int; l int; need record; have int; other text; om jsonb;
begin
  perform public._gov_gate(p_character, 'runtime.resources');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  select x into me from jsonb_array_elements(public._character_feature_resources(p_character, public._character_mods(p_character))) x
  where x ->> 'key' = p_resource_key;
  if me is null or not (me -> 'config') ? 'slot_recovery' then
    raise exception 'This resource does not recover spell slots' using errcode = '22023';
  end if;
  if not (me ->> 'active')::boolean then raise exception '% is not available', me ->> 'name' using errcode = '22023'; end if;
  if coalesce((me ->> 'remaining')::int, 0) < 1 then raise exception '% is already used', me ->> 'name' using errcode = '22023'; end if;
  -- Pact Magic recovery (Eldritch Master): every expended Pact slot comes back; the levels are not chosen
  if me -> 'config' -> 'slot_recovery' ->> 'pool' = 'pact' then
    select coalesce(expended, 0) into have from public.character_spell_slot_state where character_id = p_character and pool = 'pact' and slot_level = 0;
    if coalesce(have, 0) = 0 then raise exception 'No expended Pact Magic slot to recover' using errcode = '22023'; end if;
    perform public._resource_change(p_character, p_resource_key, 'expend', 1, null, null, null, format('%s: Pact Magic slots', me ->> 'name'));
    for l in 1..have loop perform public._slot_change(p_character, 'pact', null, -1, me ->> 'name'); end loop;
    return jsonb_build_object('resource', (select x from jsonb_array_elements((public.get_character_resources(p_character)) -> 'resources') x
                                           where x ->> 'key' = p_resource_key),
                              'recovered', jsonb_build_object('pact', have), 'slots', public.get_character_spell_slots(p_character));
  end if;
  if coalesce(cardinality(p_slot_levels), 0) = 0 then raise exception 'Choose at least one expended slot to recover' using errcode = '22023'; end if;
  budget := (me ->> 'slot_recovery_budget')::int;
  maxl := (me -> 'config' -> 'slot_recovery' ->> 'max_slot_level')::int;
  select sum(x) into total from unnest(p_slot_levels) x;
  if exists (select 1 from unnest(p_slot_levels) x where x is null or x < 1 or x > maxl) then
    raise exception '% recovers slots of level 1 to % only', me ->> 'name', maxl using errcode = '22023';
  end if;
  if total > budget then
    raise exception 'The slot levels add up to %; % recovers at most % levels of slots', total, me ->> 'name', budget using errcode = '22023';
  end if;
  if (me -> 'config' -> 'slot_recovery') ? 'max_slots' and cardinality(p_slot_levels) > (me -> 'config' -> 'slot_recovery' ->> 'max_slots')::int then
    raise exception '% recovers % slot(s) at a time', me ->> 'name', me -> 'config' -> 'slot_recovery' ->> 'max_slots' using errcode = '22023';
  end if;
  -- a second resource of the same class row that the recovery also spends (Harness Divine Power: a Channel Divinity use)
  other := me -> 'config' -> 'slot_recovery' ->> 'also_expend';
  if other is not null then
    select x into om from jsonb_array_elements(public._character_feature_resources(p_character, public._character_mods(p_character))) x
    where x ->> 'resource_id' = other and x ->> 'character_class_id' = me ->> 'character_class_id';
    if om is null or not (om ->> 'active')::boolean or coalesce((om ->> 'remaining')::int, 0) < 1 then
      raise exception '% also needs one use of %, and none is left', me ->> 'name', coalesce(om ->> 'name', other) using errcode = '22023';
    end if;
  end if;
  for need in select x as lvl, count(*) as n from unnest(p_slot_levels) x group by x loop
    select coalesce(expended, 0) into have from public.character_spell_slot_state
    where character_id = p_character and pool = 'standard' and slot_level = need.lvl;
    if coalesce(have, 0) < need.n then
      raise exception 'Only % expended level % slot(s) to recover', coalesce(have, 0), need.lvl using errcode = '22023';
    end if;
  end loop;
  perform public._resource_change(p_character, p_resource_key, 'expend', 1, null, null, null,
                                  coalesce(nullif(btrim(p_reason), ''), format('%s: slot levels %s', me ->> 'name', array_to_string(p_slot_levels, ', '))));
  if other is not null then
    perform public._resource_change(p_character, om ->> 'key', 'expend', 1, null, null, null, format('Spent by %s', me ->> 'name'));
  end if;
  foreach l in array p_slot_levels loop
    perform public._slot_change(p_character, 'standard', l, -1, format('%s', me ->> 'name'));
  end loop;
  return jsonb_build_object('resource', (select x from jsonb_array_elements((public.get_character_resources(p_character)) -> 'resources') x
                                         where x ->> 'key' = p_resource_key),
                            'recovered', to_jsonb(p_slot_levels), 'budget', budget, 'slots', public.get_character_spell_slots(p_character));
end;
$function$;

-- convert_spell_slot(uuid,text,text,integer,text)
CREATE OR REPLACE FUNCTION public.convert_spell_slot(p_character uuid, p_resource_key text, p_direction text, p_slot_level integer, p_pool text DEFAULT 'standard'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare me jsonb; cost int; gain int; pact jsonb;
begin
  perform public._gov_gate(p_character, 'runtime.resources');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  select x into me from jsonb_array_elements(public._character_feature_resources(p_character, public._character_mods(p_character))) x
  where x ->> 'key' = p_resource_key;
  if me is null or not (me -> 'config') ? 'conversion' then
    raise exception 'This resource cannot be converted to or from spell slots' using errcode = '22023';
  end if;
  if not (me ->> 'active')::boolean then raise exception '% is not available', me ->> 'name' using errcode = '22023'; end if;
  if p_direction = 'points_to_slot' then
    if p_slot_level is null or p_slot_level < 1 or p_slot_level > (me -> 'config' -> 'conversion' ->> 'max_created_level')::int then
      raise exception 'You can create spell slots of level 1 to %', me -> 'config' -> 'conversion' ->> 'max_created_level' using errcode = '22023';
    end if;
    cost := (me -> 'config' -> 'conversion' -> 'create_costs' ->> p_slot_level::text)::int;
    if coalesce((me ->> 'remaining')::int, 0) < cost then
      raise exception 'A level % slot costs % %; % left', p_slot_level, cost, me ->> 'name', coalesce((me ->> 'remaining')::int, 0) using errcode = '22023';
    end if;
    perform public._resource_change(p_character, p_resource_key, 'expend', cost, null, null, null, format('Created a level %s spell slot', p_slot_level));
    insert into public.character_temporary_spell_slots (character_id, slot_level, quantity, source_type, source_label, expires_on, created_by)
    values (p_character, p_slot_level, 1, 'feature', left(me ->> 'feature_name', 80), 'long_rest', auth.uid());
    insert into public.character_resource_events (character_id, event_type, pool, slot_level, amount, reason, details)
    values (p_character, 'restore', 'temporary', p_slot_level, 1, format('%s: created from %s %s', me ->> 'feature_name', cost, me ->> 'name'),
            jsonb_build_object('resource_key', p_resource_key, 'cost', cost));
  elsif p_direction = 'slot_to_points' then
    if p_pool not in ('standard', 'pact') then raise exception 'Unknown slot pool "%"', p_pool using errcode = '22023'; end if;
    if p_pool = 'pact' then
      pact := public.get_character_spell_slots(p_character) -> 'pact_magic';
      p_slot_level := (pact ->> 'slot_level')::int;
    end if;
    gain := least(coalesce(p_slot_level, 0), coalesce((me ->> 'expended')::int, 0));
    if gain < 1 then raise exception '% is already full', me ->> 'name' using errcode = '22023'; end if;
    perform public._slot_change(p_character, p_pool, p_slot_level, 1, format('Converted to %s', me ->> 'name'));
    perform public._resource_change(p_character, p_resource_key, 'restore', gain, null, null, null,
                                    format('Gained from a level %s spell slot', p_slot_level));
  else
    raise exception 'Unknown direction "%" (slot_to_points or points_to_slot)', p_direction using errcode = '22023';
  end if;
  return jsonb_build_object('resource', (select x from jsonb_array_elements((public.get_character_resources(p_character)) -> 'resources') x
                                         where x ->> 'key' = p_resource_key),
                            'slots', public.get_character_spell_slots(p_character));
end;
$function$;

-- expend_standard_spell_slot(uuid,integer,text)
CREATE OR REPLACE FUNCTION public.expend_standard_spell_slot(p_character uuid, p_slot_level integer, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public._gov_gate(p_character, 'runtime.resources');   -- campaign governance (20261019000100)
 select public._slot_change(p_character, 'standard', p_slot_level, 1, p_reason) $function$;

-- restore_standard_spell_slot(uuid,integer,text)
CREATE OR REPLACE FUNCTION public.restore_standard_spell_slot(p_character uuid, p_slot_level integer, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public._gov_gate(p_character, 'runtime.resources');   -- campaign governance (20261019000100)
 select public._slot_change(p_character, 'standard', p_slot_level, -1, p_reason) $function$;

-- expend_pact_magic_slot(uuid,text)
CREATE OR REPLACE FUNCTION public.expend_pact_magic_slot(p_character uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public._gov_gate(p_character, 'runtime.resources');   -- campaign governance (20261019000100)
 select public._slot_change(p_character, 'pact', null, 1, p_reason) $function$;

-- restore_pact_magic_slot(uuid,text)
CREATE OR REPLACE FUNCTION public.restore_pact_magic_slot(p_character uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public._gov_gate(p_character, 'runtime.resources');   -- campaign governance (20261019000100)
 select public._slot_change(p_character, 'pact', null, -1, p_reason) $function$;

-- expend_character_resource(uuid,text,integer,text)
CREATE OR REPLACE FUNCTION public.expend_character_resource(p_character uuid, p_resource_key text, p_amount integer DEFAULT 1, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public._gov_gate(p_character, 'runtime.resources');   -- campaign governance (20261019000100)
 select public._resource_change(p_character, p_resource_key, 'expend', p_amount, null, null, null, p_reason) $function$;

-- restore_character_resource(uuid,text,integer,text)
CREATE OR REPLACE FUNCTION public.restore_character_resource(p_character uuid, p_resource_key text, p_amount integer DEFAULT 1, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public._gov_gate(p_character, 'runtime.resources');   -- campaign governance (20261019000100)
 select public._resource_change(p_character, p_resource_key, 'restore', p_amount, null, null, null, p_reason) $function$;

-- set_character_resource_state(uuid,text,integer,text,integer,integer)
CREATE OR REPLACE FUNCTION public.set_character_resource_state(p_character uuid, p_resource_key text, p_expended integer, p_reason text, p_temporary_bonus integer DEFAULT NULL::integer, p_max_adjustment integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public._gov_gate(p_character, 'runtime.resources');   -- campaign governance (20261019000100)
 select public._resource_change(p_character, p_resource_key, 'set', null, p_expended, p_temporary_bonus, p_max_adjustment, p_reason) $function$;

-- use_temporary_spell_slot(uuid,uuid)
CREATE OR REPLACE FUNCTION public.use_temporary_spell_slot(p_character uuid, p_slot uuid)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public._gov_gate(p_character, 'runtime.resources');   -- campaign governance (20261019000100)
 select public._temporary_slot_change(p_character, p_slot, 1) $function$;

-- restore_temporary_spell_slot(uuid,uuid)
CREATE OR REPLACE FUNCTION public.restore_temporary_spell_slot(p_character uuid, p_slot uuid)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public._gov_gate(p_character, 'runtime.resources');   -- campaign governance (20261019000100)
 select public._temporary_slot_change(p_character, p_slot, -1) $function$;

-- start_character_state(uuid,text,boolean)
CREATE OR REPLACE FUNCTION public.start_character_state(p_character uuid, p_state text, p_spend boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s record; spent boolean := false;
begin
  perform public._gov_gate(p_character, 'runtime.states');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;          -- one state change per character at a time
  select st.*, ul.character_class_id into s
  from public._character_feature_unlocks(p_character) ul join public.class_feature_states st on st.feature_version_id = ul.feature_version_id
  where ul.active and st.key = p_state limit 1;
  if s.key is null then raise exception 'This character has no state "%"', p_state using errcode = '22023'; end if;
  if exists (select 1 from public.character_active_states where character_id = p_character and state_key = p_state) then
    raise exception '% is already active', s.name using errcode = '22023';
  end if;
  if s.resource_id is not null and coalesce(p_spend, true) then
    perform public.expend_character_resource(p_character, 'f:' || s.character_class_id || ':' || s.resource_id, 1);
    spent := true;
  end if;
  insert into public.character_active_states (character_id, state_key, character_class_id, feature_version_id, resource_spent, started_by)
  values (p_character, p_state, s.character_class_id, s.feature_version_id, spent, auth.uid());
  return public.get_character_states(p_character);
end;
$function$;

-- end_character_state(uuid,text)
CREATE OR REPLACE FUNCTION public.end_character_state(p_character uuid, p_state text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform public._gov_gate(p_character, 'runtime.states');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  delete from public.character_active_states where character_id = p_character and state_key = p_state;
  if not found then raise exception 'That state is not active' using errcode = '22023'; end if;
  return public.get_character_states(p_character);
end;
$function$;

-- apply_infusion(uuid,text,uuid,text)
CREATE OR REPLACE FUNCTION public.apply_infusion(p_character uuid, p_infusion text, p_inventory_item uuid DEFAULT NULL::uuid, p_replicate_item text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c record; o public.class_feature_choice_options; inf jsonb; inv uuid; ii public.inventory_items; why text; mid text;
  new_item uuid; comp uuid; hp int; mods jsonb; d jsonb;
begin
  perform public._gov_gate(p_character, 'runtime.states');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;                -- one infusion change at a time
  select x.* into c from public._character_infusion_choices(p_character) x where p_infusion = any (x.known) limit 1;
  if c.choice_id is null then raise exception 'You do not know this infusion' using errcode = '22023'; end if;
  select * into o from public.class_feature_choice_options where choice_id = c.choice_id and option_id = p_infusion;
  inf := o.data -> 'infusion';
  if (select count(*) from public.character_infusions where character_id = p_character and choice_id = c.choice_id) >= c.max_items then
    raise exception 'You already have % infused items; end an infusion first', c.max_items using errcode = '22023';
  end if;
  select id into inv from public.inventories where character_id = p_character and kind = 'character';
  mid := public._infusion_modifier(inf, c.class_level);
  perform set_config('tavern.managed_modifier', '1', true);

  if inf -> 'item' ? 'none' then                                                       -- Replicate Magic Item
    if p_replicate_item is null or not exists (select 1 from jsonb_array_elements(inf -> 'replicate') e, jsonb_array_elements_text(e -> 1) x
                                               where (e ->> 0)::int <= c.class_level and x = p_replicate_item) then
      raise exception 'Choose a magic item you can replicate at your level' using errcode = '22023';
    end if;
    new_item := public.add_inventory_item(inv, p_replicate_item, 1, null, format('Infused: %s', o.label), '{}'::jsonb);
    insert into public.character_infusions (character_id, character_class_id, infusion_id, choice_id, inventory_item_id, created_item, applied_by)
    values (p_character, c.character_class_id, p_infusion, c.choice_id, new_item, true, auth.uid());
  elsif inf ? 'companion' then                                                          -- Homunculus Servant
    d := public.get_character_derived_stats(p_character);
    select jsonb_object_agg(k, (d -> 'abilities' -> k ->> 'modifier')::int) into mods from jsonb_object_keys(d -> 'abilities') k;
    hp := greatest(1, (public._resource_max(inf -> 'companion' -> 'hp', jsonb_build_object('class_level', c.class_level,
            'total_level', c.class_level, 'proficiency_bonus', (d -> 'proficiency_bonus' ->> 'value')::int, 'mods', mods)) ->> 'max')::int);
    comp := public.add_character_companion(p_character, null, inf -> 'companion' ->> 'name', o.label, hp);
    if p_inventory_item is not null then
      select * into ii from public.inventory_items where id = p_inventory_item and inventory_id = inv;
      if ii.id is null then raise exception 'That item is not in this character''s inventory' using errcode = '22023'; end if;
    end if;
    insert into public.character_infusions (character_id, character_class_id, infusion_id, choice_id, inventory_item_id, companion_id, applied_by)
    values (p_character, c.character_class_id, p_infusion, c.choice_id, ii.id, comp, auth.uid());
  else
    select * into ii from public.inventory_items where id = p_inventory_item and inventory_id = inv for update;
    if ii.id is null then raise exception 'Choose an item from this character''s inventory' using errcode = '22023'; end if;
    why := public._infusion_item_refusal(inf, ii);
    if why is not null then raise exception '%', why using errcode = '22023'; end if;
    if ii.quantity > 1 then raise exception 'Split the stack first: only one item can hold the infusion' using errcode = '22023'; end if;
    insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (ii.id, mid);
    insert into public.character_infusions (character_id, character_class_id, infusion_id, choice_id, inventory_item_id, modifier_id, applied_by)
    values (p_character, c.character_class_id, p_infusion, c.choice_id, ii.id, mid, auth.uid());
  end if;
  perform set_config('tavern.managed_modifier', '', true);
  return public.get_character_infusions(p_character);
end;
$function$;

-- remove_infusion(uuid,uuid)
CREATE OR REPLACE FUNCTION public.remove_infusion(p_character uuid, p_infusion_row uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.character_infusions;
begin
  perform public._gov_gate(p_character, 'runtime.states');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  select * into r from public.character_infusions where id = p_infusion_row and character_id = p_character;
  if not found then raise exception 'Infusion not found' using errcode = '22023'; end if;
  perform set_config('tavern.managed_modifier', '1', true);
  if r.modifier_id is not null then
    -- unattune first when only this infusion needed attunement (the item is re-checked when its modifier goes)
    update public.inventory_items ii set is_attuned = false
    where ii.id = r.inventory_item_id and ii.is_attuned
      and not coalesce((select requires_attunement from public.items where id = ii.item_id), false)
      and not exists (select 1 from public.inventory_item_modifiers im join public.item_modifiers md on md.id = im.modifier_id
                      where im.inventory_item_id = ii.id and md.requires_attunement_override and im.modifier_id <> r.modifier_id);
    delete from public.inventory_item_modifiers where inventory_item_id = r.inventory_item_id and modifier_id = r.modifier_id;
  end if;
  delete from public.character_infusions where id = r.id;
  if r.created_item then delete from public.inventory_items where id = r.inventory_item_id; end if;
  if r.companion_id is not null then delete from public.character_companions where id = r.companion_id; end if;
  perform set_config('tavern.managed_modifier', '', true);
  return public.get_character_infusions(p_character);
end;
$function$;

-- refresh_infusions(uuid)
CREATE OR REPLACE FUNCTION public.refresh_infusions(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r record;
begin
  perform public._gov_gate(p_character, 'runtime.states');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  perform set_config('tavern.managed_modifier', '1', true);
  for r in select ci.id, ci.inventory_item_id, ci.modifier_id, public._infusion_modifier(o.data -> 'infusion', c.class_level) as want
           from public.character_infusions ci
           join public.class_feature_choice_options o on o.choice_id = ci.choice_id and o.option_id = ci.infusion_id
           join public._character_infusion_choices(p_character) c on c.choice_id = ci.choice_id and c.character_class_id = ci.character_class_id
           where ci.character_id = p_character and ci.modifier_id is not null loop
    if r.want is not null and r.want <> r.modifier_id then
      delete from public.inventory_item_modifiers where inventory_item_id = r.inventory_item_id and modifier_id = r.modifier_id;
      insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (r.inventory_item_id, r.want);
      update public.character_infusions set modifier_id = r.want where id = r.id;
    end if;
  end loop;
  perform set_config('tavern.managed_modifier', '', true);
  return public.get_character_infusions(p_character);
end;
$function$;

-- start_transformation(uuid,text,jsonb)
CREATE OR REPLACE FUNCTION public.start_transformation(p_character uuid, p_creature text, p_options jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c public.creatures; o record; ch public.characters; mode text; items jsonb := '{}'; k text; dropped jsonb := '{}'; v text;
begin
  perform public._gov_gate(p_character, 'runtime.wild_shape');   -- campaign governance (20261019000100)
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
$function$;

-- end_transformation(uuid,text)
CREATE OR REPLACE FUNCTION public.end_transformation(p_character uuid, p_reason text DEFAULT 'manual'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.character_transformations;
begin
  perform public._gov_gate(p_character, 'runtime.wild_shape');   -- campaign governance (20261019000100)
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
$function$;

-- change_transformation_hp(uuid,integer)
CREATE OR REPLACE FUNCTION public.change_transformation_hp(p_character uuid, p_delta integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r jsonb;
begin
  perform public._gov_gate(p_character, 'runtime.wild_shape');   -- campaign governance (20261019000100)
  if p_delta is null or p_delta = 0 then raise exception 'Give a damage or healing amount' using errcode = '22023'; end if;
  r := case when p_delta < 0 then public.damage_active_transformation(p_character, -p_delta) else public.heal_active_transformation(p_character, p_delta) end;
  return r || jsonb_build_object('ended', coalesce((r -> 'result' ->> 'ended')::boolean, false),
                                 'carryover', coalesce((r -> 'result' ->> 'carryover')::int, 0));
end;
$function$;

-- set_transformation_hp(uuid,integer,integer,text)
CREATE OR REPLACE FUNCTION public.set_transformation_hp(p_character uuid, p_hp integer, p_temp integer DEFAULT NULL::integer, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.character_transformations;
begin
  perform public._gov_gate(p_character, 'runtime.wild_shape');   -- campaign governance (20261019000100)
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
$function$;

-- heal_active_transformation(uuid,integer,text)
CREATE OR REPLACE FUNCTION public.heal_active_transformation(p_character uuid, p_amount integer, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.character_transformations; nv int;
begin
  perform public._gov_gate(p_character, 'runtime.wild_shape');   -- campaign governance (20261019000100)
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
$function$;

-- damage_active_transformation(uuid,integer,text)
CREATE OR REPLACE FUNCTION public.damage_active_transformation(p_character uuid, p_amount integer, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.character_transformations; ch public.characters; temp_used int; left_dmg int; nv int; carry int := 0; ntemp int := 0; nhp int;
  result jsonb;
begin
  perform public._gov_gate(p_character, 'runtime.wild_shape');   -- campaign governance (20261019000100)
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
$function$;

-- use_form_ability(uuid,text,text,integer)
CREATE OR REPLACE FUNCTION public.use_form_ability(p_character uuid, p_ability text, p_action text DEFAULT 'use'::text, p_roll integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.character_transformations; c public.creatures; a jsonb; avail boolean; roll int; minv int;
begin
  perform public._gov_gate(p_character, 'runtime.wild_shape');   -- campaign governance (20261019000100)
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
$function$;

-- combat_wild_shape_heal(uuid,integer,text,integer)
CREATE OR REPLACE FUNCTION public.combat_wild_shape_heal(p_character uuid, p_slot_level integer, p_pool text DEFAULT 'standard'::text, p_roll integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.character_transformations; roll int := 0; i int; nv int; pact jsonb;
begin
  perform public._gov_gate(p_character, 'runtime.wild_shape');   -- campaign governance (20261019000100)
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
$function$;

-- set_transformation_equipment(uuid,uuid,text)
CREATE OR REPLACE FUNCTION public.set_transformation_equipment(p_character uuid, p_item uuid, p_mode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.character_transformations;
begin
  perform public._gov_gate(p_character, 'runtime.wild_shape');   -- campaign governance (20261019000100)
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
$function$;

-- set_form_favorite(uuid,text,boolean)
CREATE OR REPLACE FUNCTION public.set_form_favorite(p_character uuid, p_creature text, p_favorite boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform public._gov_gate(p_character, 'runtime.wild_shape');   -- campaign governance (20261019000100)
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
$function$;

-- set_wild_shape_settings(uuid,text,text,boolean)
CREATE OR REPLACE FUNCTION public.set_wild_shape_settings(p_character uuid, p_seen_mode text DEFAULT NULL::text, p_default_equipment text DEFAULT NULL::text, p_confirm_lethal boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cur public.character_wild_shape_settings;
begin
  perform public._gov_gate_wild_shape_settings(p_character, p_seen_mode);   -- campaign governance (20261019000100)
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
$function$;

-- set_seen_forms(uuid,text[],boolean,text,text)
CREATE OR REPLACE FUNCTION public.set_seen_forms(p_character uuid, p_creatures text[], p_seen boolean DEFAULT true, p_source text DEFAULT 'seen'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare x text;
begin
  perform public._gov_gate(p_character, 'runtime.mark_seen_form');   -- campaign governance (20261019000100)
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
$function$;
