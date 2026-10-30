# Catalog list / detail API (release 2026-10-30)

Rule: a picker opens at once, shows a compact list, and loads one entry's full data only when it is selected. Timeouts,
errors and Retry are handled by `js/catalog-load.js` (existing) for lists and by the picker for details.

## Status per picker (local catalog = production catalog ± a few rows)

| Picker | List | Detail | List payload (uncompressed JSON) | Status |
|---|---|---|---|---|
| **Background** | `get_background_list()` **new** | `get_background_detail(p_version)` **new** | **≈ 9 KB** (was `get_background_catalog` ≈ 470 KB, 359 KB of it an unused feat list) | done in this release |
| Lineage | `v_lineage_catalog` (12 columns) | `get_lineage_detail` | 21 KB | already list/detail |
| Spell | `v_spell_catalog` (31 columns, no descriptions) | `get_spell_detail` | 429 KB | already list/detail; the list is large because every row carries class lists and casting metadata used by the filters. Trimming needs the filters reworked: follow-up |
| Feat | `get_feat_catalog(p_character)` (no descriptions, no effects; per-character eligibility) | `get_feat_detail` | 300 KB | already list/detail; size is per-row keys + summaries used by search: follow-up |
| Class / Subclass | 3 table reads (15 class, 119 subclass versions) | `preview_character_class_add`, `get_class_starting_equipment` | 50 KB | already compact |
| Item | `v_item_catalog` paged (`range`), filters server-side | row by id | one page | already compact |
| Wild Shape | creature list 72 KB + options inside `get_character_transformation` (up to 86 KB) | — | — | follow-up: options out of the open path |
| Companion | creature list (shared with Wild Shape) | — | 72 KB | follow-up |

## Background contract

`get_background_list()` → `{ versions: [{ id, name, ruleset, enabled_by_default, status, dm_permission, setting, source_label,
legacy, skills: [name] }], tools: [{ id, name }] }`, in catalog order (2024 first, then background and version sort order).
`tools` serves the duplicate-replacement dialog (every tool any background offers).

`get_background_detail(p_version)` → the same object `get_background_catalog().versions[]` contains for that id (tested equal
for every version), or `null` for an unknown or invisible version. Both: `SECURITY INVOKER` (visibility = RLS on
`background_versions`), `authenticated` only, pinned `search_path`.

Client: `js/background-api.js` `getBackgroundList` / `getBackgroundDetail` (session cache, cleared at sign-out, 15 s limit);
the editor shows "Loading the background…" and an inline Retry for the detail; the legacy path and an older database fall
back to the full catalog.
