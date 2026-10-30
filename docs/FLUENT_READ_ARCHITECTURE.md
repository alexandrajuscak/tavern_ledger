# Fluent read architecture (provider-independent design, 2026-10-30)

**Status (2026-10-30):** implemented as Supabase option A (migration `20261030000100`, `js/read-layer.js`). It is deployed behind `FLUENT_READS = 'off'`; measurements: `docs/FLUENCY_BENCHMARKS.md`.

The same design works on Supabase (POC A: PostgREST RPCs) and on a portable API (POC B: HTTP endpoints); both call the
same SQL functions. Evidence for every claim: `docs/FLUENCY_POC_RESULTS.md`.

## 1. Principles

1. **One open = one round trip and one rules evaluation.** Today: 35 requests in 5 dependent waves and ~10 evaluations.
2. Permanent derived state is computed **once per build revision**, not once per RPC.
3. Runtime state (HP, slots, resources, Wild Shape, conditions) is small and read separately from permanent state.
4. Catalog data is versioned and cached; pickers fetch a **list**, then **one detail**.
5. Change events carry **what to refresh**, never data; the client refetches the affected bundle.
6. Authorization stays in PostgreSQL (RLS + SECURITY DEFINER checks). The API/bundle layer never filters by itself alone.

## 2. Request contracts

| Request | Content | Size (3-class L9 char, local) | Core evaluations |
|---|---|---|---|
| `GET view(char, tab)` — **default on open** | `{shell, tab, bundle}` | 30-40 KB (Play/Abilities/Spells); 133 KB (Build) | 1-2 |
| `GET shell(char)` — prefetch on hover/focus | identity row, governance (permission, campaign, lock, decisions), summary (level, abilities, AC, initiative, speed, HP, size, PB, senses, active form, warnings), revision `{character_updated_at, derived_hash}` | 7 KB | 1 |
| `GET tab(char, tab)` — tab change | see §3 | as view minus shell | 0-2 |
| `GET backgrounds` (list) | id, name, ruleset, legacy, source, abilities, feat name, flags | **9 KB** (was 470 KB) | 0 |
| `GET backgrounds/:id` (detail) | one version + its feat | 4 KB | 0 |
| Mutation (e.g. HP) | returns the new row + new revision; emits an event | < 1 KB | 0 |

Rules: no response > ~150 KB; Build's 118 KB `class_features` is the outlier and should get its own lazy section in
Phase 1 (only the open class's features).

## 3. Tab bundles

| Tab | Sections (existing functions, unchanged) |
|---|---|
| Play (`combat`) | derived, resources, states, spell_slots, transformation, attacks, trackers |
| Abilities (`stats`) | derived, proficiencies |
| Spells | spellbook, spell_slots, class_summary, legacy spells |
| Inventory | inventory id, items (ordered like today), equipment, attunement, weight, containers, legacy review |
| Build (`features`) | class_summary, class_features, lineage, background, feats, infusions, change_requests, features |
| Bio | notes (identity is in the shell) |

The bundles reuse the existing RPCs verbatim, so semantics are identical by construction (989 equality checks in POC A,
210/210 view equality between POC A and POC B).

## 4. One evaluation per bundle: the transaction memo (implemented in POC A)

`get_character_derived_stats` checks a transaction-local token. Bundle entry points switch it on, so every nested call of
`_character_mods` / `get_character_derived_stats` inside one bundle reuses one result, keyed by
`(token, character, current_user, auth.uid())`. `current_user` is in the key because SECURITY DEFINER callers run as the
owner (RLS bypass) and must not share a result with invoker callers; that is why Play and Build show 2 evaluations, not 1.
Outside a bundle the token is empty and behaviour is the old one (tested: 2 plain calls = 2 evaluations). The bundle is
read-only, so nothing can change under the memo. **Zero rule changes.**

## 5. Revisioned build snapshot (Phase 1b, designed, not built)

The memo removes repetition *within* a request. A snapshot removes it *across* requests:

| Part | Content | Refreshed when |
|---|---|---|
| `character_build_snapshot` (1 row per character) | abilities, saves, skills, passives, AC, initiative, speed, max HP, PB, attacks, spellcasting summaries, `build_revision`, `catalog_revision`, `computed_at` | after a permanent change |
| runtime (existing tables) | current/temp HP, slots expended, resources, active Wild Shape, conditions | never cached |

Permanent changes: class/level/subclass, lineage, background, feats and their choices, ability scores, equipment and
attunement, item modifiers, proficiencies, permanent custom content, catalog version change.

Refresh strategy (recommended): **lazy on revision mismatch, inside the read transaction.** Every permanent mutation
bumps `characters.build_revision` (one trigger per source table, in the same transaction as the change). A read compares
`snapshot.build_revision` and `catalog_revision` with the current values; on mismatch it recomputes, returns the fresh
value and writes the snapshot (a `SECURITY DEFINER` upsert; this makes the read path read-write, accepted). Correctness
argument: a snapshot is used only when both revisions match, and every input of the core bumps one of them, so a stale
snapshot can never be returned. Proof obligation: a test that, for every source table of the core, mutates a row and
asserts the revision changed (generated from the function dependency graph, `PERFORMANCE_AUDIT_2026-10-27.md` §6), plus the
golden equality suite run against snapshot reads. Synchronous refresh in every mutation was rejected (it would put the
8 s risk on writes); background refresh was rejected (stale windows).

Runtime-dependent parts of the core (Wild Shape form, active states, conditions that change AC/speed) must stay outside the
snapshot or bump the revision; this is the main implementation risk and is why the snapshot is Phase 1b, after the bundles.

## 6. Invalidation

| Event | Refetch |
|---|---|
| HP / temp HP / death saves / inspiration | shell only (or nothing: the mutation response carries the new values) |
| slot spent / restored, resource used | `spell_slots` / `resources` sections |
| Wild Shape start/end | shell + Play |
| equipment, attunement, item change | shell + Play + Inventory (derived changes) |
| class / feat / lineage / background / choices | shell + active tab (snapshot revision bumped) |
| governance / lock / approval / reveal | shell (governance) + request bar |
| another character's change | **nothing** |

Coalesce events for 300 ms per character; refetch only the domains in the union.

## 7. Change notification (Realtime replacement or simplification)

| Option | Fit for 5-25 users |
|---|---|
| A. Supabase Realtime, 64 table bindings per sheet (today) | works, but 66 subscription rows per sheet, WAL polling cost, churn on every switch |
| B. WebSocket from an API | more machinery than needed |
| **C. Server-sent events** | **recommended for the portable API** (POC B: 36 ms delivery via `pg_notify`, authorized at subscribe time) |
| D. Short polling of the active character | simple, 1 request / 5-10 s / viewer, latency = interval |
| **E. Revision polling + immediate mutation responses** | robust fallback; 1 tiny request per 10 s |
| F. Hybrid | C with E as fallback |

On **Supabase** the equivalent of C is **one Broadcast-style or single-table channel**: a `character_events` table (or
`realtime.send` broadcast) written by a trigger with `{character_id, domains, revision}`, one binding per sheet filtered by
`character_id`, instead of 64 table bindings. That keeps Realtime but reduces it to 1 subscription row per open sheet.
The own client ignores events whose revision it already has (its mutation response).

## 8. Frontend: cache and dedupe

- One in-memory store keyed `view:<char>:<tab>`, `shell:<char>`, `catalog:<name>:<etag>`; in-flight requests are shared
  (dedupe), superseded ones aborted (the existing `read-control.js` generation logic stays).
- Show cached data immediately marked "refreshing"; replace when the revision differs; do nothing when equal
  (`derived_hash` lets the client skip a re-render).
- Prefetch: shell on hover/focus of a card in Home; the likely next tab during idle (after the current tab has painted).

## 9. User transitions (V6 visual identity unchanged)

| Transition | Behaviour |
|---|---|
| Home → Character | header switches **immediately** to the clicked card's cached identity (name, class line, HP from the Home list) and a stable skeleton of the active tab; the view response fills header + tab **together** in one paint |
| A → B (→ C) | A's content is removed from interaction at the click (inert + dimmed for ≤ 150 ms), never shown as B; B's cached shell (if prefetched) appears at once; only the last target's response is rendered |
| Tab change | cached tab shows instantly ("refreshing" chip if older than its revision); otherwise skeleton of that tab only |
| Picker | modal and list shell at once; list from cache or a 9 KB request; detail on selection with an inline spinner in the detail pane |
| Reconnect | keep the screen; one shell fetch; refetch only domains whose revision changed |

No section-by-section pop-in: the bundle arrives as one response, so the sheet paints in one step.
