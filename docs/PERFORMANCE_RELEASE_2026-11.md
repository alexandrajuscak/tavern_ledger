# Performance release 1 (2026-11-10): resource refresh, Home cards, catalog caches

**Status: prepared and tested locally, committed, NOT deployed.** Frontend only (asset marker `?v=21`); no migration, no
database object, no production contact. Deployment waits for a fresh production backup and a signed-in production smoke,
which need the database URL file (`%USERPROFILE%\.tavern-ledger\backup-db-url.txt`) that does not exist yet.

No secret, connection string, player name or e-mail appears in this report.

## Why

Read-only analysis of the saved production statistics (`pg_stat_statements` since 2026-10-30, release baselines):

| Evidence | Value |
|---|---|
| `get_character_reads` | 2,302 calls, mean 651 ms, max 7.9 s, 1,499 s in total (about ten times the next statement) |
| `get_character_derived_stats` called directly | 128 calls, mean 1,027 ms, max 6.0 s |
| Server read cache (`tl_cache`) | one counter per character: any write to a table with `character_id` (a spent resource or slot included) invalidates all 14 cached reads of that character |

Two frontend behaviours multiplied that cost:

1. **Every resource change re-read the whole class page.** A `character_resources` event (own click, or another session) ran
   `loadClasses`: class summary, slots, class features (33-118 KB), resources, states, then the Wild Shape read (options up to
   86 KB), companions, infusions and the starting-equipment state: about 4 requests, all cold because the same write had just
   invalidated the cache.
2. **Home cards bypassed the server read cache.** Each card called `get_character_derived_stats` directly, six at a time; only
   `get_character_reads` uses the cache.

## What changed

| Area | Change | Files |
|---|---|---|
| Resource refresh (A2) | `loadResources`: a resource use / restore and a `character_resources` revision re-read **only** `get_character_resources` and `get_character_states` (one coalesced request). `overlayResources` replaces the copies of the resource rows that the class-features read and the Wild Shape read carry (same server rows, same keys), so every counter on the page shows the fresh value. A class read that overlaps a resource change re-reads the resources afterwards (`resEpoch`). The JSON export always does the full class read first (it takes manual counters from the class summary) | `js/sheet.js` |
| Home cards (A3) | `cardDerivedStats`: on the fluent path the card reads go through `get_character_reads(['get_character_derived_stats'])`, the cached entry point; the direct RPC stays for the legacy flag and for a database without the fluent functions; a timeout is not retried on the slower path. Three reads at a time instead of six | `js/app.js` |
| Catalog caches on a user switch (finding 0.4a) | The spell catalog and details, lineage catalog and details, creature list and inventory catalog details are dropped by `clearReadCaches` (sign-out, session end, another user) through the existing `onUserCachesCleared` hook | `js/spell-api.js`, `js/lineage-api.js`, `js/creature-api.js`, `js/inventory-api.js` |
| Comments | legacy Realtime channel: 70 bindings (was documented as 64), fluent: 2 | `js/sheet.js`, `js/store.js` |
| Asset marker | `?v=20` → `?v=21` (201 references in `js/` and `index.html`, 7 browser tests) | — |

Unchanged on purpose: state changes (Rage start / end), class, feat, choice and Wild Shape changes, rests and slot dialogs
still run the full class read; the server functions; the legacy read path.

### Finding 0.4a in detail

Row-level security is correct: `v_spell_catalog` and `v_lineage_catalog` are `security_invoker` views, and the policies of
`catalog_spells`, `spell_versions`, `lineages`, `lineage_versions` and `creatures` return custom content only to its author,
an admin and members of its campaign. The exposure was in the browser only: sign-out does not reload the page, and only the
Background picker registered its cache for clearing. A second user signing in **in the same tab without a reload** could be
shown the previous user's campaign custom spells, lineages and creatures in pickers (and would miss their own). Tool and
weapon reference lists were never affected (official rows only). Whether the server would have refused to assign such
content was not tested; the cache is now cleared, so the question no longer arises.

## Tests (local Supabase stack, 55 migrations, 35 local characters)

| Suite | Result |
|---|---|
| `performance_release_ui_test.py` (new, 15 checks) | 15 / 0 |
| Complete browser suite (`run_browser_local.sh`, 41 suites) | 1,328 passed, 1 failed, then fixed (below) |
| `v6_product_hardening_ui_test.py` after the test fix | 51 / 0 |

The one failure was `H3` ("a fresh browser shows loading marks until the authoritative values arrive"): the test looked at
the Home cards once and expected none to be loaded yet. With the cached read two of three cards already showed their
authoritative AC. The check now holds the card reads back for 1.2 s while it looks; product behaviour is unchanged (a card
still shows the loading mark, never a stored legacy AC, until its read answers).

New checks: a Use click and a restore from another session cost the resource read only (no class features, class summary,
Wild Shape, slots, derived stats); the quick row, the Play action card, the Build feature card, the resource list and the
Wild Shape uses all show the server value; Home reads 3 cards through `get_character_reads` with no direct derived RPC and
the second visit is answered from the server cache (`cache.hits = 1` each); after a user switch on the same page all three
catalogs are read again.

Not run: the plain-PostgreSQL suite and rollback / re-apply (no SQL changed); a production smoke (no production access).

## Deployment plan (not executed)

1. Fresh backup with restore rehearsal (`nightly_backup.ps1 -Label pre-perf1 -Rehearse`), read-only baseline.
2. Push the commit (Pages build), verify the served files are byte-identical and carry one asset version `?v=21`.
3. Signed-in production smoke with synthetic accounts (fluent smoke + one resource use), cleanup to zero residue.
4. Rollback: revert the commit (frontend only; no database state to undo).

## Open items

1. Create the database URL file so the backup, the smoke and the read-only checks (logs, `temp_bytes` / `work_mem`) can run.
2. The nightly backup is still not scheduled (it needs the same file, and Docker running at the scheduled time).
3. Next release: split the read-cache revision into build and runtime counters (the server half of this problem). Note for
   its design: the class-features read embeds the resource rows, so it can be cached per build revision only because the
   client now treats the resource read as the authority for the counters.
