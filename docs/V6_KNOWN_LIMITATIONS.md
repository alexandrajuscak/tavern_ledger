# V6 known limitations (verified, 2026-10-22)

## Current product limitations

- **Hit dice** are one pool: a count plus one die type. A multiclass character's dice of different sizes are not tracked
  separately.
- **Death saves** are three plus three markers stored on the character. There is no automatic roll, reset rule or
  stabilisation logic beyond resetting them on healing from 0 HP.
- **Weight** has no carrying capacity or encumbrance (not modelled). The Weight card says "carried" only.
- **Collapsed vitals** hide the condition chips; temp HP and the HP state stay visible as badges.
- **Search on Home** appears only with more than six characters.
- **Realtime timing:** updates made elsewhere arrive after about 0.5 s and are applied after the debounce (about 1.5 s in
  total). In 1 of 5 hardening runs one update took more than 15 s; this was not reproducible (10 / 10 rounds in a dedicated
  loop).
- **Reference reads:** `damage_types` and `class_versions` are read once by two modules each on the first sheet of a session.

## Depends on a future engine

- Conditions and concentration (effects are informational today).
- A unified Health, Death Saves, Hit Dice and Rest workflow.
- A Companion gameplay sheet (today: a summary card with HP and actions).
- A guided level-up wizard.
- The remaining official subclasses.

## Local-only measurement limitation

All timings in `docs/V6_PERFORMANCE_REVIEW.md` were measured on this machine against local Supabase in Docker. They say
nothing about a hosted deployment.

## Licensing

- **Fonts:** Inter, Cinzel and Alegreya use the SIL Open Font License 1.1, and supabase-js the MIT licence (texts in `fonts/`
  and `vendor/supabase-js/`).
- **Icons:** the curated icons in `assets/icons/` came from the user's own collection. Their licences are unknown
  (`docs/ICON_ASSET_INVENTORY.md`). They are fine for a private table; replace or license them before any public release.

## Added by V6.2 (2026-10-23; docs/V62_ADVERSARIAL_HARDENING_AUDIT.md)

- **Import** is all-or-nothing for the core rows (sheet, attacks, features, spells, slots, notes, inventory). The
  enrichment (lineage, background, classes, spells, feats, Wild Shape, companions) is best effort and reported. A fully
  transactional import needs a server import function (ADV-FUTURE-016).
- **Imported current HP** is not cut to the file's base maximum, because feats may raise it. The sheet bounds it once the
  derived stats load (ADV-FUTURE-018).
- **Sign-out is global** (Supabase default). Another open browser keeps working until its access token expires (about 1 h)
  (ADV-FUTURE-017).
- **Realtime DELETE events** are not filtered per character. Clients receive only the ids of deleted rows of other
  characters, never content (ADV-FUTURE-015).
- **Reconnect resync** covers the character sheet. DM Space and the request panel catch up on their next read
  (docs/V62_REALTIME_REVIEW.md).
- **Old audit rows** that named an unidentified item are hidden from the player on read, not rewritten. The DM still sees
  them.
- **Players do not see party members' sheets** or their audit events through the API (a policy choice;
  docs/V62_AUTHORIZATION_MATRIX.md).
- **Not tested in V6.2:** a hosted deployment, multiple real devices on a LAN, screen readers other than the automated
  checks, and very large campaigns beyond the local data (35 characters, 5 campaigns).

## Added by the production incident fix (2026-10-29; docs/PRODUCTION_INCIDENT_REALTIME_TIMEOUTS.md)

- **Realtime DELETE events** still reach every open sheet (they cannot be filtered server-side). The sheet now drops the
  deletes of other characters; for nine tables whose key holds no `character_id` it learns its own row keys with one small
  read after the first such delete, so that first delete still causes one refresh.
- **Aborting a read** cancels the statement in PostgREST (verified locally on PostgREST 14); a statement that is already
  finishing may still complete, and its answer is dropped.
- **Shared catalogs are not aborted** when a picker closes: they are cached per page and reused. Only the Background catalog
  has its own 15 s client limit; the others are bounded by the 8 s server statement timeout.
- **The spellbook loads with the Spells section** (and for export). Opening Spells for the first time after a sheet open costs
  one request there instead of on every open.
- **Saves**: after 6 failed automatic attempts (about a minute) unsaved edits wait for the next edit, reconnect or tab close.
- **Derived stats remain the main cost** of a sheet (about 9 RPCs that each evaluate the rules core). The items-scan fix
  removes about 40 % of that work; the next step (R2: spell slots and resources without the full derived evaluation,
  docs/PERFORMANCE_AUDIT_2026-10-27.md) is a larger change and not part of this fix.
- **Measured locally only** for request counts and the rapid-switch behaviour; production timings are from read-only
  production statistics. No staging project exists. Deployed 2026-10-29 (`a568ab5`); the signed-in production smoke is the
  operator's checklist in docs/DEPLOYMENT_PRODUCTION_SMOKE_RESULTS.md.

## Added by the fluent read release (2026-10-30; docs/FLUENT_READ_ARCHITECTURE.md)

- **No permanent build snapshot yet.** Each character open still runs the rules core once per security context (1-2 times,
  was ~10). Whether bursts on Supabase Free need the snapshot is decided by the measured checkpoint in
  docs/FLUENCY_PRODUCTION_DEPLOYMENT.md.
- **Still in the open:** Build's class-feature list (33-118 KB) and the Wild Shape form options (up to 86 KB) arrive with every
  open; making them lazy needs the class and Wild Shape panels to render without them.
- **Spell and Feat picker lists are large** (≈ 429 KB / 300 KB uncompressed; already list/detail): trimming needs the filters
  reworked. The Background picker list is ≈ 9 KB (was 470 KB).
- **No offline copy on the fluent path.** The legacy path kept the last stored rows of each opened character in localStorage
  and showed them read-only when offline; the fluent path deliberately persists no character data (privacy, shared devices).
  Offline, a character cannot be opened; edits in progress are still queued and saved later as before.
- **Session catalogs** (class catalog, lineage and spell references, inventory lookups) are still separate requests on the
  first open of a session; afterwards they are cached until sign-out.
- **Home card stats** (max HP, AC) still read the derived stats per card, six at a time, cached per character version.
- **Feature flag:** `FLUENT_READS` in js/config.js; `?fluent=0` per browser forces the legacy path. The legacy code path and its
  64-binding Realtime channel remain in this release as the rollback; they are removed only after production monitoring.

## Added by the Combat Builder (2026-11-06; docs/COMBAT_BUILDER_ARCHITECTURE.md)

**Unsupported combat automation (by design; the DM decides):**
- no attack, saving throw or damage resolution;
- no Resistance / Immunity / Vulnerability arithmetic (shown as reminders);
- conditions are reminders except the documented Initiative modes and the concentration notice;
- no automatic spell-to-effect mapping (concentration links are made by hand);
- no "Delay" action (not in either SRD);
- the optional 2014 tie roll-off is not automated;
- no automatic CR estimate for homebrew.

**Character data:**
- Passive Perception of player characters is calculated from the derived stats and the stored skill proficiency. A
  proficiency granted only by an item or background through the proficiency resolver may be missing; the sheet stays
  authoritative.
- Companions are not added automatically; use a typed-in combatant.

**Difficulty:** 2024 only (SRD 5.2.1 XP budget). SRD 5.1 has no encounter difficulty table, so 2014 encounters show
"not available".

**Catalog / licensing:** 73 SRD 5.2.1 stat blocks (a focused set; the parser reads 327 of the 330); SRD 5.1 creatures as
before. Non-SRD monsters only as DM homebrew.

**Player view:** the read model `get_combat_player_view` exists and is tested, but there is no player combat screen yet.

**Sheet HP buttons need a connection:** Damage and Heal on the character sheet are now one atomic server call
(`apply_character_hp`). Offline they refuse ("Could not reach the server. Nothing was changed") instead of queuing; a
typed HP value still saves and queues as before.

**Mobile:** full stat blocks are in the detail drawer; long encounters (20+ combatants) scroll in one column below
600 px.

**Not in scope (future):** battle map, tokens, movement, line of sight, VTT features.

**Local environment:** the full ruleset text of SRD conditions is summarized (project-authored), not reproduced.

## Follow-up 2026-11-07 (feat removal, ability sources)

- **Ability Score Improvement above 20:** effect bonuses (class ASIs, feats, items) are added after the 20-cap and capped only
  at 30, so an ASI on a base of 19 gives 21 (the rules cap an ASI at 20; some items may exceed it). Needs per-source caps in
  `_derived_stats_core`; not changed because it alters effective scores. Local data: 0 characters affected.
- **Feat saving-throw proficiency** (Resilient and similar) is shown as automated on the feat card, but the derived saves and the
  proficiency resolver do not apply it; mark the save on the sheet manually until fixed.
- **Orphan inactive feat resources** left by feat removals before 20261107 are not cleaned retroactively (inactive, never shown).
- **Source-granted feats** are changed at their source (background, lineage, ASI choice); there is no DM override that removes
  only the feat and keeps the source.
- **Combat Builder mobile header:** on 390 px the encounter header and the notes take about 40 % of the screen before the
  initiative list (Next stays docked at the bottom). Unchanged in this follow-up.
- **Combat Initiative modifier** follows the sheet only until Initiative is entered or rolled; a rolled Initiative is kept for
  the whole combat (rolled once, as in the rules).
- **Combat Builder live refresh** of a linked character covers tables with a revision trigger (feats, classes and class choices, lineage, background, proficiencies, equipment, inventory). Infusions, active states (Rage …), background choices and item modifiers are picked up when the encounter is reopened.

## Combined follow-up release (2026-11-07)

- **Wild Shape duration** is tracked by wall clock. A form past its duration still takes damage as shown (then ends); a heal
  or correction on it ends it and changes nothing (the DM re-applies to the normal form). Instant death, form resistances and
  concentration stay reminders. No 2024 Druid exists in the catalog.
- **Undo** of a Combat Builder damage that ended a Wild Shape form is refused (correct the HP by hand).
- **Active class options** in Play are reminders unless the option was already automated; Favored Enemy, Natural Explorer
  and Dragon Ancestor stay on Build. Option counters are matched to their option by name (resource reads carry no option id).
- **Artificer**: a character whose item holds an active infusion cannot be deleted directly (the managed-modifier guard refuses
  the cascaded delete); end the infusion first. Pre-existing, found during this release, not changed.
- **Herbs & Plants / potion details and crafting notes** are text only; no crafting, harvesting or ingredient consumption.
- **Item icons**: gallery only (no uploads); an icon key unknown to an older browser falls back to the category icon.
- **Permanent delete** refuses anything with inventory history, even after the entries were removed (archive instead).
- The read-cache revision is bumped once by the item and class-option migrations: the first open of each character after the
  release is a cold read.
- **Shared monster groups**: a total typed for one member always sets the whole group; there is no UI to split an existing
  group (add copies with "Each rolls" for individual Initiative).
- **Expired-form heal in the Combat Builder** records no HP event (nothing was applied); a retry with the same request id is
  therefore not deduplicated and, since the form has ended, would heal the normal form.
