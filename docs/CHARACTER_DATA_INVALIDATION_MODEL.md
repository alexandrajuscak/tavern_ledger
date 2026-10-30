# Character data invalidation model (release 2026-10-30)

## Revisions

`public.character_revisions (id, character_id, source_table, changed_at)`: an **append-only change log**; `id` (monotonic) is
the revision. A row trigger (`_bump_character_revision`, SECURITY DEFINER) on each of the 21 tables below inserts one row per
transaction, character and table. Properties (tested in `supabase/tests/fluent_read_tests.sql`):

- one row per **transaction** and table, however many rows or statements (transaction-local marker);
- insert-only: no shared row is ever updated, so no row lock is held between statements: no new lock-ordering / deadlock path;
- nothing stays pending in the transaction: DDL after DML in one transaction keeps working (a first design with deferred
  constraint triggers broke exactly that in the plain-PostgreSQL migration suite and was replaced before release);
- about 1 in 50 trigger calls prunes up to 200 rows older than 3 days (`for update skip locked`); the latest revision per table
  may be pruned after 3 days, which only means "nothing new" to a client that knows a higher one;
- never fails the user's write: any error becomes a `WARNING` and the write commits (verified: a bad marker name during
  development only produced warnings, every write succeeded);
- a character deleted in the same transaction leaves no row (insert only if the character still exists; FK cascade on delete);
- readable only where the character is readable (`can_access_character`), never writable by `authenticated`;
- carries no data: a table name and a number.

Domain revisions are derived from the per-table maxima (`revisions` read: `max(id)` per source table; the client keeps the
last known value per table):

| Domain | Source tables |
|---|---|
| **runtime** | `character_spell_slot_state`, `character_temporary_spell_slots`, `character_resources`, `character_transformations`, `spell_slots`, `feature_trackers`; the `characters` row itself (HP, temp HP, death saves, inspiration, coins: delivered as the row, see below) |
| **build** | `character_classes`, `character_feature_choices`, `character_optional_features`, `character_lineages`, `character_lineage_choices`, `character_backgrounds`, `character_proficiencies`, `features`, `attacks` |
| **inventory** | `inventory_items`, `character_equipment` |
| **spells** | `character_spells`, `character_spellcasting_sources`, `spells` |
| **notes** | `notes` |
| **campaign policy / approvals / locks** | `character_governance`, `change_requests` (the request bar's own 2 bindings, unchanged) |
| **custom content** | catalog tables: not invalidated per character (versioned catalog; a picker reloads on open) |

Hidden-condition and DM-note tables are deliberately **not** revisioned: a player must not learn *when* hidden data changed.

## What refreshes after which change

The revision event is replayed into the sheet's existing decision table (`onRemote` in `js/sheet.js`), so the targeted
behaviour of the legacy path is kept; the difference is the transport (1 table instead of 64 bindings) and that the reloads
are coalesced into one request.

| Change | Refreshed | Not refreshed |
|---|---|---|
| HP, temp HP, inspiration, death saves, coins (`characters` UPDATE) | the row is patched in place (the event carries it); derived stats only if a column they read changed (`derivedColumnChanged`) | build, spells, inventory, other tabs |
| spell slot used / restored | slots only | class features, derived |
| resource used | class reload (resources) | derived, lineage, spellbook |
| prepared spell / spell source | spellbook | everything else |
| equip / unequip / attune, item added | inventory panel if open (its re-read refreshes derived); otherwise derived + the stored rows | build, spells |
| class, level, choices, optional features | class reload + derived + lineage + spellbook | inventory |
| lineage / background | that card + derived | inventory, spells |
| Wild Shape start / end | transformation (+ derived when the form changes) | build |
| tracker / note / legacy feature, attack, spell row | that list (re-read, differences replayed row by row; edits in progress are kept) | everything else |
| another character's change | **nothing** (events are filtered by character server-side) | — |
| own change | the same as a remote one; reads triggered in the same tick are one request | — |

## Duplicates, ordering, reconnect

- An event whose revision is ≤ the last known one is ignored (duplicates, replays).
- Reconnect after a drop: one request (`characters` row + all revisions), then only the tables whose revision moved.
  The legacy path reloaded the whole sheet (34 requests) per drop.
- A prefetched view older than 1.5 s triggers the same reconciliation once after mount (nothing is missed between the
  prefetch and the subscription).

## Server-side read cache (migration 20261030000200)

`get_character_reads` (and with it the Character Shell, the view and the bundles) serves the expensive rules reads from
`tl_cache.character_reads`, one row per character, **viewer** (`auth.uid()`) and read. The legacy path (each RPC called
directly) never uses it. A cached value is served only while its key is unchanged:

| Key part | Bumped by |
|---|---|
| `tl_cache.character_rev(character)` | trigger `tl_cache_rev` on every public table with a `character_id` column; tables with an `inventory_id` column via `inventories.character_id`; `characters` itself unless only runtime columns changed (`hp_current`, `hp_temp`, `death_successes`, `death_failures`, `inspiration`, `hit_dice_current`, `cp`/`sp`/`ep`/`gp`/`pp`, `updated_at`) |
| `tl_cache.global_rev` | trigger `tl_cache_rev` on every other public table (catalog, campaigns, members, policies, DM content, profiles, item secrets, ...) and on a party / shop inventory |
| latest applied migration + calculation version | any migration (a migration may change a rules function) |

Rules that make a stale value impossible (each tested in `supabase/tests/progressive_read_tests.sql`):

- every public table carries the trigger (a coverage check fails for a future table without one);
- the key is read **before** the value is computed: a concurrent change can only make a stored value look older (a miss);
- the counter is a stored number compared for equality (never "the newest log row", which a pruned or uncommitted log row could
  fool); a no-op update does not bump; one bump per transaction;
- a transaction that has bumped a counter never stores a value (a later write in it would not bump again);
- trigger errors are not swallowed (a missed bump would be a stale value; the write fails instead);
- never cached: characters with a Wild Shape row (the form layer depends on current HP and on the clock), governance, change
  requests, table reads, errors; callers other than an API user (`authenticated`).

Cached reads: derived stats, proficiencies, lineage, background, feats, class summary, spell slots, class features,
resources, states, infusions, spellbook, primary-class starting equipment, transformation (only without a Wild Shape row).
A cached derived-stats value also seeds the request's memo, so nested invoker callers reuse it.
