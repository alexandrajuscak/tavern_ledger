-- Timing of selectable class options (docs/ACTIVE_CLASS_FEATURE_AUDIT.md, docs/ACTIVE_CLASS_FEATURE_PRESENTATION.md).
-- Rollback: supabase/rollback/rollback_class_option_activation.sql.
--
-- A targeted, idempotent, version-aware catalog patch: no catalog re-import, no new row, no character data. It adds two keys
-- to class_feature_choice_options.data of NAMED options only (feature version + option id), taken from the option's own
-- rules text, so the Play page can place a selected option without parsing text in the browser:
--   activation: action | bonus_action | reaction | special (used during play outside the action types: when you hit, when
--               you cast, on a check) | passive (always on) | spell (adds a spell or a free cast; shown in Spells) |
--               item (bound to an item: Artificer infusions; shown on the item in Inventory)
--   play:       'reminder' on a passive option that matters in combat (shown under "Passive and reminders" in Play).
-- automation is NOT changed: an option stays "informational" (a reminder) unless it already was automated.
-- Existing character choices are untouched; the catalog trigger tl_cache_rev bumps the global read-cache revision, so cached
-- class-feature reads are rebuilt with the new keys. Options that are not listed (Favored Enemy, Natural Explorer, Dragon
-- Ancestor, test classes) keep no timing and stay on the Build page.

with m (feature_version_id, option_id, activation, play) as (values
  -- Fighting Style (fighter, champion's additional style, paladin, ranger) and Battle Master maneuvers (Superior Technique)
  ('*style', 'archery', 'passive', 'reminder'), ('*style', 'defense', 'passive', null), ('*style', 'dueling', 'passive', 'reminder'),
  ('*style', 'blind-fighting', 'passive', 'reminder'), ('*style', 'great-weapon-fighting', 'passive', 'reminder'),
  ('*style', 'two-weapon-fighting', 'passive', 'reminder'), ('*style', 'thrown-weapon-fighting', 'passive', 'reminder'),
  ('*style', 'unarmed-fighting', 'passive', 'reminder'), ('*style', 'close-quarters-shooter', 'passive', 'reminder'),
  ('*style', 'mariner', 'passive', null), ('*style', 'interception', 'reaction', null), ('*style', 'protection', 'reaction', null),
  ('*style', 'tunnel-fighter', 'bonus_action', null), ('*style', 'superior-technique', 'passive', null),
  ('*style', 'blessed-warrior', 'spell', null), ('*style', 'druidic-warrior', 'spell', null),
  ('*style', 'ambush', 'special', null), ('*style', 'bait-and-switch', 'special', null), ('*style', 'brace', 'reaction', null),
  ('*style', 'commanders-strike', 'special', null), ('*style', 'commanding-presence', 'special', null),
  ('*style', 'disarming-attack', 'special', null), ('*style', 'distracting-strike', 'special', null),
  ('*style', 'evasive-footwork', 'special', null), ('*style', 'feinting-attack', 'bonus_action', null),
  ('*style', 'goading-attack', 'special', null), ('*style', 'grappling-strike', 'bonus_action', null),
  ('*style', 'lunging-attack', 'special', null), ('*style', 'maneuvering-attack', 'special', null),
  ('*style', 'menacing-attack', 'special', null), ('*style', 'parry', 'reaction', null), ('*style', 'precision-attack', 'special', null),
  ('*style', 'pushing-attack', 'special', null), ('*style', 'quick-toss', 'bonus_action', null), ('*style', 'rally', 'bonus_action', null),
  ('*style', 'riposte', 'reaction', null), ('*style', 'sweeping-attack', 'special', null), ('*style', 'tactical-assessment', 'special', null),
  ('*style', 'trip-attack', 'special', null),
  -- Hunter (ranger)
  ('ranger-hunter-hunters-prey-phb', 'colossus-slayer', 'special', null), ('ranger-hunter-hunters-prey-phb', 'giant-killer', 'reaction', null),
  ('ranger-hunter-hunters-prey-phb', 'horde-breaker', 'special', null),
  ('ranger-hunter-defensive-tactics-phb', 'escape-the-horde', 'passive', 'reminder'), ('ranger-hunter-defensive-tactics-phb', 'multiattack-defense', 'passive', 'reminder'),
  ('ranger-hunter-defensive-tactics-phb', 'steel-will', 'passive', 'reminder'),
  ('ranger-hunter-multiattack-phb', 'volley', 'action', null), ('ranger-hunter-multiattack-phb', 'whirlwind-attack', 'action', null),
  ('ranger-hunter-superior-hunters-defense-phb', 'evasion', 'passive', 'reminder'),
  ('ranger-hunter-superior-hunters-defense-phb', 'stand-against-the-tide', 'reaction', null),
  ('ranger-hunter-superior-hunters-defense-phb', 'uncanny-dodge', 'reaction', null),
  -- Metamagic: used while casting a spell
  ('sorcerer-metamagic-phb', '*', 'special', null),
  -- Pact Boon
  ('warlock-pact-boon-phb', 'pact-of-the-blade', 'action', null), ('warlock-pact-boon-phb', 'pact-of-the-chain', 'spell', null),
  ('warlock-pact-boon-phb', 'pact-of-the-tome', 'spell', null), ('warlock-pact-boon-phb', 'pact-of-the-talisman', 'special', null),
  ('warlock-pact-boon-phb', 'pact-of-the-star-chain', 'spell', null),
  -- Fiendish Resilience: a chosen resistance
  ('warlock-fiend-fiendish-resilience-phb', '*', 'passive', 'reminder'),
  -- Eldritch Invocations
  ('warlock-eldritch-invocations-phb', 'agonizing-blast', 'special', null), ('warlock-eldritch-invocations-phb', 'eldritch-spear', 'special', null),
  ('warlock-eldritch-invocations-phb', 'grasp-of-hadar', 'special', null), ('warlock-eldritch-invocations-phb', 'lance-of-lethargy', 'special', null),
  ('warlock-eldritch-invocations-phb', 'repelling-blast', 'special', null), ('warlock-eldritch-invocations-phb', 'eldritch-smite', 'special', null),
  ('warlock-eldritch-invocations-phb', 'lifedrinker', 'special', null), ('warlock-eldritch-invocations-phb', 'thirsting-blade', 'special', null),
  ('warlock-eldritch-invocations-phb', 'improved-pact-weapon', 'special', null), ('warlock-eldritch-invocations-phb', 'protection-of-the-talisman', 'special', null),
  ('warlock-eldritch-invocations-phb', 'gift-of-the-protectors', 'special', null),
  ('warlock-eldritch-invocations-phb', 'bond-of-the-talisman', 'action', null), ('warlock-eldritch-invocations-phb', 'gaze-of-two-minds', 'action', null),
  ('warlock-eldritch-invocations-phb', 'ghostly-gaze', 'action', null), ('warlock-eldritch-invocations-phb', 'one-with-shadows', 'action', null),
  ('warlock-eldritch-invocations-phb', 'cloak-of-flies', 'bonus_action', null), ('warlock-eldritch-invocations-phb', 'maddening-hex', 'bonus_action', null),
  ('warlock-eldritch-invocations-phb', 'relentless-hex', 'bonus_action', null),
  ('warlock-eldritch-invocations-phb', 'rebuke-of-the-talisman', 'reaction', null), ('warlock-eldritch-invocations-phb', 'tomb-of-levistus', 'reaction', null),
  ('warlock-eldritch-invocations-phb', 'armor-of-shadows', 'spell', null), ('warlock-eldritch-invocations-phb', 'ascendant-step', 'spell', null),
  ('warlock-eldritch-invocations-phb', 'beast-speech', 'spell', null), ('warlock-eldritch-invocations-phb', 'bewitching-whispers', 'spell', null),
  ('warlock-eldritch-invocations-phb', 'chains-of-carceri', 'spell', null), ('warlock-eldritch-invocations-phb', 'dreadful-word', 'spell', null),
  ('warlock-eldritch-invocations-phb', 'eldritch-sight', 'spell', null), ('warlock-eldritch-invocations-phb', 'fiendish-vigor', 'spell', null),
  ('warlock-eldritch-invocations-phb', 'gift-of-the-depths', 'spell', null), ('warlock-eldritch-invocations-phb', 'mask-of-many-faces', 'spell', null),
  ('warlock-eldritch-invocations-phb', 'master-of-myriad-forms', 'spell', null), ('warlock-eldritch-invocations-phb', 'minions-of-chaos', 'spell', null),
  ('warlock-eldritch-invocations-phb', 'mire-the-mind', 'spell', null), ('warlock-eldritch-invocations-phb', 'misty-visions', 'spell', null),
  ('warlock-eldritch-invocations-phb', 'otherworldly-leap', 'spell', null), ('warlock-eldritch-invocations-phb', 'sculptor-of-flesh', 'spell', null),
  ('warlock-eldritch-invocations-phb', 'shroud-of-shadow', 'spell', null), ('warlock-eldritch-invocations-phb', 'sign-of-ill-omen', 'spell', null),
  ('warlock-eldritch-invocations-phb', 'thief-of-five-fates', 'spell', null), ('warlock-eldritch-invocations-phb', 'tricksters-escape', 'spell', null),
  ('warlock-eldritch-invocations-phb', 'undying-servitude', 'spell', null), ('warlock-eldritch-invocations-phb', 'visions-of-distant-realms', 'spell', null),
  ('warlock-eldritch-invocations-phb', 'whispers-of-the-grave', 'spell', null), ('warlock-eldritch-invocations-phb', 'far-scribe', 'spell', null),
  ('warlock-eldritch-invocations-phb', 'book-of-ancient-secrets', 'spell', null),
  ('warlock-eldritch-invocations-phb', 'devils-sight', 'passive', 'reminder'), ('warlock-eldritch-invocations-phb', 'eldritch-mind', 'passive', 'reminder'),
  ('warlock-eldritch-invocations-phb', 'witch-sight', 'passive', 'reminder'), ('warlock-eldritch-invocations-phb', 'aspect-of-the-moon', 'passive', null),
  ('warlock-eldritch-invocations-phb', 'beguiling-influence', 'passive', null), ('warlock-eldritch-invocations-phb', 'eyes-of-the-rune-keeper', 'passive', null),
  ('warlock-eldritch-invocations-phb', 'gift-of-the-ever-living-ones', 'passive', null),
  ('warlock-eldritch-invocations-phb', 'investment-of-the-chain-master', 'passive', null), ('warlock-eldritch-invocations-phb', 'voice-of-the-chain-master', 'passive', null),
  -- Artificer infusions: bound to an item (shown on the item and, when it adds something to do, in Play)
  ('artificer-infuse-item-tce', '*', 'item', null)
),
styles (fv) as (values ('fighter-fighting-style-phb'), ('fighter-champion-additional-fighting-style-phb'), ('paladin-fighting-style-phb'), ('ranger-fighting-style-phb')),
target as (
  select o.choice_id, o.option_id, m.activation, m.play
  from public.class_feature_choice_options o
  join public.class_feature_choices c on c.id = o.choice_id
  join m on (m.feature_version_id = c.feature_version_id or (m.feature_version_id = '*style' and c.feature_version_id in (select fv from styles)))
        and (m.option_id = o.option_id or m.option_id = '*')
  where c.kind = 'option'
)
update public.class_feature_choice_options o
set data = o.data || jsonb_strip_nulls(jsonb_build_object('activation', t.activation, 'play', t.play))
from target t
where o.choice_id = t.choice_id and o.option_id = t.option_id
  and (o.data ->> 'activation' is distinct from t.activation or o.data ->> 'play' is distinct from t.play);
