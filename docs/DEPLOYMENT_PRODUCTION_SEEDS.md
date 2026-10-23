# Deployment: production-safe seed manifest (2026-10-23)

## Verified on a clean database (throwaway `postgres:15` container, 2026-10-23)

Steps: the local auth harness → all **41 migrations** → the 9 catalog seeds in order → counts → all 9 seeds a **second
time** → counts again → `catalog_integrity_report.sql`.

- No migration or seed failed. The seeds are **idempotent**: the counts did not change on the second run.
- After seeding: **0** auth users, **0** profiles, **0** characters, **0** campaigns, **0** DM content. **No demo or test
  fixture comes from migrations or seeds.**
- RLS is enabled on **152 / 152** public tables. **0** SECURITY DEFINER functions lack a pinned `search_path`. 31 tables are
  in `supabase_realtime`.
- Integrity report: 14 checks, **0** dangling references.

## Seeds (apply in this order; the same order as `supabase/config.toml` `[db.seed]`)

| # | File | SHA-256 (first 16) | Size | Expected counts after a clean load | Overwrites | Production |
|---|---|---|---|---|---|---|
| 1 | `reference_data.sql` | `03d81799bd34b80c` | 422 KB | source_books **58**, damage_types **13**, items **1,146** (all kinds), equipment slots and rules | upserts; replaces `equipment_slot_rules` | SAFE |
| 2 | `item_effects.sql` | `02c21344a10c81c5` | 1 KB | item effects | upserts | SAFE |
| 3 | `spells.sql` | `a68c2be9858b3a40` | 721 KB | spell_versions **574**, class_spell_list_entries **1,543** | upserts; deletes official rows no longer in the catalog | SAFE for the initial load (see rule R1) |
| 4 | `classes.sql` | `004a183a7c5a6155` | 68 KB | class_versions **13**, subclass_versions **118** | upserts; deletes unused progression-only subclasses | SAFE |
| 5 | `class_features.sql` | `5aa078724dd3bb68` | 614 KB | class_feature_versions **246** | upserts; deletes official feature rows of the 13 classes | SAFE |
| 6 | `creatures.sql` | `81213bc9ad7570f5` | 410 KB | creatures **334** | upserts; deletes official creatures no longer listed | SAFE |
| 7 | `lineages.sql` | `0d12665062f386ad` | 495 KB | lineage_versions **133** | upserts; deletes rows not in the catalog (see R1) | SAFE for the initial load |
| 8 | `feats.sql` | `164d58cb41e0e4a7` | 315 KB | feat_versions **408** | upserts; deletes the child rows of official feats only | SAFE |
| 9 | `backgrounds.sql` | `145cf40c96ec36f2` | 181 KB | background_versions **30** | upserts; deletes the child rows of official backgrounds only | SAFE |

The local development database shows class_versions 15 / subclass_versions 119 / class_feature_versions 270. The
difference is local **test fixtures** (a synthetic test class from `class_feature_engine_fixture.sql`); they are not part
of the seeds.

## Forbidden in production (never run remotely)

- `scripts/local/seed_local_demo.py` and `scripts/seed-local-demo.ps1`: the demo users, Local Hero / Wizard / Warlock /
  Wild Shape characters, the Local Relaxed / Standard / Strict / Custom tables, requests, hidden conditions and custom
  content.
- `supabase/tests/fixtures/*.sql`, `supabase/tests/02_legacy_fixture.sql`, `supabase/tests/00_local_harness.sql` (it
  replaces the auth schema; it is meant only for plain PostgreSQL).
- Every browser or API suite: they create `ui-*`, `hb-smoke-*` and `local-smoke-*` users.

## Rule R1: initial load only (found in this audit)

`spells.sql` deletes `class_spell_list_entries` rows that are not in the official list, and `lineages.sql` deletes
`lineage_traits`, `lineage_choices` and similar rows that are not in the official catalog. Those statements are **not
limited to official content**. DM custom content writes into the same tables (`_dm_materialize`). Locally, 2 class-list
entries of custom spells would be removed by a re-run.

**So in production the seeds run exactly once, on the empty database, before any DM content exists.** A later catalog
update needs the generators (`scripts/data-migration/generate_spell_seed.py`, `generate_lineage_seed.py`, …) to scope these
deletes to official rows first. That is a follow-up, not part of this deployment.

## Licensing

The seeds carry structured rules data from non-SRD books, with source links. They are applied **from this machine**
directly to the database and are **not** committed to the public repository or served by Pages
(docs/DEPLOYMENT_FILE_MANIFEST.md, group 3).

**However: the official catalog is readable with the anonymous key, by design.** The SQL suite asserts it (S46), and it
was verified locally: `GET /rest/v1/spell_versions` and `/items` answer 200 without a sign-in. The publishable key is
public in `js/config.js`, so anyone who finds the site can download the whole hosted catalog through the API, even with
sign-up turned off. For a private-table deployment this is a **documented licensing risk**. For a promoted public release
it would need either an SRD-only catalog, or a migration that limits catalog reads to signed-in campaign members (a
behaviour change with its own tests). Licensing gate: docs/DEPLOYMENT_PRODUCTION_SECURITY_GATE.md.
