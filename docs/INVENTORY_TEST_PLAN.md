# Inventory test plan

No test framework was added to the project. Layers:

| Layer | File | Runs against |
|---|---|---|
| SQL | `supabase/tests/inventory_tests.sql` (200 checks) | plain PostgreSQL 15 (`run_local.sh`) and the local Supabase database |
| SQL | `supabase/tests/derived_stats_tests.sql` (56 checks) | same; needs `supabase/seed/item_effects.sql` |
| SQL | `supabase/tests/lineage_tests.sql` (84 checks) | same; needs `supabase/seed/lineages.sql` |
| SQL | `supabase/tests/spell_tests.sql` (45 checks) | same; needs `supabase/seed/spells.sql` then `lineages.sql` |
| SQL | `supabase/tests/class_slot_tests.sql` (84 checks) + `slot_concurrency_test.sh` | same; needs `supabase/seed/classes.sql` |
| SQL | `supabase/tests/class_feature_tests.sql` (94 checks) + `feature_resource_concurrency_test.sh` | same; needs `class_features.sql` and the synthetic fixture `supabase/tests/fixtures/class_feature_engine_fixture.sql` (loaded right before the suite) |
| API contract | `supabase/tests/api/api_contract_test.py` (168 checks, incl. derived stats, proficiency RLS, lineages, spells, class levels and class features) | local Supabase: GoTrue + PostgREST, real JWTs |
| Browser | `supabase/tests/browser/inventory_ui_test.py` (38), `homebrew_smoke_test.py` (28), `derived_stats_ui_test.py` (35), `lineage_ui_test.py` (25), `spell_ui_test.py` (28), `class_slot_ui_test.py` (29), `class_feature_ui_test.py` (36) | the real app in Microsoft Edge (Playwright, headless) + local Supabase; all run from `run_browser_local.sh` |
| Manual | checklist below | a person with a browser |

Browser test setup (outside the project): `python -m venv <tmp>/pwvenv && <tmp>/pwvenv/Scripts/pip install playwright==1.55.0`,
then `SUPABASE_CLI=… bash supabase/tests/run_supabase_local.sh --keep` and `PYTHON=<tmp>/pwvenv/Scripts/python bash supabase/tests/run_browser_local.sh`.
It uses synthetic users (`ui-*@example.test`) and characters; screenshots go to `$TEMP/tavern-ledger-screens`.

## Required scenarios — results of the last run

| # | Scenario | Evidence | Result |
|---|---|---|---|
| 1 | character without inventory | browser 1 | PASSED |
| 2 | character with legacy items | browser 2a–2d (shown, review badge, link) | PASSED |
| 3 | catalog > 1 000 items | browser 3a ("Showing 50 of 1146") | PASSED |
| 4 | search and filter reset paging | browser 3c, 3d | PASSED |
| 5 | Load more without duplicates | browser 3b (100 unique ids) | PASSED |
| 6 | add an item | browser 4 | PASSED |
| 7 | add several pieces | browser 4 (Javelin ×5, 4 Sledgehammers) | PASSED |
| 8 | quantity never 0 | SQL J1–J3, P2; API "quantity 0 rejected", "refuses 0"; UI sends no 0 (− on the last piece = remove) | PASSED |
| 9 | remove the last piece | browser 12 | PASSED |
| 10 | equip | browser 6b, 7b | PASSED |
| 11 | equip from a stack of thrown weapons | browser 6a (Javelin 5 → 4 + 1) | PASSED |
| 12 | unequip | browser 6c (rejoins the stack) | PASSED |
| 13 | shield + two-handed weapon | browser 7a | PASSED |
| 14 | attune | browser 13a | PASSED |
| 15 | attunement limit | browser 13b | PASSED |
| 16 | healing potion | browser 8a, 8b | PASSED |
| 17 | last potion | browser 8c | PASSED |
| 18 | scroll | browser 9 | PASSED |
| 19 | missing ammunition | browser 10a, 10b | PASSED |
| 20 | container warning | browser 11 | PASSED |
| 21 | owner access | browser (all player scenarios), API | PASSED |
| 22 | DM access | browser 15a, API | PASSED |
| 23 | another player cannot change it | browser 15b, API, SQL G1–G4 | PASSED |
| 24 | refresh keeps the server state | browser 14 | PASSED |
| 25 | mobile view | browser 16a–16d (Edge, 390 × 844 viewport) | PASSED (emulated viewport) |
| – | realtime: DM change appears on the player's open page | browser 16r | PASSED (local stack) |
| – | browser console without unexpected errors | browser 17 | PASSED |

The browser suite ran three times in a row with 38/38 (one flaky test step was fixed in the test, see below).

## Derived character stats — last run (2026-10-15)

Full validation on a fresh local database (`run_supabase_local.sh`, migrations + both seed files):

| Check | Result |
|---|---|
| 15 migrations on an empty volume, 1146 items, seed re-run | PASSED |
| legacy path (base schema → legacy rows → `migration up` → seed) | PASSED |
| SQL: inventory 200/200, derived stats 56/56 (Supabase Postgres and plain PostgreSQL 15, before and after rollback + re-apply) | PASSED |
| API contract 96/96 | PASSED |
| rollback to the base schema (11 tables), then `db reset` | PASSED |
| browser: inventory 38/38, homebrew 28/28, derived stats 35/35 | PASSED |
| `seed-local-demo.ps1` twice (idempotent); Local Hero AC 18, Local Sidekick AC 16 / speed 20 with armor, Strength and weapon warnings | PASSED |
| data survives `stop-local` / `start-local` | PASSED |
| AC tile note at 320 / 360 / 390 / 900 px, incl. manual override + 4 warnings: stays inside the shield shape | PASSED (screenshots checked) |

Fixes found by this run: the derived-stats migration failed on a **fresh** database (its `proficiency_groups` reference
armor categories that only the later seed created; it now inserts those four categories itself, with the seed's
values). The demo seeder equipped the shield in `off_hand` instead of the `shield` slot. On phones the AC tile note
now shows a compact form (`⚠ 4`).

## Character lineages — last run (2026-10-15)

Fresh local database, 16 migrations, three seed files (`run_supabase_local.sh`, `run_local.sh`, `run_browser_local.sh`):

| Check | Result |
|---|---|
| 16 migrations on an empty volume; 47 lineages / 133 versions seeded; legacy-data path | PASSED |
| lineage seed loaded twice: catalog checksum unchanged (Supabase and plain PostgreSQL) | PASSED |
| SQL: inventory 200/200, derived stats 56/56, lineages 84/84 (both databases, and again after rollback + re-apply) | PASSED |
| lineage-only rollback → derived stats 56/56 on the restored 20261015001400 functions → `migration up` → lineages 84/84 | PASSED |
| API contract 111/111 (15 lineage checks) | PASSED |
| full rollback to the base schema (11 tables), then `db reset` | PASSED |
| browser: inventory 38/38, homebrew 28/28, derived stats 35/35, lineages 25/25 | PASSED |
| whole-catalog sweep: 124 version / sub-lineage combinations assigned and resolved (SQL L67) | PASSED |
| demo seed (lineages for Local Hero / Local Sidekick), data kept across `stop-local` / `start-local` | PASSED |

## Spell catalog and spellbook — last run (2026-10-16)

Fresh local database, 17 migrations, four seed files (`run_supabase_local.sh`, `run_local.sh`, `run_browser_local.sh`):

| Check | Result |
|---|---|
| 17 migrations on an empty volume; 574 spell versions seeded; 137/137 lineage spell grants linked; legacy-data path | PASSED |
| spell and lineage seeds loaded twice: catalog checksums unchanged (Supabase and plain PostgreSQL) | PASSED |
| SQL: inventory 200/200, derived stats 56/56, lineages 84/84, spells 45/45 (both databases, and again after rollback + re-apply) | PASSED |
| spell-only rollback → lineages 84/84; lineage-only rollback → derived 56/56; `migration up` → lineages 84/84, spells 45/45 | PASSED |
| API contract 129/129 (18 spell checks) | PASSED |
| Realtime publication includes `character_spells`, `character_spellcasting_sources`; 9 security_invoker views | PASSED |
| full rollback to the base schema (11 tables), then `db reset` | PASSED |
| browser: inventory 38/38, homebrew 28/28, derived stats 35/35, lineages 25/25, spells 28/28 | PASSED |
| catalog kept across `stop-local` / `start-local` | PASSED |

## Class levels, spell slots, Pact Magic and rests — last run (2026-10-16)

Fresh local database, 18 migrations, five seed files:

| Check | Result |
|---|---|
| `run_supabase_local.sh`: 178 checks (18 migrations; class seed 12 versions / 240 levels / 289 slot rows; seeds idempotent; SQL inventory 200, derived 56, lineages 84, spells 45, classes 84; rollbacks 1700 → 1600 → 1500 with guards, re-apply; Realtime; API 146) | PASSED |
| `run_local.sh` (plain PostgreSQL): same SQL suites, slot concurrency (last slot spent once), all rollbacks | PASSED |
| browser: inventory 38, homebrew 28, derived stats 35, lineages 25, spells 28, classes / slots 29 | PASSED |

## Class feature engine — last run (2026-10-16)

Fresh local database, 19 migrations, six seed files (+ `class_features.sql`), synthetic fixture loaded only for the
feature suites:

| Check | Result |
|---|---|
| `run_supabase_local.sh`: 209 checks (19 migrations; seeds and fixture idempotent; SQL inventory 200, derived 56, lineages 84, spells 45, classes 84, class features 94; class-resource and slot concurrency; rollbacks 1800 → 1700 → 1600 → 1500 with guards, re-apply; Realtime; API 168; `db reset`) | PASSED |
| `run_local.sh` (plain PostgreSQL): same SQL suites, both concurrency tests, all rollbacks and re-apply | PASSED |
| browser: inventory 38, homebrew 28, derived stats 35, lineages 25, spells 28, classes / slots 29, class features 36 | PASSED |
| task-start data restored from backup (fingerprint identical); Local Feature Tester added; `stop-local` / `start-local` keeps everything | PASSED |

Test changes: `class_slot_tests.sql` M10 now chooses Eldritch Knight at Fighter 3 before lowering to 2 (a subclass can
only be chosen at its selection level); `class_slot_ui_test.py` check 18 reads the new class change review instead of
the old confirm; `run_local.sh` loads the fixture only right before `class_feature_tests.sql` (other suites expect 12
classes).

## Wild Shape gameplay engine — last run (2026-10-17)

**Completed and passed:**
- `run_supabase_local.sh --keep`: 328 checks passed and 1 failed (CAE6). CAE6 was an obsolete message expectation in
  `class_catalog_api_test.py`; the engine's refusal was correct. The expectation was updated, and the file then passed
  69/69. Rollback checks passed.
- Wild Shape SQL (`classes/wild_shape_tests.sql`): 52/52.
- Wild Shape concurrency: 4/4.
- Wild Shape API and access control (`api/wild_shape_api_test.py`): 31/31.
- Focused browser tests: `wild_shape_ui_test.py` 74/74 and `class_druid_ui_test.py` 14/14.
- Post-restore smoke test on the restored local data: 10/10.

**Interrupted, not failed (incomplete):** Claude Code stopped these two because the machine was low on available memory.
Neither is fully run after the final changes.
- `run_local.sh`: 472 checks passed and 0 failed, up to the per-class tests.
- `run_browser_local.sh`: the inventory suite passed 38/38, with no failure before the homebrew test.

## Local demo data smoke test

`supabase/tests/browser/local_demo_smoke_test.py` (23 checks) runs against the seeded demo characters
([LOCAL_TEST_CHARACTERS.md](LOCAL_TEST_CHARACTERS.md)) without resetting anything; afterwards run
`.\scripts\seed-local-demo.ps1 -Repair`. Last run 2026-10-16: 23 / 23 PASSED.

## NOT RUN

- Real phones/tablets, Safari and Firefox (only Edge/Chromium was automated).
- Google OAuth and magic-link sign-in with the new UI (password sign-in was used).
- Anything against the hosted Supabase project (not allowed in this phase).
- Accessibility audit with a screen reader.
- Offline behaviour of the inventory actions.

## Manual checklist (for a person, before a release)

1. Open an existing character: every item of the old inventory is visible; custom items have a dashed border.
2. A custom item with the same name as a catalog item offers **Link**; linking keeps name and description.
3. **+ Add item**: search "rope", filter kind/category/rarity/magic/source, Load more, add 3 pieces; the list updates and a toast appears.
4. − / + on a stack; − on the last piece asks before removing.
5. Equip a javelin from a stack of 5 (4 remain, 1 equipped). Unequip (back to 5).
6. Equip a shield, then a greatsword → clear error. Swap via the slot's **Replace**.
7. Attune three items; the fourth shows the limit and the list of attuned items.
8. Use a Potion of Healing: "Healing: 2d4 + 2", HP unchanged. Use the last one: it disappears.
9. Longbow without arrows → warning; add arrows → count and "Show".
10. Put heavy things into a sack → over-capacity warning (not blocked). Try to put a container into itself → clear error.
11. Reload the page: same state. Open the same character on a second device/tab: changes appear without reloading.
12. As the DM: open a player's character and add an item. As another player: the character is not accessible.
13. Phone: equipment collapses, cards are readable, all buttons reachable without hover, details open as a bottom sheet.
14. The equipped checkbox is gone; nothing in the UI allows quantity 0.

## Fixes found by the tests

- Database: shields were allowed in the **armor** slot (a kind-level rule with `category_id = null` meant "any category").
  Fixed in the seed generator (item-level rules for magic armor without a category) + SQL tests C9b, C9c.
- UI: equipment column overflowed on phones (`min-width: auto` grid items) — fixed in CSS.
- UI: catalog items without a known weight showed "0 lb" — now "weight unknown".
- Test: picking a result while the debounced search was still replacing the list (test-only race; the test now waits).
