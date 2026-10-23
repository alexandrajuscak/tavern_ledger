-- =============================================================================
-- SYNTHETIC TEST CONTENT for the class feature engine (migration 20261015001800). NOT official D&D content, never part of
-- supabase/seed (config.toml does not load it). Loaded by the SQL / API / browser tests and by the local demo seeder.
-- Every row is marked content_scope = 'test' / source_status = 'test_fixture'. Idempotent (upserts only, no deletes).
--
-- "Engine Test Class" exercises every engine path the Fighter (and later classes) will need: level unlocks, optional and
-- replacement features, choices (single, multiple, dependent sub-choice, skills, expertise, spells, ASI / feat placeholder,
-- prerequisites), subclass selection and subclass features, resources (short / long rest, scaling, partial recovery,
-- ability-based maximum, die scaling), proficiency / spell / attack grants, attack count, critical range, AC formula,
-- informational features. Expected values: docs/LOCAL_TEST_CHARACTERS.md ("Local Feature Tester").
-- =============================================================================
begin;

insert into public.classes as t (id, name, sort_order, content_scope) values ('engine-test', 'Engine Test Class', 99, 'test')
on conflict (id) do update set name = excluded.name, sort_order = excluded.sort_order, content_scope = excluded.content_scope;

insert into public.class_versions as t (id, class_id, name, source_label, source_url, status, rules_edition, spellcasting_ability,
  preparation_mode, ritual_mode, caster_type, hit_die, rules_label, multiclass_contribution, implementation_status, limitations,
  content_scope, subclass_level, notes)
values ('engine-test-fixture', 'engine-test', 'Engine Test Class (test fixture)', 'Tavern Ledger test fixture (synthetic)',
  'https://example.invalid/tavern-ledger/engine-test-fixture', 'current', '2014', 'wis', 'none', 'none', 'none', 'd8', 'Test fixture',
  'none', 'partial', '{"Synthetic test content for the class feature engine. Not an official class."}', 'test', 3,
  'Test fixture only (supabase/tests/fixtures/class_feature_engine_fixture.sql).')
on conflict (id) do update set name = excluded.name, source_label = excluded.source_label, source_url = excluded.source_url,
  spellcasting_ability = excluded.spellcasting_ability, hit_die = excluded.hit_die, rules_label = excluded.rules_label,
  multiclass_contribution = excluded.multiclass_contribution, implementation_status = excluded.implementation_status,
  limitations = excluded.limitations, content_scope = excluded.content_scope, subclass_level = excluded.subclass_level, notes = excluded.notes;

insert into public.subclasses as t (id, class_id, name, content_scope) values ('engine-test-path', 'engine-test', 'Test Path', 'test')
on conflict (id) do update set name = excluded.name, content_scope = excluded.content_scope;
insert into public.subclass_versions as t (id, class_id, name, source_label, source_url, status, preparation_mode, multiclass_contribution,
  implementation_status, limitations, subclass_id, class_version_id, selection_level, content_scope, notes)
values ('engine-test-path-fixture', 'engine-test', 'Test Path (test fixture)', 'Tavern Ledger test fixture (synthetic)',
  'https://example.invalid/tavern-ledger/engine-test-path', 'current', 'none', 'none', 'features_partial',
  '{"Synthetic test content for the class feature engine. Not an official subclass."}', 'engine-test-path', 'engine-test-fixture', 3, 'test',
  'Test fixture only.')
on conflict (id) do update set name = excluded.name, implementation_status = excluded.implementation_status, limitations = excluded.limitations,
  subclass_id = excluded.subclass_id, class_version_id = excluded.class_version_id, selection_level = excluded.selection_level,
  content_scope = excluded.content_scope;

-- ---- features (identity + version) ---------------------------------------------------------------------------------------
insert into public.class_features as t (id, class_id, subclass_id, name, content_scope)
select x.id, 'engine-test', x.sub, x.name, 'test' from (values
  ('et-proficiencies', null, 'Test Proficiencies'), ('et-fighting-style', null, 'Test Fighting Style'),
  ('et-surge', null, 'Test Surge'), ('et-inspiration', null, 'Test Inspiration'), ('et-expertise', null, 'Test Expertise'),
  ('et-strike', null, 'Spirit Strike'), ('et-unarmored', null, 'Test Unarmored Defense'), ('et-optional-lore', null, 'Optional Lore'),
  ('et-discipline', null, 'Test Discipline'), ('et-burst', null, 'Test Burst'), ('et-focus', null, 'Test Focus Pool'),
  ('et-tactical-note', null, 'Tactical Note'), ('et-subclass', null, 'Test Path Choice'), ('et-keen-senses', null, 'Keen Senses'),
  ('et-swift-reflexes', null, 'Swift Reflexes'), ('et-insight', null, 'Test Insight'), ('et-asi', null, 'Ability Score Improvement'),
  ('et-extra-attack', null, 'Extra Attack'), ('et-reserve', null, 'Test Reserve'), ('et-advanced', null, 'Advanced Technique'),
  ('et-path-precision', 'engine-test-path', 'Path Precision'), ('et-path-training', 'engine-test-path', 'Path Training'),
  ('et-path-spells', 'engine-test-path', 'Path Spells'), ('et-path-mastery', 'engine-test-path', 'Path Mastery')) x(id, sub, name)
on conflict (id) do update set subclass_id = excluded.subclass_id, name = excluded.name, content_scope = excluded.content_scope;

insert into public.class_feature_versions as t (id, feature_id, name, summary, source_label, source_status, automation, automation_notes,
  activation, repeatable)
select x.id, x.id, x.name, x.summary, 'Tavern Ledger test fixture (synthetic)', 'test_fixture', x.auto, x.note, x.act, x.rep from (values
  ('et-proficiencies', 'Test Proficiencies', 'Starting proficiencies: WIS and CON saves (first class only), armor and weapons, two skills.', 'automated', null, 'passive', false),
  ('et-fighting-style', 'Test Fighting Style', 'Choose one fighting style option. Some options change attacks or AC; others are reminders.', 'partially_automated', 'Protection and Blind Fighting are informational.', 'passive', false),
  ('et-surge', 'Test Surge', 'A short-rest resource: one use, back after a short or long rest.', 'automated', null, 'bonus_action', false),
  ('et-inspiration', 'Test Inspiration', 'Uses equal to your CHA modifier (at least 1); the die grows with level. Back after a long rest.', 'automated', null, 'bonus_action', false),
  ('et-expertise', 'Test Expertise', 'Choose two skills you are proficient in; your proficiency bonus is doubled for them.', 'automated', null, 'passive', false),
  ('et-strike', 'Spirit Strike', 'A force strike that is always available; its damage die grows at levels 5 and 11.', 'automated', null, 'action', false),
  ('et-unarmored', 'Test Unarmored Defense', 'Without armor and shield your AC is 10 + DEX + WIS.', 'automated', null, 'passive', false),
  ('et-optional-lore', 'Optional Lore', 'An optional feature: learn Elvish.', 'automated', null, 'passive', false),
  ('et-discipline', 'Test Discipline', 'Choose a discipline; the Elements discipline then asks for an element (resistance). Also choose two techniques.', 'partially_automated', 'Techniques are reminders.', 'passive', false),
  ('et-burst', 'Test Burst', 'A short-rest resource with one use (two from level 17).', 'automated', null, 'special', false),
  ('et-focus', 'Test Focus Pool', 'Points equal to your class level. A long rest restores all; a short rest restores 1.', 'automated', null, 'special', false),
  ('et-tactical-note', 'Tactical Note', 'Advantage on Stealth while hidden in dim light. Contextual: shown as a reminder only.', 'informational', 'Depends on the situation; never applied automatically.', 'passive', false),
  ('et-subclass', 'Test Path Choice', 'At level 3 choose a path (subclass).', 'automated', null, 'passive', false),
  ('et-keen-senses', 'Keen Senses', '+1 to initiative.', 'automated', null, 'passive', false),
  ('et-swift-reflexes', 'Swift Reflexes', 'Optional replacement for Keen Senses: add your proficiency bonus to initiative and +5 ft speed without heavy armor.', 'automated', null, 'passive', false),
  ('et-insight', 'Test Insight', 'Detect Magic is always prepared (ritual). Choose one Wizard cantrip.', 'automated', null, 'passive', false),
  ('et-asi', 'Ability Score Improvement', 'Increase one ability by 2 or two abilities by 1, or choose a feat (feat catalog: future).', 'partially_automated', 'Feats are a placeholder until the feat catalog exists.', 'passive', true),
  ('et-extra-attack', 'Extra Attack', 'Attack twice when you take the Attack action (three times from level 11).', 'automated', null, 'passive', false),
  ('et-reserve', 'Test Reserve', 'Uses equal to your proficiency bonus, back after a long rest.', 'automated', null, 'special', false),
  ('et-advanced', 'Advanced Technique', 'Requires the Test Path subclass. +1 to Strength saving throws.', 'automated', null, 'passive', false),
  ('et-path-precision', 'Path Precision', 'Your weapon attacks score a critical hit on a roll of 19 or 20.', 'automated', null, 'passive', false),
  ('et-path-training', 'Path Training', 'Proficiency with heavy armor.', 'automated', null, 'passive', false),
  ('et-path-spells', 'Path Spells', 'Shield is always prepared for you.', 'automated', null, 'passive', false),
  ('et-path-mastery', 'Path Mastery', 'Two uses per long rest.', 'automated', null, 'special', false)
) x(id, name, summary, auto, note, act, rep)
on conflict (id) do update set name = excluded.name, summary = excluded.summary, source_label = excluded.source_label,
  source_status = excluded.source_status, automation = excluded.automation, automation_notes = excluded.automation_notes,
  activation = excluded.activation, repeatable = excluded.repeatable;

-- ---- unlocks --------------------------------------------------------------------------------------------------------------
insert into public.class_feature_unlocks as t (id, class_version_id, subclass_version_id, level, feature_version_id, is_optional,
  replaces_unlock_id, replacement_mode, prerequisites, sort_order)
select x.id, x.cv, x.sv, x.lvl, x.fv, x.opt, x.rep, x.mode, x.pre::jsonb, x.ord from (values
  ('et-u1-proficiencies', 'engine-test-fixture', null, 1, 'et-proficiencies', false, null, null, '{}', 1),
  ('et-u1-fighting-style', 'engine-test-fixture', null, 1, 'et-fighting-style', false, null, null, '{}', 2),
  ('et-u1-surge', 'engine-test-fixture', null, 1, 'et-surge', false, null, null, '{}', 3),
  ('et-u1-inspiration', 'engine-test-fixture', null, 1, 'et-inspiration', false, null, null, '{}', 4),
  ('et-u1-expertise', 'engine-test-fixture', null, 1, 'et-expertise', false, null, null, '{}', 5),
  ('et-u1-strike', 'engine-test-fixture', null, 1, 'et-strike', false, null, null, '{}', 6),
  ('et-u1-unarmored', 'engine-test-fixture', null, 1, 'et-unarmored', false, null, null, '{}', 7),
  ('et-u1-optional-lore', 'engine-test-fixture', null, 1, 'et-optional-lore', true, null, null, '{}', 8),
  ('et-u2-discipline', 'engine-test-fixture', null, 2, 'et-discipline', false, null, null, '{}', 1),
  ('et-u2-burst', 'engine-test-fixture', null, 2, 'et-burst', false, null, null, '{}', 2),
  ('et-u2-focus', 'engine-test-fixture', null, 2, 'et-focus', false, null, null, '{}', 3),
  ('et-u2-tactical-note', 'engine-test-fixture', null, 2, 'et-tactical-note', false, null, null, '{}', 4),
  ('et-u3-subclass', 'engine-test-fixture', null, 3, 'et-subclass', false, null, null, '{}', 1),
  ('et-u3-keen-senses', 'engine-test-fixture', null, 3, 'et-keen-senses', false, null, null, '{}', 2),
  ('et-u3-insight', 'engine-test-fixture', null, 3, 'et-insight', false, null, null, '{}', 4),
  ('et-u3-reserve', 'engine-test-fixture', null, 3, 'et-reserve', false, null, null, '{}', 5),
  ('et-u4-asi', 'engine-test-fixture', null, 4, 'et-asi', false, null, null, '{}', 1),
  ('et-u5-extra-attack', 'engine-test-fixture', null, 5, 'et-extra-attack', false, null, null, '{}', 1),
  ('et-u6-advanced', 'engine-test-fixture', null, 6, 'et-advanced', false, null, null,
     '{"all": [{"type": "subclass", "id": "engine-test-path-fixture"}]}', 1),
  ('et-u8-asi', 'engine-test-fixture', null, 8, 'et-asi', false, null, null, '{}', 1),
  ('et-p3-precision', null, 'engine-test-path-fixture', 3, 'et-path-precision', false, null, null, '{}', 1),
  ('et-p3-training', null, 'engine-test-path-fixture', 3, 'et-path-training', false, null, null, '{}', 2),
  ('et-p3-spells', null, 'engine-test-path-fixture', 3, 'et-path-spells', false, null, null, '{}', 3),
  ('et-p7-mastery', null, 'engine-test-path-fixture', 7, 'et-path-mastery', false, null, null, '{}', 1)
) x(id, cv, sv, lvl, fv, opt, rep, mode, pre, ord)
on conflict (id) do update set class_version_id = excluded.class_version_id, subclass_version_id = excluded.subclass_version_id,
  level = excluded.level, feature_version_id = excluded.feature_version_id, is_optional = excluded.is_optional,
  replaces_unlock_id = excluded.replaces_unlock_id, replacement_mode = excluded.replacement_mode,
  prerequisites = excluded.prerequisites, sort_order = excluded.sort_order;
-- the optional replacement after its target exists
insert into public.class_feature_unlocks as t (id, class_version_id, level, feature_version_id, is_optional, replaces_unlock_id,
  replacement_mode, sort_order)
values ('et-u3-swift-reflexes', 'engine-test-fixture', 3, 'et-swift-reflexes', true, 'et-u3-keen-senses', 'replace', 3)
on conflict (id) do update set level = excluded.level, feature_version_id = excluded.feature_version_id, is_optional = excluded.is_optional,
  replaces_unlock_id = excluded.replaces_unlock_id, replacement_mode = excluded.replacement_mode, sort_order = excluded.sort_order;

-- ---- scaling --------------------------------------------------------------------------------------------------------------
insert into public.class_feature_scaling as t (feature_version_id, key, label, value_type, table_by_level, unit) values
  ('et-strike', 'damage_die', 'Damage', 'dice', '[[1, "1d6"], [5, "1d8"], [11, "1d10"]]', null),
  ('et-inspiration', 'die', 'Inspiration die', 'dice', '[[1, "d6"], [5, "d8"], [10, "d10"]]', null),
  ('et-extra-attack', 'attacks', 'Attacks per Attack action', 'number', '[[5, 2], [11, 3]]', 'attacks'),
  ('et-burst', 'uses', 'Uses', 'number', '[[2, 1], [17, 2]]', 'uses'),
  ('et-focus', 'points', 'Focus points', 'number', '[[2, 2], [3, 3], [4, 4], [5, 5], [6, 6], [7, 7], [8, 8], [9, 9], [10, 10]]', 'points')
on conflict (feature_version_id, key) do update set label = excluded.label, value_type = excluded.value_type,
  table_by_level = excluded.table_by_level, unit = excluded.unit;

-- ---- choices and options ---------------------------------------------------------------------------------------------------
insert into public.class_feature_choices as t (id, feature_version_id, kind, label, min_picks, max_picks, level, config, applies_to,
  replaceable, allow_free_text, sort_order)
select x.id, x.fv, x.kind, x.label, x.mn, x.mx, x.lvl, x.cfg::jsonb, x.app, x.repl, x.ft, x.ord from (values
  ('et-skills', 'et-proficiencies', 'skill', 'Two skills', 2, 2, 1,
     '{"from": ["athletics", "insight", "perception", "stealth", "survival"]}', 'primary_class', false, false, 1),
  ('et-skills-mc', 'et-proficiencies', 'skill', 'One skill (multiclass)', 1, 1, 1,
     '{"from": ["athletics", "insight", "perception", "stealth", "survival"]}', 'multiclass', false, false, 2),
  ('et-style', 'et-fighting-style', 'option', 'Fighting style', 1, 1, 1, '{"group": "fighting-style"}', 'always', true, false, 1),
  ('et-expertise-pick', 'et-expertise', 'expertise', 'Two skills for expertise', 2, 2, 1, '{}', 'always', false, false, 1),
  ('et-discipline-pick', 'et-discipline', 'option', 'Discipline', 1, 1, 2, '{}', 'always', false, false, 1),
  ('et-techniques', 'et-discipline', 'option', 'Two techniques', 2, 2, 2, '{}', 'always', false, false, 3),
  ('et-subclass-pick', 'et-subclass', 'subclass', 'Test Path', 1, 1, 3, '{}', 'always', false, false, 1),
  ('et-cantrip', 'et-insight', 'spell', 'One Wizard cantrip', 1, 1, 3, '{"spell_list": "wizard-spell-list", "spell_level": 0}', 'always', false, false, 1),
  ('et-asi-pick', 'et-asi', 'asi', 'Ability Score Improvement or feat', 1, 2, 1, '{"points": 2, "allow_feat": true}', 'always', false, false, 1)
) x(id, fv, kind, label, mn, mx, lvl, cfg, app, repl, ft, ord)
on conflict (id) do update set feature_version_id = excluded.feature_version_id, kind = excluded.kind, label = excluded.label,
  min_picks = excluded.min_picks, max_picks = excluded.max_picks, level = excluded.level, config = excluded.config,
  applies_to = excluded.applies_to, replaceable = excluded.replaceable, allow_free_text = excluded.allow_free_text, sort_order = excluded.sort_order;

insert into public.class_feature_choice_options as t (choice_id, option_id, label, summary, option_group, prerequisites, sort_order)
select x.c, x.o, x.label, x.summary, x.grp, x.pre::jsonb, x.ord from (values
  ('et-style', 'archery', 'Archery', '+2 to attack rolls with ranged weapons.', 'Ranged', '{}', 1),
  ('et-style', 'defense', 'Defense', '+1 AC while you wear armor.', 'Defensive', '{}', 2),
  ('et-style', 'dueling', 'Dueling', '+2 damage with a melee weapon in one hand and no other weapon.', 'Melee', '{}', 3),
  ('et-style', 'protection', 'Protection', 'Reaction to protect an ally (reminder only).', 'Defensive', '{}', 4),
  ('et-style', 'heavy-stance', 'Heavy Stance', 'Needs STR 13. Reminder only.', 'Melee', '{"all": [{"type": "ability", "ability": "str", "min": 13}]}', 5),
  ('et-discipline-pick', 'elements', 'Elements', 'Choose an element: resistance to it.', null, '{}', 1),
  ('et-discipline-pick', 'body', 'Body', 'Endurance training (reminder only).', null, '{}', 2),
  ('et-techniques', 'feint', 'Feint', 'Reminder.', null, '{}', 1),
  ('et-techniques', 'parry', 'Parry', 'Reminder.', null, '{}', 2),
  ('et-techniques', 'riposte', 'Riposte', 'Reminder.', null, '{}', 3),
  ('et-techniques', 'forbidden-technique', 'Forbidden Technique', 'Needs DM permission (optional rule).', null,
     '{"all": [{"type": "text", "text": "DM permission (optional rule)"}]}', 4)
) x(c, o, label, summary, grp, pre, ord)
on conflict (choice_id, option_id) do update set label = excluded.label, summary = excluded.summary, option_group = excluded.option_group,
  prerequisites = excluded.prerequisites, sort_order = excluded.sort_order;

-- dependent sub-choice: only when the Elements discipline is chosen
insert into public.class_feature_choices as t (id, feature_version_id, kind, label, min_picks, max_picks, level, parent_choice_id,
  parent_option_id, sort_order)
values ('et-element', 'et-discipline', 'option', 'Element', 1, 1, 2, 'et-discipline-pick', 'elements', 2)
on conflict (id) do update set label = excluded.label, parent_choice_id = excluded.parent_choice_id, parent_option_id = excluded.parent_option_id,
  sort_order = excluded.sort_order;
insert into public.class_feature_choice_options as t (choice_id, option_id, label, summary, sort_order) values
  ('et-element', 'fire', 'Fire', 'Resistance to fire damage.', 1),
  ('et-element', 'cold', 'Cold', 'Resistance to cold damage.', 2),
  ('et-element', 'lightning', 'Lightning', 'Resistance to lightning damage.', 3)
on conflict (choice_id, option_id) do update set label = excluded.label, summary = excluded.summary, sort_order = excluded.sort_order;

-- ---- effects (proficiency, expertise, AC, attacks, spells, ...) -------------------------------------------------------------
insert into public.class_feature_effects as t (feature_version_id, seq, effect_type, target, value, value_text, spell_version_id, min_level,
  choice_id, option_choice_id, option_id, applies_to, conditions, automation, data)
select x.fv, x.seq, x.et, x.tg, x.val, x.vt, x.sp, x.lvl, x.ch, x.oc, x.oo, x.app, x.cond::jsonb, x.auto, x.data::jsonb from (values
  ('et-proficiencies', 1, 'proficiency', 'save', null::numeric, 'wis', null, 1, null, null, null, 'primary_class', '{}', 'automated', '{}'),
  ('et-proficiencies', 2, 'proficiency', 'save', null, 'con', null, 1, null, null, null, 'primary_class', '{}', 'automated', '{}'),
  ('et-proficiencies', 3, 'proficiency', 'group', null, 'light-armor', null, 1, null, null, null, 'always', '{}', 'automated', '{}'),
  ('et-proficiencies', 4, 'proficiency', 'group', null, 'medium-armor', null, 1, null, null, null, 'primary_class', '{}', 'automated', '{}'),
  ('et-proficiencies', 5, 'proficiency', 'group', null, 'shields', null, 1, null, null, null, 'always', '{}', 'automated', '{}'),
  ('et-proficiencies', 6, 'proficiency', 'group', null, 'simple-weapons', null, 1, null, null, null, 'always', '{}', 'automated', '{}'),
  ('et-proficiencies', 7, 'proficiency', 'group', null, 'martial-weapons', null, 1, null, null, null, 'primary_class', '{}', 'automated', '{}'),
  ('et-proficiencies', 8, 'proficiency', 'skill', null, null, null, 1, 'et-skills', null, null, 'always', '{}', 'automated', '{}'),
  ('et-proficiencies', 9, 'proficiency', 'skill', null, null, null, 1, 'et-skills-mc', null, null, 'always', '{}', 'automated', '{}'),
  ('et-fighting-style', 1, 'attack_bonus', null, 2, null, null, 1, null, 'et-style', 'archery', 'always', '{"weapon": "ranged"}', 'automated', '{}'),
  ('et-fighting-style', 2, 'ac_bonus', null, 1, null, null, 1, null, 'et-style', 'defense', 'always', '{"armor": "worn"}', 'automated', '{}'),
  ('et-fighting-style', 3, 'damage_bonus', null, 2, null, null, 1, null, 'et-style', 'dueling', 'always', '{"weapon": "one_handed_melee_only"}', 'automated', '{}'),
  ('et-fighting-style', 4, 'informational', null, null, 'Protection: impose disadvantage on an attack against an ally (reaction).', null, 1, null, 'et-style', 'protection', 'always', '{}', 'informational', '{}'),
  ('et-expertise', 1, 'expertise', 'skill', null, null, null, 1, 'et-expertise-pick', null, null, 'always', '{}', 'automated', '{}'),
  ('et-strike', 1, 'attack', null, null, null, null, 1, null, null, null, 'always', '{}', 'automated',
     '{"name": "Spirit Strike", "ability": "str", "dice_by_level": [[1, "1d6"], [5, "1d8"], [11, "1d10"]], "damage_type": "force", "range": "5 ft"}'),
  ('et-unarmored', 1, 'ac_formula', null, 10, null, null, 1, null, null, null, 'always', '{"armor": "none", "shield": "none"}', 'automated',
     '{"abilities": ["dex", "wis"]}'),
  ('et-optional-lore', 1, 'proficiency', 'language', null, 'elvish', null, 1, null, null, null, 'always', '{}', 'automated', '{}'),
  ('et-discipline', 1, 'resistance', 'fire', null, null, null, 2, null, 'et-element', 'fire', 'always', '{}', 'automated', '{}'),
  ('et-discipline', 2, 'resistance', 'cold', null, null, null, 2, null, 'et-element', 'cold', 'always', '{}', 'automated', '{}'),
  ('et-discipline', 3, 'resistance', 'lightning', null, null, null, 2, null, 'et-element', 'lightning', 'always', '{}', 'automated', '{}'),
  ('et-tactical-note', 1, 'skill_advantage', 'stealth', null, null, null, 2, null, null, null, 'always', '{}', 'informational', '{}'),
  ('et-keen-senses', 1, 'initiative_bonus', null, 1, null, null, 3, null, null, null, 'always', '{}', 'automated', '{}'),
  ('et-swift-reflexes', 1, 'initiative_bonus', null, 0, 'pb', null, 3, null, null, null, 'always', '{}', 'automated', '{}'),
  ('et-swift-reflexes', 2, 'speed_bonus', null, 5, null, null, 3, null, null, null, 'always', '{"armor": "not_heavy"}', 'automated', '{}'),
  ('et-insight', 1, 'spell', null, null, null, 'detect-magic-phb', 3, null, null, null, 'always', '{}', 'automated',
     '{"always_prepared": true, "ritual": true, "uses_spell_slots": true}'),
  ('et-insight', 2, 'spell', null, null, null, null, 3, 'et-cantrip', null, null, 'always', '{}', 'automated', '{"uses_spell_slots": false}'),
  ('et-asi', 1, 'ability_bonus', null, null, null, null, 1, 'et-asi-pick', null, null, 'always', '{}', 'automated', '{}'),
  ('et-extra-attack', 1, 'extra_attack', null, 1, null, null, 5, null, null, null, 'always', '{}', 'automated', '{}'),
  ('et-extra-attack', 2, 'extra_attack', null, 2, null, null, 11, null, null, null, 'always', '{}', 'automated', '{}'),
  ('et-advanced', 1, 'save_bonus', 'str', 1, null, null, 6, null, null, null, 'always', '{}', 'automated', '{}'),
  ('et-path-precision', 1, 'critical_range', null, 19, null, null, 3, null, null, null, 'always', '{}', 'automated', '{}'),
  ('et-path-training', 1, 'proficiency', 'group', null, 'heavy-armor', null, 3, null, null, null, 'always', '{}', 'automated', '{}'),
  ('et-path-spells', 1, 'spell', null, null, null, 'shield-phb', 3, null, null, null, 'always', '{}', 'automated',
     '{"always_prepared": true, "uses_spell_slots": true}')
) x(fv, seq, et, tg, val, vt, sp, lvl, ch, oc, oo, app, cond, auto, data)
on conflict (feature_version_id, seq) do update set effect_type = excluded.effect_type, target = excluded.target, value = excluded.value,
  value_text = excluded.value_text, spell_version_id = excluded.spell_version_id, min_level = excluded.min_level,
  choice_id = excluded.choice_id, option_choice_id = excluded.option_choice_id, option_id = excluded.option_id,
  applies_to = excluded.applies_to, conditions = excluded.conditions, automation = excluded.automation, data = excluded.data;

-- ---- resources ---------------------------------------------------------------------------------------------------------------
insert into public.class_feature_resources as t (id, feature_version_id, name, resource_type, max_formula, die, die_by_level, recharge,
  short_rest_recovery, min_level, automation, activation_note, sort_order)
select x.id, x.fv, x.name, x.rt, x.mf::jsonb, x.die, x.dbl::jsonb, x.rc, x.sr::jsonb, x.lvl, x.auto, x.note, x.ord from (values
  ('et-surge-uses', 'et-surge', 'Test Surge', 'uses', '{"fixed": 1}', null, null, 'short_or_long_rest', null, 1, 'automated', 'Bonus action', 1),
  ('et-inspiration-uses', 'et-inspiration', 'Test Inspiration', 'dice', '{"terms": [{"of": "ability", "ability": "cha"}], "minimum": 1}',
     'd6', '[[1, "d6"], [5, "d8"], [10, "d10"]]', 'long_rest', null, 1, 'automated', 'Bonus action', 2),
  ('et-burst-uses', 'et-burst', 'Test Burst', 'uses', '{"table": [[2, 1], [17, 2]]}', null, null, 'short_rest', null, 2, 'automated', null, 3),
  ('et-focus-points', 'et-focus', 'Test Focus Pool', 'points', '{"terms": [{"of": "class_level"}]}', null, null, 'long_rest', '{"fixed": 1}',
     2, 'automated', null, 4),
  ('et-reserve-uses', 'et-reserve', 'Test Reserve', 'uses', '{"terms": [{"of": "proficiency_bonus"}]}', null, null, 'long_rest', null, 3,
     'automated', null, 5),
  ('et-path-mastery-uses', 'et-path-mastery', 'Path Mastery', 'uses', '{"fixed": 2}', null, null, 'long_rest', null, 7, 'automated', null, 6)
) x(id, fv, name, rt, mf, die, dbl, rc, sr, lvl, auto, note, ord)
on conflict (id) do update set feature_version_id = excluded.feature_version_id, name = excluded.name, resource_type = excluded.resource_type,
  max_formula = excluded.max_formula, die = excluded.die, die_by_level = excluded.die_by_level, recharge = excluded.recharge,
  short_rest_recovery = excluded.short_rest_recovery, min_level = excluded.min_level, automation = excluded.automation,
  activation_note = excluded.activation_note, sort_order = excluded.sort_order;

-- ---- a second version of the test class (class version change review: different features, incompatible subclass) ----------
insert into public.class_versions as t (id, class_id, name, source_label, source_url, status, rules_edition, spellcasting_ability,
  preparation_mode, ritual_mode, caster_type, hit_die, rules_label, multiclass_contribution, implementation_status, limitations,
  content_scope, subclass_level, notes)
values ('engine-test-fixture-v2', 'engine-test', 'Engine Test Class v2 (test fixture)', 'Tavern Ledger test fixture (synthetic)',
  'https://example.invalid/tavern-ledger/engine-test-fixture-v2', 'current', '2014', 'wis', 'none', 'none', 'none', 'd10', 'Test fixture v2',
  'none', 'partial', '{"Synthetic test content for the class feature engine. Not an official class."}', 'test', 3,
  'Test fixture only: a second version for the version change review.')
on conflict (id) do update set name = excluded.name, hit_die = excluded.hit_die, rules_label = excluded.rules_label,
  limitations = excluded.limitations, content_scope = excluded.content_scope, subclass_level = excluded.subclass_level;
insert into public.class_feature_unlocks as t (id, class_version_id, level, feature_version_id, sort_order) values
  ('et-v2-u1-proficiencies', 'engine-test-fixture-v2', 1, 'et-proficiencies', 1),
  ('et-v2-u1-strike', 'engine-test-fixture-v2', 1, 'et-strike', 2),
  ('et-v2-u2-surge', 'engine-test-fixture-v2', 2, 'et-surge', 1)
on conflict (id) do update set class_version_id = excluded.class_version_id, level = excluded.level,
  feature_version_id = excluded.feature_version_id, sort_order = excluded.sort_order;

commit;
