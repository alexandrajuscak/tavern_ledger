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
