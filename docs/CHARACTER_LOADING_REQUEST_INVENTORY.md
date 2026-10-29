# Character loading: request inventory (incident 2026-10-23)

Measured with `supabase/tests/browser/incident_probe.py` (local stack, Chromium network emulation 150 ms per request,
synthetic multiclass characters). Release `9b810aa` = "before"; the incident fix = "after". Request **counts** are
comparable with production; local **times** are not (local PostgreSQL is 10-25x faster than the Free compute, see
docs/PRODUCTION_INCIDENT_REALTIME_TIMEOUTS.md §2a).

"Heavy" = an RPC that recomputes the character's derived stats inside the database (production idle 50-930 ms each).

## One character open (warm session)

| # | Request | Domain | Specific / shared | Heavy | Stage | Initial render needs it | Cancellable after fix | Realtime refreshes it |
|---|---|---|---|---|---|---|---|---|
| 1-8 | `characters`, `inventory_items`, `notes`, `spell_slots`, `feature_trackers`, `features`, `attacks`, `spells` (bundle) | core + legacy lists | character | no | 1 (parallel) | yes | yes (`loadBundle` signal) | yes |
| 9-11 | `campaigns`, `campaign_members`, `profiles` (loadCampaigns) | campaign | user | no | 1 (parallel) | yes (chips, owner) | no (shared, tiny) | no |
| 12-13 | `get_character_governance`, `get_character_change_requests` | governance | character | no | 2 | lock banner | yes | yes (request channel) |
| 14-15 | `get_character_derived_stats`, `get_character_proficiencies` | derived | character | **2** | 2 | yes (AC, saves, skills) | yes | yes |
| 16 | `get_character_lineage` | lineage | character | no | 2 | Build chips | yes | yes |
| 17 | `get_character_background` | background | character | no (1 core run for a 2024 background) | 2 | Build card | yes | yes |
| 18 | `get_character_spellbook` | spells | character | **1 (2 core runs)** | 2 | **only on Spells** | yes | yes |
| 19-23 | `get_character_class_summary`, `get_character_spell_slots`, `get_character_class_features`, `get_character_resources`, `get_character_states` | classes | character | **5** | 2 (parallel) | Play strip, Build | yes | yes |
| 24 | `get_character_feats` | feats | character | **1** | 2 | Build | yes | yes |
| 25-26 | `get_character_transformation`, `character_companions` | Wild Shape / companions | character | **1** | 3 (after 19-23) | Play | yes + generation check | yes |
| 27 | `get_character_infusions` | infusions | character | no | 3 | Build | yes + generation check | no |
| 28-29 | `character_starting_equipment`, `get_class_starting_equipment` | class setup | character | no | 4 (after 25-27) | Build | generation check | no |
| 30-35 | `inventories`, `v_inventory_detail`, `character_equipment`, `v_character_attunement`, `v_inventory_weight`, `v_container_contents`, `legacy_inventory_review` | inventory | character | no (views; `v_character_attunement` up to 6.6 s in production under load) | 2 | Inventory, AC | aborted with the inventory controller | yes |

Shared reference data (class catalog, lineage reference, spell reference) is read once per page and cached
(`classCatalog`, `lineageRef`, `spellRef`, the api modules' `*Promise` caches): measured 0 repeated reads per open.

### Before / after (150 ms latency)

| Scenario | Release 9b810aa | After the fix |
|---|---|---|
| One open: requests / heavy RPCs | 36 / 10 | 35 / 9 (spellbook with the Spells section) |
| Rapid A -> B -> C (150 ms apart): A and B bundle reads | 16 completed | 13 cancelled |
| Paced A -> B -> C (700 ms apart): heavy RPCs of A / B completed | 10 / 10 | 7 / 2 (locally fast; on production most would be cancelled) |
| Own HP edit: heavy RPCs in the editing + a viewing session | 3 + 3 | 0 + 0 |
| A delete on a character nobody has open: heavy RPCs per open sheet | 3 (every time) | first time 2 + 1 small read (learning), then 0 |
| Realtime drop x3: heavy RPCs / channel joins | 30 / 12 | 27 / 9 (one coordinated reload per real reconnect, channel kept) |
| Background picker: dialog shown / results (local) | 0.28 s / 0.28 s (nothing visible until the catalog arrived) | 0.12 s / 0.35 s (dialog first, list loads into it) |

## Safe to lazy-load, cache or drop

| Request | Decision | Why |
|---|---|---|
| `get_character_spellbook` | **lazy** (implemented) | heaviest single read in production (928 ms idle for character 4); only the Spells section and export show it |
| class / lineage / spell reference | already cached per page | shared, no character data |
| `get_background_catalog` | already cached per page; own 15 s limit (implemented) | 90 ms idle, 470 KB |
| `campaigns`, `campaign_members`, `profiles` per open | kept | tiny, decide ownership chips; candidate for a later per-session cache |
| `get_character_transformation` on mount and Realtime | kept | debounced; the mount read is part of `loadClasses` stage 3 |
| A combined `get_character_sheet` RPC | **not** done | it would still run the derived core several times (docs/PERFORMANCE_AUDIT_2026-10-27.md 16.4); only worth it after R2 |

## Sequential chains

`loadClasses`: stage 2 (6 parallel) -> stage 3 (3 parallel) -> stage 4 (starting equipment). Each stage now checks that
the load is still current before starting the next (a superseded load stops instead of sending stages 3 and 4).
`loadLineage`: lineage -> (only for an old free-text race) the lineage catalog for a suggestion.
