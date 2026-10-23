-- =============================================================================
-- DM content lifecycle and hidden DM data (20261019000400 / 000500 / 000600; docs/CUSTOM_CONTENT_LIFECYCLE.md,
-- HIDDEN_DM_DATA.md, DM_SPACE.md): authoring rights, draft visibility, validation, publish, assignment, versions, archive,
-- custom spells / items (unidentified, curse, reveal) / feats / Wild Shape forms / companions / backgrounds / lineages /
-- conditions, hidden notes, content policy, usage, deletion rules, DM backup, read models, RLS.
-- Runs inside the per-class harness (alice = player, bob = outsider, dm = DM of :camp).
-- =============================================================================
\set w1 f1d00000-0000-0000-0000-000000000001
\set w2 f1d00000-0000-0000-0000-000000000002
\set w3 f1d00000-0000-0000-0000-000000000003
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'w1', :'alice', 'Content Wizard', :'camp', 1, 8, 14, 12, 16, 10, 10, 8, 8, 30),
  (:'w2', :'alice', 'Content Druid', :'camp', 1, 10, 12, 14, 10, 16, 10, 10, 10, 30),
  (:'w3', :'alice', 'Content Hero', :'camp', 1, 14, 12, 12, 10, 10, 10, 10, 10, 30);
create function tl_test.code(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
create function tl_test.ref(p_content uuid) returns text language sql security definer as $$
  select v.catalog_ref from public.dm_content c join public.dm_content_versions v on v.id = c.published_version_id where c.id = p_content $$;
create function tl_test.form_allowed(p_char uuid, p_creature text) returns boolean language sql security definer as $$
  select allowed from public._form_options(p_char) where creature_id = p_creature $$;
create function tl_test.cstatus(p_content uuid) returns text language sql security definer as $$ select status from public.dm_content where id = p_content $$;
grant all on all functions in schema tl_test to public;
select tl_test.as_user(:'alice');
select public.set_character_class(:'w1', 'wizard-phb', 1, null, true);
select public.set_character_class(:'w2', 'druid-phb', 2, null, true);

-- ---- authoring rights ----------------------------------------------------------------------------------------------------
select tl_test.rec('DC1 a player cannot create custom spells, items, feats, creatures, companions, backgrounds, lineages or conditions',
  (select bool_and(tl_test.code(format('select public.create_dm_content(%L, %L, %L)', t, :'camp', '{"name": "Player Thing"}')) = 'TLDMO')
   from unnest(array['spell', 'item', 'feat', 'creature', 'companion', 'background', 'lineage', 'condition']) t)
  and tl_test.code(format('select public.create_dm_content(%L, null, %L)', 'spell', '{"name": "Private Player Spell"}')) = 'TLDMO');
select tl_test.rec('DC2 nobody writes the registry directly',
  tl_test.code(format('insert into public.dm_content (content_type, author_id, campaign_id, name) values (%L, %L, %L, %L)', 'spell', :'alice', :'camp', 'x')) = '42501');
select tl_test.as_user(:'dm');
select (public.create_dm_content('spell', :'camp', '{"name": "Ember Lance", "summary": "A spear of embers.", "dm_notes": "Secret: it was taught by a fire giant."}',
        'b0000000-0000-0000-0000-000000000001') ->> 'id') as sp \gset
select tl_test.rec('DC3 the DM creates a campaign draft (idempotent request id), authored by the DM',
  tl_test.cstatus(:'sp') = 'draft'
  and (public.create_dm_content('spell', :'camp', '{"name": "Ember Lance"}', 'b0000000-0000-0000-0000-000000000001') ->> 'id') = :'sp'
  and exists (select 1 from jsonb_array_elements(public.get_dm_content_library(:'camp')) x where x ->> 'id' = :'sp'));
select tl_test.as_user(:'alice');
select tl_test.rec('DC4 a draft is invisible to players (registry and catalog)',
  not exists (select 1 from public.dm_content) and not exists (select 1 from public.dm_content_versions)
  and tl_test.code(format('select public.get_dm_content(%L)', :'sp')) = '42501');
select tl_test.as_user(:'dm');
select public.validate_dm_content(:'sp') -> 'validation' as v1 \gset
select tl_test.rec('DC5 validation explains what is missing', not (:'v1'::jsonb ->> 'ok')::boolean
  and tl_test.cstatus(:'sp') = 'validation_failed' and (:'v1'::jsonb -> 'errors') ? 'Choose the spell level (0 for a cantrip).');
select public.save_dm_content(:'sp', '{"definition": {"level": 1, "school": "evocation", "casting_time": {"unit": "action", "amount": 1},
  "range": {"type": "distance", "distance": 60, "unit": "feet"}, "duration": {"type": "instantaneous"}, "components": {"v": true, "s": true},
  "attack_type": "ranged", "effects": [{"category": "damage", "dice": "3d6", "damage_types": ["fire"], "scaling": {"type": "slot_level", "dice": "1d6"}}],
  "class_lists": ["wizard-spell-list"]}, "player_text": "A lance of embers streaks toward a creature."}');
select public.validate_dm_content(:'sp') -> 'validation' as v2 \gset
select tl_test.rec('DC6 a complete draft validates and previews as the spell card players will see',
  (:'v2'::jsonb ->> 'ok')::boolean and tl_test.cstatus(:'sp') = 'ready_for_review'
  and (public.preview_dm_content(:'sp') -> 'preview' ->> 'name') = 'Ember Lance'
  and not exists (select 1 from public.spell_versions where name = 'Ember Lance'));
select public.publish_dm_content(:'sp');
select tl_test.rec('DC7 publishing materializes the campaign spell exactly once', tl_test.cstatus(:'sp') = 'published'
  and tl_test.code(format('select public.publish_dm_content(%L)', :'sp')) = 'TLPUB'
  and (select count(*) from public.spell_versions where name = 'Ember Lance') = 1);
select tl_test.as_user(:'alice');
select tl_test.rec('DC8 campaign members see the published spell (and the class list entry); no DM notes anywhere',
  (public.get_spell_detail(tl_test.ref(:'sp')) ->> 'name') = 'Ember Lance'
  and exists (select 1 from public.class_spell_list_entries where spell_version_id = tl_test.ref(:'sp'))
  and position('fire giant' in public.get_spell_detail(tl_test.ref(:'sp'))::text) = 0);
select tl_test.as_user(:'bob');
select tl_test.rec('DC9 outsiders do not see campaign spells or their list entries',
  not exists (select 1 from public.spell_versions where name = 'Ember Lance')
  and not exists (select 1 from public.class_spell_list_entries where spell_version_id like 'cc-%'));
select tl_test.as_user(:'alice');
select tl_test.rec('DC10 a player cannot edit the published spell', tl_test.code(format('select public.save_dm_content(%L, %L)', :'sp', '{"name": "Hacked"}')) = '42501');
select tl_test.as_user(:'dm');
select tl_test.rec('DC11 a published version is never edited in place', tl_test.code(format('select public.save_dm_content(%L, %L)', :'sp', '{"name": "Changed"}')) = 'TLPUB');
select public.dm_assign_content(:'sp', array[:'w1']::uuid[], 'known',
  jsonb_build_object('source_id', (select id from public.character_spellcasting_sources where character_id = :'w1' and source_type = 'class'))) as asg \gset
select tl_test.rec('DC12 the DM assigns the exact version to the wizard; it appears with the campaign scope',
  (:'asg'::jsonb -> 'results' -> 0 ->> 'ok')::boolean
  and exists (select 1 from jsonb_array_elements(public.get_character_spellbook(:'w1') -> 'spells') s where s ->> 'id' = tl_test.ref(:'sp') and s ->> 'scope' = 'campaign'));
select tl_test.ref(:'sp') as sp_v1 \gset
select public.new_dm_content_version(:'sp');
select public.save_dm_content(:'sp', jsonb_build_object('definition', (select definition || '{"level": 2}' from public.dm_content_versions where content_id = :'sp' and version_no = 2)));
select public.publish_dm_content(:'sp');
select tl_test.rec('DC13 a new version gets a new catalog row; the old one is superseded but the wizard keeps it',
  tl_test.ref(:'sp') <> :'sp_v1' and (select level from public.spell_versions where id = tl_test.ref(:'sp')) = 2
  and (select archived_at is not null from public.spell_versions where id = :'sp_v1')
  and exists (select 1 from public.character_spells where character_id = :'w1' and spell_version_id = :'sp_v1'));
select public.archive_dm_content(:'sp', 'Retired');
select tl_test.rec('DC14 archived content cannot be assigned again; existing references stay',
  tl_test.code(format('select public.dm_assign_content(%L, %L, %L)', :'sp', array[:'w1'], 'known')) = 'TLPUB'
  and exists (select 1 from public.character_spells where character_id = :'w1' and spell_version_id = :'sp_v1')
  and tl_test.code(format('select public.delete_dm_content(%L)', :'sp')) = 'TLPUB');
select tl_test.as_user(:'alice');
select tl_test.rec('DC15 a player cannot learn an archived custom spell either',
  tl_test.code(format('select public.set_character_spell(%L, %L, %L)', :'w1',
    (select id from public.character_spellcasting_sources where character_id = :'w1' and source_type = 'class'), tl_test.ref(:'sp'))) = 'TLPUB');

-- ---- item with hidden properties ---------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select (public.create_dm_content('item', :'camp', '{"name": "Ring of the Ashen Oath", "summary": "A heavy iron ring.", "player_text": "An iron ring warm to the touch.",
  "definition": {"item": {"kind_id": "gear", "is_magic": true, "requires_attunement": true, "rarity_id": "rare", "weight_lb": 0.1},
                 "hidden": {"unidentified_name": "Heavy iron ring", "unidentified_description": "A plain, heavy iron ring.",
                            "curse": "Bound to the wearer: cannot remove it; disadvantage on Charisma checks.",
                            "properties": [{"key": "fire", "label": "Fire ward", "text": "Resistance to fire damage while attuned."}]}}}') ->> 'id') as it \gset
select public.publish_dm_content(:'it');
select tl_test.rec('DC16 publishing a hidden-property item stores its secrets for the DM only',
  exists (select 1 from public.item_secrets where item_id = tl_test.ref(:'it') and curse like 'Bound%'));
select public.dm_assign_content(:'it', array[:'w3']::uuid[], 'inventory', '{"identified": false}');
select tl_test.as_user(:'alice');
select tl_test.rec('DC17 the player sees only the disguise: no catalog row, no secrets, no true name',
  not exists (select 1 from public.items where id = tl_test.ref(:'it'))
  and not exists (select 1 from public.item_secrets)
  and exists (select 1 from public.v_inventory_detail where character_id = :'w3' and name = 'Heavy iron ring' and kind_id is null)
  and (public.get_character_item_knowledge(:'w3') -> 0 ->> 'state') = 'unidentified'
  and (public.get_character_item_knowledge(:'w3') -> 0 ->> 'curse') is null
  and (public.get_character_item_knowledge(:'w3') -> 0 ->> 'true_name') is null
  and position('Ashen' in public.get_character_item_knowledge(:'w3')::text) = 0
  and tl_test.code('select true_name from public.inventory_item_knowledge') = '42501');
select tl_test.rec('DC18 a player cannot identify the item', tl_test.code(format('select public.set_item_knowledge(%L, %L)',
  (select id from public.inventory_items where character_id = :'w3' and name = 'Heavy iron ring'), 'identified')) = '42501');
select tl_test.as_user(:'dm');
select public.set_item_knowledge((select id from public.inventory_items where character_id = :'w3' and name = 'Heavy iron ring'), 'partially_identified', array['magic', 'fire']);
select tl_test.as_user(:'alice');
select tl_test.rec('DC19 partial identification reveals the chosen property and the magic, never the curse',
  (public.get_character_item_knowledge(:'w3') -> 0 -> 'properties' -> 0 ->> 'label') = 'Fire ward'
  and (public.get_character_item_knowledge(:'w3') -> 0 -> 'facts' ->> 'magic')::boolean
  and (public.get_character_item_knowledge(:'w3') -> 0 ->> 'curse') is null);
select tl_test.as_user(:'dm');
select public.set_item_knowledge((select id from public.inventory_items where character_id = :'w3' and item_id = tl_test.ref(:'it')), 'identified', array['magic', 'fire']);
select tl_test.as_user(:'alice');
select tl_test.rec('DC20 identified: the player sees the item and its true name; the curse stays secret until revealed',
  exists (select 1 from public.items where id = tl_test.ref(:'it'))
  and exists (select 1 from public.inventory_items where character_id = :'w3' and name = 'Ring of the Ashen Oath')
  and (public.get_character_item_knowledge(:'w3') -> 0 ->> 'curse') is null
  and exists (select 1 from public.campaign_audit_events where character_id = :'w3' and event_type = 'item_revealed'));

-- ---- conditions and notes -----------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select (public.create_dm_content('condition', :'camp', '{"name": "Ashen Mark", "summary": "Smells of smoke.",
  "definition": {"category": "curse", "effects": [{"type": "check_disadvantage", "target": "cha"}]}}') ->> 'id') as cnd \gset
select public.publish_dm_content(:'cnd');
select public.dm_assign_content(:'cnd', array[:'w3']::uuid[], 'hidden', '{"note": "From the ring"}');
select public.save_dm_note(:'w3', 'Prophecy', 'The ring will betray them at the gate.', null, 'You dream of a burning gate.');
select tl_test.as_user(:'alice');
select tl_test.rec('DC21 hidden conditions and notes are not readable by the player (tables, read models, audit)',
  jsonb_array_length(public.get_character_conditions(:'w3')) = 0 and not exists (select 1 from public.character_conditions)
  and not exists (select 1 from public.dm_character_notes) and jsonb_array_length(public.get_character_revealed_notes(:'w3')) = 0
  and not exists (select 1 from public.campaign_audit_events where event_type in ('hidden_effect_added', 'hidden_note_added'))
  and tl_test.code(format('select public.get_dm_character_hidden(%L)', :'w3')) = '42501');
select tl_test.as_user(:'dm');
select tl_test.rec('DC22 the DM sees them', jsonb_array_length(public.get_dm_character_hidden(:'w3') -> 'notes') = 1
  and (public.get_character_conditions(:'w3') -> 0 ->> 'hidden')::boolean);
select public.reveal_character_condition((select id from public.character_conditions where character_id = :'w3'));
select public.reveal_dm_note((select id from public.dm_character_notes where character_id = :'w3'));
select tl_test.as_user(:'alice');
select tl_test.rec('DC23 revealed: the player sees the condition and the reveal text, never the DM body',
  (public.get_character_conditions(:'w3') -> 0 ->> 'name') = 'Ashen Mark'
  and (public.get_character_revealed_notes(:'w3') -> 0 ->> 'text') = 'You dream of a burning gate.'
  and (public.get_character_conditions(:'w3') -> 0 ->> 'dm_note') is null
  and exists (select 1 from public.campaign_audit_events where character_id = :'w3' and event_type = 'hidden_effect_revealed'));

-- ---- custom feat, creature, companion, background, lineage -----------------------------------------------------------------------
select tl_test.as_user(:'dm');
select (public.create_dm_content('feat', :'camp', '{"name": "Ashwalker", "summary": "+5 ft speed.", "ruleset": "2024",
  "definition": {"category": "general", "effects": [{"type": "speed_bonus", "value": 5, "label": "Ashwalker"}]}}') ->> 'id') as ft \gset
select public.publish_dm_content(:'ft');
select public.dm_assign_content(:'ft', array[:'w3']::uuid[], 'campaign_reward');
select tl_test.rec('DC24 a custom feat granted as a reward applies its effect (speed 30 -> 35)',
  (public.get_character_derived_stats(:'w3') -> 'speed' ->> 'value')::int = 35
  and (select source_type from public.character_feats where character_id = :'w3') = 'campaign_reward');
select (public.create_dm_content('creature', :'camp', '{"name": "Cinder Fox", "summary": "A fox with ember fur.",
  "definition": {"size": "Small", "creature_type": "beast", "armor_class": 13, "hit_points": 9, "hit_dice": "2d6+2", "speed": {"walk": 40},
                 "abilities": {"str": 8, "dex": 16, "con": 12, "int": 4, "wis": 12, "cha": 6}, "challenge_rating": 0.25, "skills": {"perception": 3},
                 "actions": [{"kind": "melee", "name": "Bite", "reach": 5, "damage": [{"dice": "1d6+3", "type": "piercing"}], "targets": "one target", "attack_bonus": 5}],
                 "wild_shape_eligible": true}}') ->> 'id') as cr \gset
select public.publish_dm_content(:'cr');
select tl_test.as_user(:'alice');
select tl_test.rec('DC25 a custom beast is not a Wild Shape option before a DM grant, and the player cannot self-grant it',
  tl_test.form_allowed(:'w2', tl_test.ref(:'cr')) is null
  and tl_test.code(format('select public.set_seen_forms(%L, array[%L])', :'w2', tl_test.ref(:'cr'))) = 'TLDMO'
  and tl_test.code(format('select public.add_character_companion(%L, %L)', :'w2', tl_test.ref(:'cr'))) = 'TLDMO');
select tl_test.as_user(:'dm');
select public.dm_assign_content(:'cr', array[:'w2']::uuid[], 'seen_form');
select tl_test.as_user(:'alice');
select tl_test.rec('DC26 after the DM grant the Druid can use it (Druid 2, CR 1/4, walking)',
  tl_test.form_allowed(:'w2', tl_test.ref(:'cr')));
select tl_test.as_user(:'dm');
select (public.create_dm_content('companion', :'camp', '{"name": "Ember Hound", "summary": "A loyal hound.", "dm_notes": "Spy of the fire cult.",
  "definition": {"creature": {"size": "Medium", "creature_type": "beast", "armor_class": 14, "hit_points": 15, "speed": {"walk": 40},
                 "abilities": {"str": 14, "dex": 14, "con": 13, "int": 3, "wis": 12, "cha": 6}, "challenge_rating": 0.5},
                 "hp_formula": {"base": 15, "per_level": 2}, "rules": "Acts on your initiative.", "hidden": {"loyalty": "Reports to the cult."}}}') ->> 'id') as cp \gset
select public.publish_dm_content(:'cp');
select public.dm_assign_content(:'cp', array[:'w3']::uuid[], 'companion', '{"name": "Smoke"}');
select tl_test.as_user(:'alice');
select tl_test.rec('DC27 a companion template creates a companion instance; the player reads its public info only',
  exists (select 1 from public.character_companions where character_id = :'w3' and name = 'Smoke' and template_version_id is not null)
  and (public.get_content_public_info((select template_version_id from public.character_companions where character_id = :'w3')) -> 'definition' ->> 'rules') = 'Acts on your initiative.'
  and position('cult' in public.get_content_public_info((select template_version_id from public.character_companions where character_id = :'w3'))::text) = 0);
select tl_test.as_user(:'dm');
select (public.create_dm_content('background', :'camp', '{"name": "Ash Pilgrim", "ruleset": "2024", "summary": "Walked the burning road.",
  "definition": {"abilities": ["str", "con", "wis"], "feat": "alert-2024", "skills": ["athletics", "survival"], "tools": ["dice-set"], "gold": 50}}') ->> 'id') as bg \gset
select public.publish_dm_content(:'bg');
select (public.create_dm_content('lineage', :'camp', '{"name": "Emberkin", "summary": "Children of the ash.",
  "definition": {"traits": [{"name": "Darkvision", "summary": "60 feet.", "effects": [{"type": "sense", "target": "darkvision", "value": 60}]},
                            {"name": "Fire Resistance", "summary": "Resistance to fire.", "effects": [{"type": "resistance", "target": "fire"}]}]}}') ->> 'id') as ln \gset
select public.publish_dm_content(:'ln');
select public.dm_assign_content(:'bg', array[:'w3']::uuid[], 'direct', '{"ability": {"mode": "plus1_x3", "allocation": {"str": 1, "con": 1, "wis": 1}}}') as bgasg \gset
select public.dm_assign_content(:'ln', array[:'w3']::uuid[], 'direct') as lnasg \gset
select tl_test.rec('DC28 a custom 2024 background (with its Origin feat) and a custom lineage apply to the character',
  (:'bgasg'::jsonb -> 'results' -> 0 ->> 'ok')::boolean and (:'lnasg'::jsonb -> 'results' -> 0 ->> 'ok')::boolean
  and (public.get_character_derived_stats(:'w3') -> 'background' ->> 'name') = 'Ash Pilgrim'
  and exists (select 1 from jsonb_array_elements(public.get_character_feats(:'w3') -> 'feats') f where f -> 'feat' ->> 'id' = 'alert-2024')
  and coalesce((public.get_character_derived_stats(:'w3') -> 'senses' -> 'darkvision' ->> 'value')::int, 0) = 60);
select tl_test.rec('DC29 a 2014 background with ability increases is refused by validation',
  (select (public.validate_dm_content((public.create_dm_content('background', :'camp', '{"name": "Wrong", "ruleset": "2014", "definition": {"abilities": ["str"]}}') ->> 'id')::uuid)
    -> 'validation' ->> 'ok')::boolean) = false);

-- ---- usage, deletion, private library, policy -------------------------------------------------------------------------------------
select tl_test.rec('DC30 usage review counts the characters that use a content item',
  (public.get_dm_content(:'ft') -> 'usage' ->> 'characters')::int = 1);
select (public.create_dm_content('spell', :'camp', '{"name": "Unused Draft"}') ->> 'id') as ud \gset
select tl_test.rec('DC31 an unused draft can be deleted by its author', tl_test.code(format('select public.delete_dm_content(%L)', :'ud')) = 'ok');
select (public.create_dm_content('item', null, '{"name": "Library Lantern", "definition": {"item": {"kind_id": "gear"}}}') ->> 'id') as lib \gset
select tl_test.rec('DC32 private library content is copied to a campaign before publishing',
  tl_test.code(format('select public.publish_dm_content(%L)', :'lib')) = '22023'
  and (select (public.duplicate_dm_content(:'lib', :'camp') ->> 'campaign_id')::uuid) = :'camp'::uuid);
select public.set_campaign_governance(:'camp', '{"content": {"allow_custom": false}}');
select tl_test.as_user(:'alice');
select tl_test.rec('DC33 the content policy filters new player picks of campaign content (custom off)',
  tl_test.code(format('select public.add_inventory_item(%L, %L)', (select id from public.inventories where character_id = :'w1' limit 1), tl_test.ref(:'it'))) in ('TLDIS', '42501'));
select tl_test.as_user(:'dm');
select public.set_campaign_governance(:'camp', '{"content": {"allow_custom": true}}');

-- ---- read models and backup -----------------------------------------------------------------------------------------------------
select tl_test.rec('DC34 the DM overview and party read models list the campaign and its characters',
  (public.get_dm_overview(:'camp') -> 'counts' ->> 'characters')::int >= 3
  and exists (select 1 from jsonb_array_elements(public.get_dm_party(:'camp') -> 'characters') p where p ->> 'name' = 'Content Hero' and (p ->> 'hidden_notes')::int = 0)
  and exists (select 1 from jsonb_array_elements(public.get_my_dm_campaigns()) c where (c ->> 'id')::uuid = :'camp'::uuid));
select tl_test.rec('DC35 the DM backup holds hidden data and the content registry',
  position('burning gate' in public.export_campaign_dm_backup(:'camp')::text) > 0
  and jsonb_array_length(public.export_campaign_dm_backup(:'camp') -> 'content') >= 6);
select tl_test.as_user(:'alice');
select tl_test.rec('DC36 players cannot open DM read models or the backup',
  tl_test.code(format('select public.get_dm_party(%L)', :'camp')) = '42501' and tl_test.code(format('select public.get_dm_overview(%L)', :'camp')) = '42501'
  and tl_test.code(format('select public.export_campaign_dm_backup(%L)', :'camp')) = '42501'
  and jsonb_array_length(public.get_my_dm_campaigns()) = 0);
select tl_test.as_root();
select tl_test.rec('DC37 no orphan content: every content has a current version of its own',
  not exists (select 1 from public.dm_content c where c.current_version_id is null
              or not exists (select 1 from public.dm_content_versions v where v.id = c.current_version_id and v.content_id = c.id)));
