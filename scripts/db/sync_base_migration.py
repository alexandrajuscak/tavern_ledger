"""Keep the baseline migration identical to supabase/schema.sql.

schema.sql is the hand-run base schema that the live project already has. For the Supabase CLI it is
also the first migration (20261015000000_base_schema.sql) so a new local/test project can be built with
`supabase db reset` instead of pasting SQL. On the live project that version is marked as applied with
`supabase migration repair --status applied 20261015000000` (documented, never run automatically).

  python scripts/db/sync_base_migration.py          # (re)write the baseline
  python scripts/db/sync_base_migration.py --check  # exit 1 if it drifted
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "supabase" / "schema.sql"
DST = ROOT / "supabase" / "migrations" / "20261015000000_base_schema.sql"
HEADER = ("-- GENERATED from supabase/schema.sql by scripts/db/sync_base_migration.py - do not edit.\n"
          "-- Baseline: on the live project mark it applied with `supabase migration repair --status applied 20261015000000`.\n\n")


def main():
    want = HEADER + SRC.read_text(encoding="utf-8")
    if "--check" in sys.argv:
        ok = DST.exists() and DST.read_text(encoding="utf-8") == want
        print("baseline in sync" if ok else "baseline DRIFTED from schema.sql")
        sys.exit(0 if ok else 1)
    DST.write_text(want, encoding="utf-8", newline="\n")
    print("baseline written:", DST.name)


if __name__ == "__main__":
    main()
