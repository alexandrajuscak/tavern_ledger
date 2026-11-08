# Active class features in Play (2026-11-07)

Play answers "what can this character do during a turn or during active gameplay?". Build stays the place where choices are
made; Play shows what those choices let you do. Wild Shape keeps its dedicated panel (the quality reference). Audit and
per-feature placement: `docs/ACTIVE_CLASS_FEATURE_AUDIT.md`.

## Sections of Play

| Section | Content |
|---|---|
| Ready to use | states (Rage …), feature DCs, limited-use counters with Use buttons and rest recovery (existing) |
| Wild Shape | dedicated panel (existing) |
| Attacks | weapons, feature attacks, attack riders (Eldritch Smite, Divine Smite …) |
| Actions / Bonus actions / Reactions / Free and special | class features with that `activation` (existing) **plus selected options with that timing** (new): Pact of the Blade, Volley, Cloak of Flies, Parry, Riposte, Interception, Metamagic options, maneuvers that trigger on a hit … |
| Passive and reminders | the existing passive notes **plus** combat-relevant passive options (`play: reminder`): Devil's Sight, Eldritch Mind, Archery, Dueling, Great Weapon Fighting, Evasion, Steel Will, the Fiendish Resilience resistance … |
| Infused items (new) | each active Artificer infusion: name, "Artificer Infusion · on <item>", attunement state, its text; changes stay on Build |
| Spells > From your class options (new) | option casts that are not automated (Bewitching Whispers, Sign of Ill Omen, Pact of the Tome / Chain …); automated at-will casts already appear as granted spells, so they are not repeated |
| Inventory | "Infused: <name>" badge on the target item (raw modifier id hidden) |

## Card anatomy (one shared model, `js/active-features.js`)

Name · class and feature (source) · sorcery-point cost for Metamagic · automation tag (`automatic`, `partly automatic`,
`reminder`) · concise effect (the option's catalog summary) · uses of the option's own counter when it has one. Full rules
text stays on Build. No Use button is invented for a reminder; counters keep their existing Use buttons in Ready to use.

## Data and loading

- Timing comes from the catalog: `class_feature_choice_options.data.activation` (migration `20261107000400`, idempotent,
  rollback removes the keys). Values: action, bonus_action, reaction, special, passive, spell, item; `play: reminder` marks a
  combat passive.
- No new request: the model is built from reads Play already has (`get_character_class_features` with option `data`,
  `get_character_resources`, `get_character_infusions`). The progressive / fluent path and the legacy path both supply them.
- Invalidation: the existing revision triggers on class choices, levels, resources, infusions and inventory re-render Play,
  Spells and Inventory; the catalog patch bumps the global read-cache revision once. Cosmetic changes (item icons, coins,
  biography) do not touch these reads.
- Combat Builder: the character detail keeps using the summary read; active options are a sheet feature (not repeated in
  the tracker).
