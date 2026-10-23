# V6.2 test isolation

How the V6.2 mutation tests keep the local database clean, and how to check that they did. LOCAL ONLY.

## Data classes

| Class | What | Tests may |
|---|---|---|
| A. user data | users, characters and campaigns created by hand in the local app | never touch |
| B. seeded demo data | `local-player@example.test`, `local-dm@example.test` and their characters / campaigns | read; `local_demo_smoke_test.py` takes an exact snapshot and restores it |
| C. synthetic test data | users `ui-*`, `hb-smoke-*` and `local-smoke-*@example.test` and everything they own; campaigns named `UI … Campaign` | create and must remove |
| D. catalog data | official classes, spells, feats, items, creatures, lineages, backgrounds | read only |

## The harness: `supabase/tests/browser/isolation.py`

`with Isolated("TEST-ID") as t:` wraps a test:

1. **Residue check.** Before the test it looks for synthetic rows left by an earlier run (users, campaigns, characters,
   items, DM content). By default it cleans them first and notes that in the journal. With `clean_first=False` it refuses to
   start.
2. **Protected digest.** It records an md5 of every public base table (rows sorted as text). There are 152 tables and the
   digest takes about 0.8 s.
3. **Cleanup.** After the test it removes all synthetic rows in dependency order. Characters go first, then DM content,
   campaigns, items, feat / background / lineage versions and their parents, creatures, and last the auth users.
4. **Reconciliation.** It checks that no synthetic row is left and that **every** public table is identical to the start.
   That includes the tables the test wrote to.
5. **Journal.** It appends one JSON line per test to `$MUTATION_JOURNAL`. The line holds the test id, its duration, what
   was removed, the residue, the changed tables, the test error and notes. On any residue or difference it raises
   `IsolationError`, so the test fails loudly and does not carry on.

Auth session tables (`auth.sessions`, `auth.refresh_tokens`, `auth.audit_log_entries`) grow with every sign-in. They are
outside `public` and are not part of the protected comparison.

## Tests of the harness itself: `v62_test_isolation_test.py` (9 checks)

| Check | What it shows |
|---|---|
| I0 | no synthetic residue before the suite |
| I1 | the synthetic world (user, campaign, character, items, DM content) exists while the test runs |
| I2 | afterwards: no residue, and all 152 public tables are byte-identical to the start |
| I3 | the journal records the test, what was removed, and the reconciliation |
| I4 | a cleanup that only half runs is **detected**, and the leftover users / campaigns are named |
| I5 | the journal records the failed reconciliation honestly |
| I6 | a later test refuses to start on residue when it may not clean it |
| I7, I8 | resuming the cleanup removes the leftovers, and every table is identical to the start again |

## Suites that use it

- `v62_test_isolation_test.py`
- `v62_adversarial_api_test.py`
- `v62_adversarial_ui_test.py`
- `v62_import_session_soak_test.py`

The older suites still use the runner's cleanup line at start-up. It deletes the synthetic users and the `UI … Campaign`
campaigns; the V6.2 campaign names and the `hb-smoke-*` / `local-smoke-*` accounts were added to it. Before the isolated
V6.2 suites, the runner removes what the older suites of the same run left behind and stops if anything remains.
`local_demo_smoke_test.py` restores its demo snapshot itself (V6).

## Found by the harness during V6.2

- `homebrew_smoke_test.py` never removed its `hb-smoke-*` user, character and homebrew item (ADV-MODERATE-021). The
  task-end fingerprint comparison caught it. The pattern is now synthetic, and the leftover was removed and verified.
- A browser runner stopped with only its outer shell killed kept running its suites. Its writes overlapped an isolated test,
  and the harness reported "cleanup incomplete or protected data changed" instead of passing silently. Stop the whole
  process tree (docs/LOCAL_DEVELOPMENT.md).

## Checking it by hand

```bash
# synthetic residue (expect no rows)
cd supabase/tests/browser && python -c "import isolation; print(isolation.residue())"
# journal of the last run
tail -n 5 "$MUTATION_JOURNAL"
```

Compare the protected fingerprint with the files in the task backup folder (`*_fingerprint*.txt`, `*_rowcounts.txt`). The
fingerprint SQL is kept next to them.

## Rules

- Never point a mutation test at a manually created user, character or campaign.
- Never restart Supabase while a test is running against protected rows.
- Never run `run_supabase_local.sh` against a database that holds data you want to keep: it starts from an empty volume.
  Use `run_local.sh` (a throwaway plain-PostgreSQL container) for destructive migration and rollback tests.
- Start the browser runner on a free port (`PORT=5191`) when your own dev server already uses 5173.
