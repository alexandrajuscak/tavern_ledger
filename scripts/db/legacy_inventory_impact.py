"""Writes data/reports/legacy_inventory_impact.json.

Where each legacy inventory_items column is used (frontend code, seed SQL, character files) and what happens to it.
Character files are private: only aggregate counts are written, never names or values.
"""
import collections
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COLS = ["id", "character_id", "name", "quantity", "weight", "description", "equipped", "sort_order", "created_at", "updated_at"]
PLAN = {
    "id": ("keep", "primary key", "unchanged"),
    "character_id": ("keep (derived)", "frontend reads and realtime-filters by it; seed and import write it",
                     "kept and filled by the trigger from inventory_id; clients may set it on INSERT only (legacy path), never UPDATE; "
                     "can be dropped once the frontend reads by inventory_id"),
    "name": ("keep (fallback)", "display name of free-text rows; filled from the catalog when item_id is set",
             "stays as the display/fallback name; custom names go to custom_name; could become nullable for catalog rows later"),
    "quantity": ("keep", "core field", "new writes must be >= 1; legacy 0 rows keep 0 until reviewed; global CHECK (quantity >= 1) after the cleanup"),
    "weight": ("redundant for catalog rows", "per-unit weight typed by the user",
               "catalog rows use items.weight_lb in the views; the column stays for free-text rows; copied from the catalog on insert"),
    "description": ("keep (legacy notes)", "free text", "new code writes notes; description stays for legacy rows; merge into notes in a later cleanup"),
    "equipped": ("read-only projection", "checkbox in the inventory list",
                 "character_equipment is the only truth; the column is recomputed on every write (client values ignored); drop in phase 3"),
    "sort_order": ("keep", "manual ordering", "unchanged"),
    "created_at": ("keep", "", "unchanged"),
    "updated_at": ("keep", "", "unchanged"),
}


def uses(text, file):
    out = collections.defaultdict(list)
    for n, line in enumerate(text.splitlines(), 1):
        if "inventory" not in line and "B.inventory" not in line and "item" not in line.lower():
            continue
        for c in COLS:
            if re.search(rf"\b{c}\b", line):
                out[c].append(f"{file}:{n}")
    return out


def main():
    frontend = collections.defaultdict(list)
    for p in sorted((ROOT / "js").glob("*.js")):
        src = p.read_text(encoding="utf-8")
        if "inventory" not in src:
            continue
        for c, refs in uses(src, f"js/{p.name}").items():
            frontend[c] += refs
    seed_cols = []
    seed = ROOT.parent / "seed_characters.sql"
    if seed.exists():
        m = re.search(r"insert into public\.inventory_items \(([^)]*)\)", seed.read_text(encoding="utf-8"))
        seed_cols = [c.strip() for c in m.group(1).split(",")] if m else []

    # private character files: aggregate counts only
    names = set()
    agg = collections.Counter()
    items = {i["name"].lower(): i["id"] for i in json.loads((ROOT / "data" / "normalized" / "normalized_items.json").read_text(encoding="utf-8"))}
    for d in (ROOT / "examples", ROOT.parent / "Char_JSON"):
        for p in sorted(d.glob("*.json")) if d.exists() else []:
            try:
                data = json.loads(p.read_text(encoding="utf-8"))
            except ValueError:
                continue
            agg["character_files"] += 1
            for it in data.get("inventory", []):
                it = {"name": it} if isinstance(it, str) else it
                agg["rows"] += 1
                agg["rows_equipped"] += bool(it.get("equipped"))
                agg["rows_quantity_0"] += it.get("quantity", 1) == 0
                agg["rows_with_weight"] += "weight" in it
                agg["rows_with_description"] += bool(it.get("description"))
                names.add(it.get("name", "").strip().lower())
    agg["distinct_names"] = len(names)
    agg["distinct_names_exact_catalog_match"] = sum(1 for n in names if n in items)

    report = {
        "columns": [{"column": c, "status": PLAN[c][0], "current_use": PLAN[c][1], "transition": PLAN[c][2],
                     "frontend_references": frontend.get(c, []), "written_by_seed_characters_sql": c in seed_cols}
                    for c in COLS],
        "frontend_access": {
            "read": "store.js: from('inventory_items').select('*').eq('character_id', id); realtime filter character_id=eq.<id>",
            "insert": "sheet.js '+ Add item': {character_id, name:'New item', sort_order}; transfer.js import: {character_id, name, quantity, weight, equipped, description, sort_order}",
            "update": "sheet.js field binds: name, quantity (min 0), weight, description, equipped (checkbox)",
            "delete": "sheet.js delete-item by id",
            "derived_client_side": "total weight = sum(weight * quantity) over all rows",
        },
        "breaking_for_current_frontend": [
            "quantity 0 can no longer be saved (the number input allows 0): the update is rejected; the UI shows the save error",
            "the equipped checkbox no longer persists (the value is ignored); after a reload it shows the real equipment state",
            "a JSON import with quantity 0 rows fails for those rows",
            "the catalog has 1146 rows; PostgREST returns at most 1000 rows per request, so a future catalog fetch must paginate",
        ],
        "character_files_aggregate": dict(agg),
        "seed_characters_sql_columns": seed_cols,
    }
    out = ROOT / "data" / "reports" / "legacy_inventory_impact.json"
    out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8", newline="\n")
    print("legacy impact ok:", dict(agg))


if __name__ == "__main__":
    main()
