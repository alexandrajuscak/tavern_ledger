# UX and information architecture audit (2026-10-22)

The audit was done on the running local app (local Supabase plus the test frontend on `127.0.0.1:5191`). I signed in as
`local-player@example.test` and `local-dm@example.test` and opened the demo and Showcase characters. Widths: 1366 px
(laptop), 1920 px, 820 px (tablet) and 390 px (mobile). I also tried keyboard-only use. Screenshots of the "before"
state are in the task scratchpad. They are not committed, because they contain only local demo data. Probe script:
`probe.py`.

Severity levels: **blocker**, **serious**, **moderate**, **polish**, **future**. Audience: **P** player, **DM**, **B** both.

## Summary of the main problems

1. **Typography.** Cinzel, an all-caps Roman display face, sets the character name, every card heading (`h3`), the
   ability modifiers, the HP, AC, initiative, speed and proficiency numbers, the counters, the modal titles and the
   campaign names on the home page. That is 30 rules in `css/styles.css`. Cinzel has no lowercase, so each heading reads
   as small caps. Its old-style numerals make `+0` / `+6` / `19` look ornamental. Long names wrap on the home cards
   ("LOCAL FEATURE / TESTER").
2. **The structure follows the data model, not the player's tasks.**
   - The Bio tab mixes identity text fields, the class engine (levels, multiclass, Remove), the lineage engine, the
     background engine, the manual pending-choices list, the portrait, export and Delete.
   - Features mixes feats, class features, Wild Shape, infusions, companions and six free-text note lists.
   - Resources is its own tab, but Combat already shows the same resources.
   - Eight primary tabs.
3. **Everything has equal weight.** Every section is a bordered card with a gold small-caps title. Empty states
   ("No bonus actions yet. Set a feature's type to…") are as loud as real content. On Combat, 5 of 8 sections can be
   empty explanations for a typical character.
4. **Mobile navigation.** The tab bar scrolls sideways and cuts the 5th tab off at 390 px ("Fea…"). Most tabs are
   off-screen, and nothing tells you more tabs exist.
5. **Emoji as icons.** ⚔ 🛡 ☾ ☀ ✎ 🗑 ⬇ ⚠ 🎉 and the DM content type emoji (✨ 🗝 🏅 🐾 …) look different on every
   platform. Some are unlabelled (✎ has an aria-label, the decorative ones do not).
6. **Implementation language reaches the player.** Examples:
   - "Class and Spellcasting Foundation", "What this foundation does and does not do"
   - "Free-text spells and manual slots: the old spell list"
   - "Class feature: Paladin: Oath Spells"
   - "Automatic / Partly automatic / Reference only: the feat's rules are not applied automatically yet"
   - "Every action is set one by one" (DM Space preset `custom`)
   - "2014 (Player's Handbook)" next to every class.

## Findings

| # | Screen | User goal | Current experience | Problem | Severity | Proposed direction | Aud. |
|---|---|---|---|---|---|---|---|
| A1 | Global typography | Read quickly | Cinzel caps on headings and every number | Hard to read, ornamental numbers, long names wrap | serious | Inter for all UI and numbers (tabular figures). A display serif (Alegreya) only for the logo, page titles and the character name | B |
| A2 | Global | Know where you are | 8 tabs, no icons, same gold underline | Too many top-level destinations; the tab order doesn't match frequency of use | serious | 6 sections: **Play · Abilities · Spells · Inventory · Build · Bio**, with icons | P |
| A3 | Mobile nav | Switch section with one hand | Sideways-scrolling tab strip at the top, cut off | Hidden tabs, far from the thumb | serious | Fixed bottom navigation with 6 icon + label buttons at ≤ 700 px | P |
| A4 | Fonts / network | Local-only app | Google Fonts CSS and font files load from the internet | External dependency, flash of fallback font | moderate | Self-host Inter and Alegreya (OFL) under `fonts/` | B |
| A5 | Icons | Scan categories | Emoji and Unicode glyphs | Inconsistent, platform-dependent, partly unlabelled | moderate | One illustrated icon family (the user's curated set), always paired with text or an accessible name | B |
| H1 | Home | Find my character | 34 identical cards grouped by campaign, no search | Long page; the class is hidden in small grey text; the level is in a gold Cinzel circle | serious | Compact cards with a class emblem, a readable name, "Paladin 6 · Human", an HP bar using the **effective** max HP, AC, state badges (Wild Shape, locked, pending request); a search box when there are more than 6 characters | P |
| H2 | Home | See true HP | Cards show `hp_current/hp_max` (base max) | A feat HP bonus (Tough) isn't included, so the card disagrees with the sheet | serious | Use the server's derived max HP (`get_character_derived_stats().hit_points`) on the cards. Loaded in the background, with the base value as a placeholder | P |
| H3 | Home | Know what needs attention | No indicator of a pending request, lock or active Wild Shape | You must open each sheet | moderate | Status badges on cards from cheap batched reads (governance, open requests, active transformations) | B |
| S1 | Sheet header | Recognise the character | Large Cinzel name and three big buttons (Level Up, Short Rest, Long Rest). "Requests" floats alone on a second row | Level Up is a permanent build action, but it gets the strongest gold button on every tab, even when the character is locked | serious | Compact header: emblem or portrait, name, "Class level · Lineage", chips (campaign, lock, pending, Wild Shape). Rest is the only header action. Level Up moves to Build, next to the classes, and is disabled with a reason or replaced by "Ask your DM" when locked | P |
| S2 | Vitals bar | HP, AC at a glance | Large HP card, 4 tall tiles, AC "shield" shape, resource strip. About 300 px tall before any content | Pushes the tab content below the fold on a laptop; the tiles repeat on every tab | serious | One compact vitals row: HP with Damage/Heal, AC, Initiative, Speed, Proficiency, conditions and resource chips. Collapsible | P |
| S3 | Combat | Find attacks | Attacks are spread over "Equipped weapons", "From your class features", "Attacks", "Add a weapon", and Actions / Bonus / Reactions | Hard to see "what can I do now"; empty groups explain the data model ("Set a feature's type to…") | serious | **Play** tab: Active effects (Wild Shape, Rage), Resources, Attacks (weapons + feature attacks + manual), then Actions / Bonus actions / Reactions, which come from **catalog class features** plus manual entries. Calm one-line empty states. Turn guide and notes at the bottom | P |
| S4 | Combat | Use a bonus action | Catalog class features (Rage, Second Wind, Cunning Action, Healing Word…) are missing from Bonus Action / Reaction | Only free-text features and free-text spells were grouped | serious | Group catalog class features by their structured activation and prepared catalog spells by casting time | P |
| S5 | Resources tab | Spend a resource | A separate tab duplicates the strip; "Add a resource" is the dominant control | Gameplay resources live away from Play | moderate | Resources section in Play; adding a custom tracker becomes a quiet secondary action | P |
| S6 | Stats | Read a modifier | Gold Cinzel modifiers, a legend line, a proficiency card with the source-badge legend always visible | Visually busy; the legend repeats on every visit | moderate | Inter tabular numbers, clearer proficient/expertise markers (text + shape), legend inside "How does this work?" | P |
| S7 | Spells | Cast a spell | Spellcasting sources, then slots, then "Your spells". Sources show internals (Edit source, "How it is calculated", "Class feature" source) | Active play is pushed below management. School colours are good | serious | Order: spellcasting summary strip (DC / attack per source) → slots → **Ready to cast**. Source management behind "Manage spellcasting". School icon on every card | P |
| S8 | Spells | Read a spell card | "Always prepared" badge, school chip, "Slot 1st+", source "Class feature: Paladin: Oath Spells", "Known" | Five badges compete; the source text is technical | moderate | Compact card: school icon + name + level, one status chip, casting time · range · duration, damage chips; source and version behind expansion; friendly source ("Oath of Devotion") | P |
| S9 | Inventory | Equip | 13 equipment slots listed first, each with an "Equip" button, mostly "Empty" | The empty slots dominate; the items list duplicates equipped items | moderate | Equipped summary first (only filled slots, empty slots folded), carried items with category icons | P |
| S10 | Features | Understand my class | Feats card, then the class card ("Next actions", "At a glance", the level list), Companions, then 6 empty free-text lists | Wall of panels; the free-text lists ("Racial Features: None yet." ×6) look broken | serious | **Build** tab: Next steps (open choices, Level Up, requests), Classes, Class features (current level open, earlier levels folded), Lineage, Background, Feats, infusions; free-text notes folded at the bottom | P |
| S11 | Bio | Edit my portrait / notes | Bio holds the class engine, lineage, background and the manual pending choices; Notes is a separate tab | Permanent build choices are buried in "Bio"; notes are split | serious | **Bio**: identity, portrait, notes (character / session / campaign), export, delete. Legacy free-text class/background fields are folded when catalog data exists | P |
| S12 | Wild Shape | Play in beast form | Active form panel inside Combat; the normal HP card on top still shows the normal HP, and form HP is further down | Two HP displays with similar weight; form HP is the one you change | serious | While transformed the header shows a "Wild Shape: Brown Bear" chip; the vitals HP block shows the **form** HP with Damage/Heal and a "Normal HP 45/45 protected" line; Revert stays in the panel and the chip | P |
| S13 | Governance | Know what I can change | `gov-bar`, a "Requests" link at the top right | Floating link without context; no visible lock state in the header | moderate | Lock / pending chips in the header; the request tray link reads "Requests (n)" next to them | P |
| S14 | Empty states | Know nothing is wrong | Italic grey "None yet." / "No … yet. Set a feature's type to …" | Read as errors or instructions about the data model | moderate | One empty-state pattern: a short sentence plus the correct allowed action | B |
| S15 | Loading | Know it's loading | Spinner in the middle; panels pop in later (inventory "Loading inventory…") | Layout jumps | polish | Skeleton blocks for the sheet and the inventory | B |
| D1 | DM Overview | See what needs me | 6 equal number tiles (mostly 0), 4 equal cards | No priority; zeros carry the same weight as work | serious | A "Needs you" list first (pending approvals, failed applies, incomplete characters), then a party snapshot; zero counters hidden or quiet | DM |
| D2 | DM Content | Create content | Filter chips with emoji, a search field and 8 "New …" buttons at the same level | Too many equal actions | moderate | One "Create content" menu; type filter with icons; lifecycle chips Draft / Needs validation / Published / Archived | DM |
| D3 | DM header | Know the campaign | "Every action is set one by one." | Internal preset wording | moderate | "Custom rules: each action set individually" | DM |
| D4 | DM mobile | Navigate | Section select instead of tabs | Works; consistent with the player bottom nav? Different pattern | polish | Keep the select, restyled with an icon | DM |
| M1 | Modals | Confirm a change | Gold Cinzel titles; button order differs between dialogs | Inconsistent primary placement | moderate | Shared modal styles: Inter title, primary action on the right (bottom on mobile), sticky action bar | B |
| M2 | Buttons | Choose the right action | `btn-gold` is used for Level Up, + Add spell, + Add item, Upload image, + Add class, Choose… | Too many primaries per screen | moderate | One primary per context; others secondary or quiet | B |
| X1 | Keyboard | Use without a mouse | Focus ring = gold border on inputs only; buttons use the browser default | Uneven focus visibility | moderate | Global `:focus-visible` ring token | B |
| X2 | Reduced motion | Avoid motion | Smooth scroll and transitions always on | Ignores `prefers-reduced-motion` | moderate | Global reduced-motion rule | B |
| F1 | Companions | Use a companion | List inside Features | Hard to find in play | future | Companion gameplay tab (separate task); now: shown under Play | P |
| F2 | Conditions | Apply effects | Conditions are text chips with no mechanical impact | Future health and conditions engine | future | Recorded in docs/UI_MIGRATION_NOTES.md | P |

## Mechanical issues found during the audit

None that change rules. The base-max-HP display on the home cards (H2) is a display bug: the sheet already uses the
effective max.
