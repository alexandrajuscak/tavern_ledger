# Character domain bundles (release 2026-10-30)

Shell: `docs/CHARACTER_SHELL_CONTRACT.md`. Invalidation: `docs/CHARACTER_DATA_INVALIDATION_MODEL.md`.

## Decision: which domains are separate

The six sections of the sheet are rendered by loaders that share state (one class load feeds Play, Spells slots and Build;
the derived stats feed the header, Play, Abilities and Inventory notes). Splitting those loaders per tab would have meant
rewriting the sheet's rendering. The release therefore draws the line by **cost and visibility**, not by tab label:

| Domain | Contents | Loaded | Why |
|---|---|---|---|
| **Shell** (Play, Abilities, Build, Bio, header, vitals) | the 26 reads of the shell | with the open (`get_character_view`) | needed by the always-visible header/vitals and the default Play tab; one evaluation serves all of them |
| **Spells** | `get_character_spellbook` | first open of Spells (`get_character_reads`), or with the open when Spells is the active tab | the most expensive single read (production up to ~0.8 s); invisible until the tab opens |
| **Inventory** | `inventory_bundle`: inventory id, rows (`v_inventory_detail`, same order), equipment, attunement, weight, containers, legacy review, catalog rows (`CATALOG_COLUMNS`) of the items present | first open of Inventory, or with the open | replaces 7 requests + a catalog chunk (4 waves) with one |

Play / Abilities / Build / Bio need no request of their own after the open; switching to them costs 0 requests. Revisited
tabs use the data already in the sheet until a revision event invalidates their domain.

## Endpoints

| Call | Use |
|---|---|
| `get_character_view(p_character, p_tab)` | open: shell + the active tab's domain |
| `get_character_bundle(p_character, p_domain)` | `shell` / `spells` / `inventory` as a named bundle (diagnostics, tests, a future client) |
| `get_character_reads(p_character, p_reads text[])` | the coalesced form the client uses after the open: any allowlisted reads of one character, ≤ 40, one request, one memo scope |

All three: `SECURITY INVOKER`, pinned `search_path`, `authenticated` only, `can_access_character` before any read, per-read
error capture, `57014` propagated.

## Derived computation reuse

`get_character_derived_stats` and `_derived_stats_levels` hold a transaction-local memo that is active only while one of the
three entry points runs (token set at entry, cleared at exit; outside it the functions compute exactly as before). Key:
token + character + `current_user` + `auth.uid()`. Result: every nested caller (`_character_mods` in slots, resources, class
summary, spellbook; feats/states/transformation through `_derived_stats_levels`) reuses one evaluation. Measured locally:
**11 → 1-2** core evaluations per open; `fluent_read_tests.sql` asserts ≤ 2 and that outside a bundle two calls still compute
twice. No rule moved to JavaScript; no rule changed.

## Equality

`supabase/tests/fluent_read_tests.sql` (1,705 checks): every read in a view/bundle equals the direct RPC or table query for
every local character, as the owner and as the campaign DM; batch == view; inventory rows and catalog rows equal the legacy
queries. Production: `scripts/fluent/golden_reads.sql` compares the direct RPCs before/after the migration and the view
against the direct RPCs after it (`docs/FLUENCY_PRODUCTION_DEPLOYMENT.md`).

## Not done in this release (measured, listed in `V6_KNOWN_LIMITATIONS.md`)

- Build's `get_character_class_features` (33-118 KB) and the Wild Shape `options` (up to 86 KB) are still part of the shell;
  making them lazy needs the class and Wild Shape panels to render without them.
- No permanent build snapshot (see the snapshot checkpoint in `docs/FLUENCY_PRODUCTION_DEPLOYMENT.md`).
