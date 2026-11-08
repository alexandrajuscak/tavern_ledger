"""Test isolation for mutation tests (docs/V62_TEST_ISOLATION.md). LOCAL ONLY.

Data classes:
  A. user data (manually created users, characters, campaigns)      -> never mutated by tests
  B. seeded demo data (local-player / local-dm and their characters)  -> read only, or exact snapshot + restore
  C. synthetic test data (users ui-*@example.test and what they own)  -> created and removed by the test
  D. catalog data (official catalog, normalized versions)            -> read only

`Isolated(test_id)` wraps a test:
  1. refuses to start while synthetic residue exists (an earlier run did not clean up), unless asked to clean it first;
  2. records a digest of every public table (md5 of all rows) = the protected state;
  3. after the test removes all synthetic rows in dependency order;
  4. verifies that no synthetic row is left and that every public table is byte-identical to the start;
  5. appends a journal entry (JSON lines) and fails loudly on any difference.
"""
import json
import os
import subprocess
import time
from pathlib import Path

DB = "supabase_db_tavern_ledger"
SYNTH_EMAIL = "ui-%@example.test"
# every synthetic account pattern of the suites: ui-* (browser suites), hb-smoke-* (homebrew_smoke_test), local-smoke-* (local_dev_smoke_test)
SYNTH_EMAILS = ("ui-%@example.test", "hb-smoke-%@example.test", "local-smoke-%@example.test")
SYN_EMAIL_SQL = "(" + " or ".join(f"email like '{e}'" for e in SYNTH_EMAILS) + ")"
SYNTH_CAMPAIGNS = ("UI Test Campaign", "UI Refinement Campaign", "UI Hardening Campaign", "UI Adversarial Campaign", "UI Adversarial Campaign B")
JOURNAL = Path(os.environ.get("MUTATION_JOURNAL", Path(os.environ.get("TEMP", "/tmp")) / "tavern-ledger-mutation-journal.jsonl"))


class IsolationError(AssertionError):
    pass


def psql(sql):
    r = subprocess.run(["docker", "exec", "-i", DB, "psql", "-U", "postgres", "-qAt", "-v", "ON_ERROR_STOP=1"], input=sql.encode("utf-8"), capture_output=True)
    if r.returncode:
        raise IsolationError("psql failed: " + r.stderr.decode("utf-8", "replace")[:600])
    return r.stdout.decode("utf-8").strip()


SYN_USERS = f"(select id from auth.users where {SYN_EMAIL_SQL})"
SYN_CAMPS = "(select id from public.campaigns where name in (" + ",".join(f"'{c}'" for c in SYNTH_CAMPAIGNS) + f") or created_by in {SYN_USERS})"


def table_digests():
    """md5 of every public base table (rows sorted as text): the protected state."""
    tables = psql("select table_name from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' order by 1").split()
    sql = " union all ".join(f"select '{t}', count(*)::text || ':' || coalesce(md5(string_agg(x::text, '|' order by x::text)), '-') from public.{t} x" for t in tables)
    return dict(line.split("|", 1) for line in psql(sql).splitlines())


def residue():
    """Synthetic rows still present (by owner, campaign or creator)."""
    q = f"""select 'users', count(*) from auth.users where {SYN_EMAIL_SQL}
      union all select 'campaigns', count(*) from public.campaigns where id in {SYN_CAMPS}
      union all select 'characters', count(*) from public.characters where owner_id in {SYN_USERS} or campaign_id in {SYN_CAMPS}
      union all select 'items', count(*) from public.items where owner_id in {SYN_USERS}
      union all select 'dm_content', count(*) from public.dm_content where campaign_id in {SYN_CAMPS} or author_id in {SYN_USERS}
      union all select 'combat_encounters', count(*) from public.combat_encounters where campaign_id in {SYN_CAMPS}
      union all select 'combat_monster_favorites', count(*) from public.combat_monster_favorites where user_id in {SYN_USERS}"""
    return {k: int(v) for k, v in (line.split("|") for line in psql(q).splitlines()) if int(v)}


def cleanup():
    """Remove every synthetic row in dependency order (restrictive foreign keys first). Returns what was removed."""
    before = residue()
    psql(f"""begin;
      -- infused items: their modifiers are managed by Infuse Item and refuse a cascaded delete unless the managed flag is set
      set local tavern.managed_modifier = '1';
      delete from public.characters where owner_id in {SYN_USERS} or campaign_id in {SYN_CAMPS};
      delete from public.dm_content where campaign_id in {SYN_CAMPS} or author_id in {SYN_USERS};
      delete from public.combat_encounters where campaign_id in {SYN_CAMPS};   -- participants, effects, history, change log cascade
      delete from public.campaigns where id in {SYN_CAMPS};
      delete from public.items where owner_id in {SYN_USERS};
      delete from public.feat_versions where owner_id in {SYN_USERS};
      delete from public.feats where owner_id in {SYN_USERS};
      delete from public.background_versions where owner_id in {SYN_USERS};
      delete from public.backgrounds where owner_id in {SYN_USERS};
      delete from public.lineage_versions where owner_id in {SYN_USERS};
      delete from public.lineages where owner_id in {SYN_USERS};
      delete from public.creatures where owner_id in {SYN_USERS};
      delete from auth.users where {SYN_EMAIL_SQL};
      commit;""")
    return before


class Isolated:
    """with Isolated("ADV-UI-01") as iso: ...   (iso.note(...) adds journal details)"""

    def __init__(self, test_id, clean_first=True):
        self.test_id, self.clean_first, self.notes = test_id, clean_first, []

    def note(self, **kw):
        self.notes.append(kw)

    def __enter__(self):
        left = residue()
        if left:
            if not self.clean_first:
                raise IsolationError(f"{self.test_id}: synthetic residue from an earlier run: {left}")
            self.notes.append({"pre_cleanup": cleanup()})
        self.before = table_digests()
        self.t0 = time.time()
        return self

    def __exit__(self, exc_type, exc, tb):
        removed = cleanup()
        left = residue()
        after = table_digests()
        changed = sorted(t for t in set(self.before) | set(after) if self.before.get(t) != after.get(t))
        entry = {"test": self.test_id, "started": self.t0, "seconds": round(time.time() - self.t0, 1), "removed": removed,
                 "residue_after": left, "protected_tables_changed": changed, "test_error": repr(exc) if exc else None, "notes": self.notes}
        JOURNAL.parent.mkdir(parents=True, exist_ok=True)
        with JOURNAL.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry, default=str) + "\n")
        if left or changed:
            raise IsolationError(f"{self.test_id}: cleanup incomplete or protected data changed: residue={left} changed_tables={changed}")
        return False
