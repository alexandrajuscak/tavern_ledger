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
  production statistics. No staging project exists.
