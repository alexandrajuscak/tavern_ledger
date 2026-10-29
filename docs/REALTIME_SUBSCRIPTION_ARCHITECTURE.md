# Realtime subscription architecture (incident 2026-10-23)

## Client and sockets

One Supabase client per page (`js/supabase.js`, created once; every module imports it with the same specifier, so the
module is evaluated once). `globalThis.__tavernLedgerClients` counts instances for the tests (1 expected; no credential
involved). One Realtime WebSocket per page carries every channel.

## Channels

| Channel | Owner | Bindings | Created / removed |
|---|---|---|---|
| `character-<id>-<rand>` | `store.subscribeCharacter`, owned by the open sheet | 64: `characters` UPDATE (filter id) + 21 tables x INSERT/UPDATE (filter character_id) + 21 x DELETE (no filter possible) | created on the first live mount of a character; **kept** when the same character is reloaded (reconnect, refused change); removed on switch, leave, sign-out |
| `requests-<id>-<rand>` | `request-ui.js` (approval bar of the sheet) | 2 | with the sheet's governance bar |
| `dm-<campaign>-<rand>` | `dm-space.js` | 2 | DM Space; now also removed on sign-out |

Every binding is one row in `realtime.subscription`; one open sheet = 66 rows. Production evidence: ~7,000
subscription-create statements in one week of light use (64 per open), Realtime's own statements up to 3-9 s while the
database was saturated, which is what Realtime reports as `IncreaseSubscriptionConnectionPool: Too many database timeouts`.

### Why the 21 child tables stay

Each one is rendered by the sheet and changed by other sessions (DM edits, a second device). Catalog tables are **not**
subscribed (pickers load on open, Retry, reconnect). Reduction tested and rejected: one `event: '*'` binding with a filter per
table delivered no events at all on the local stack (2026-10-29), so the INSERT / UPDATE pairs stay.

## DELETE attribution (new)

DELETE cannot be filtered server-side and its `old` record holds only the primary key (verified locally: `{id}`).
Before the fix every open sheet treated every delete in these tables, of **any** character, as its own and re-read derived
stats, classes, lineage and spellbook. Now `subscribeCharacter` drops deletes of other characters:

- the key holds `character_id` (`character_backgrounds`, `character_equipment`, `character_lineages`,
  `character_lineage_choices`, `character_spell_slot_state`, `character_transformations`): compared directly;
- key without `character_id` (`character_classes`, `character_feature_choices`, `character_proficiencies`,
  `character_resources`, `character_spellcasting_sources`, `character_spells`, `character_temporary_spell_slots`,
  `inventory_items`, `character_optional_features`): on the first such delete the sheet reacts as before **and** reads the keys of
  its own rows once (`select id … where character_id = <open character>`, RLS applies); afterwards a delete is delivered only
  when its key is one of them. INSERT events of the open character add their key. After a connection drop the keys are
  learned again.
- legacy lists (`notes`, `spell_slots`, `features`, `attacks`, `spells`, `feature_trackers`): the sheet already ignores ids it
  does not hold.

## UPDATE of `characters`

The sheet compares the stored row (`serverChar`, from the bundle and every Realtime UPDATE) with the new one. A change of
columns the derived-stats SQL never reads (HP, temporary HP, coins, death saves, hit dice, inspiration, portrait, pending
choices, XP, `updated_at`) no longer re-reads the derived stats; name, HP and temporary HP count while a Wild Shape form
is active (the form layer reads them). Column list checked against `_derived_stats_core`, `_derived_stats_full`,
`_feat_layer`, `_wild_shape_layer` and their helpers, including the dynamic `to_jsonb(c) ->> 'strength'` access.

## Reconnect

`subscribeCharacter` notices `CHANNEL_ERROR` / `TIMED_OUT` followed by `SUBSCRIBED` and calls the sheet's resync, which is
debounced (1.5 s): queued edits are saved, then the sheet reloads its stored values **once**, keeping the channel (no leave and
join). Several drops in quick succession = one reload (test 29). No retry loop: supabase-js reconnects the socket with its
own backoff.
