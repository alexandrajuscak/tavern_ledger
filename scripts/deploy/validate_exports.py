"""Validate character export files before a production switch (docs/DEPLOYMENT_CHARACTER_EXPORT_MANIFEST.md).

For every *.json in EXPORT_DIR:
  1. it parses as JSON (the original file is never modified);
  2. the app's own import parser accepts it (parseCharacterJson from js/transfer.js, run in a browser page served by the
     local frontend server; no database is touched);
  3. the required sections are present (name, class / classes, level, abilities, combat.hp);
  4. no hidden DM data is present (keys such as dm_notes, curse, hidden, secrets, true_name);
  5. derived values are recorded as "informational" (they are recalculated on import);
  6. SHA-256.
Writes manifest.json and manifest.md next to the files (outside Git) and prints a summary.

Usage:  APP_URL=http://127.0.0.1:5191/ python scripts/deploy/validate_exports.py <EXPORT_DIR>
"""
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from playwright.sync_api import sync_playwright

APP = os.environ.get("APP_URL", "http://127.0.0.1:5191/")
HIDDEN_KEYS = {"dm_notes", "dmnotes", "curse", "curses", "secret", "secrets", "true_name", "truename", "hidden", "dm_only",
               "revealed_properties", "unrevealed", "dm_note"}


def hidden_paths(o, path=""):
    out = []
    if isinstance(o, dict):
        for k, v in o.items():
            p = f"{path}.{k}" if path else k
            if k.lower() in HIDDEN_KEYS:
                out.append(p)
            out += hidden_paths(v, p)
    elif isinstance(o, list):
        for i, v in enumerate(o):
            out += hidden_paths(v, f"{path}[{i}]")
    return out


def main(folder):
    folder = Path(folder)
    files = sorted(f for f in folder.glob("*.json") if not f.name.startswith("manifest"))
    rows = []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        page = browser.new_page()
        page.route("**/*supabase.co/**", lambda r: r.abort())          # never reach a hosted project from this tool
        page.goto(APP)
        page.wait_for_timeout(1500)
        for f in files:
            raw = f.read_bytes()
            row = {"file": f.name, "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw), "valid": False, "problems": []}
            try:
                j = json.loads(raw.decode("utf-8"))
            except Exception as e:                                       # noqa: BLE001 - any parse error is a finding
                row["problems"].append(f"not JSON: {e}")
                rows.append(row)
                continue
            row.update({"name": j.get("name"), "schema_version": j.get("schemaVersion"), "exported_at": j.get("exportedAt") or j.get("exported_at"),
                        "legacy_id": j.get("id"), "level": j.get("level") or (j.get("class") or {}).get("level") if isinstance(j.get("class"), dict) else j.get("level"),
                        "class": j.get("class") if isinstance(j.get("class"), str) else None,
                        "classes": [c.get("classVersion") for c in j.get("classes", [])] if isinstance(j.get("classes"), list) else None,
                        "race_text": j.get("race"), "lineage": (j.get("lineage") or {}).get("version") if isinstance(j.get("lineage"), dict) else None,
                        "background_text": j.get("background") if isinstance(j.get("background"), str) else None,
                        "background_version": (j.get("backgroundVersion") or {}).get("version") if isinstance(j.get("backgroundVersion"), dict) else None,
                        "feats": len(j.get("feats") or []), "spells": len(j.get("spells") or []) if isinstance(j.get("spells"), list) else None,
                        "catalog_spells": len(j.get("catalogSpells") or []), "inventory": len(j.get("inventory") or []),
                        "custom_refs": sum(1 for it in (j.get("inventory") or []) if isinstance(it, dict) and (it.get("custom") or it.get("homebrew")))})
            for key in ("name", "abilities", "combat"):
                if key not in j:
                    row["problems"].append(f"missing section: {key}")
            if not (j.get("class") or j.get("classes")):
                row["problems"].append("missing class / classes")
            hid = hidden_paths(j)
            if hid:
                row["problems"].append("hidden DM data present: " + ", ".join(hid[:5]))
            parsed = page.evaluate("""async (txt) => { const m = await import('./js/transfer.js?v=26');
                try { const p = m.parseCharacterJson(JSON.parse(txt)); return { ok: true, name: p.character.name, level: p.character.level,
                  hp_max: p.character.hp_max, ac: p.character.ac, attacks: p.attacks.length, spells: p.spells.length, inventory: p.inventory.length,
                  lineage: !!p.lineage, classes: p.classes.length }; }
                catch (e) { return { ok: false, error: String(e.message || e) }; } }""", raw.decode("utf-8"))
            row["parser"] = parsed
            if not parsed.get("ok"):
                row["problems"].append("import parser refused: " + parsed.get("error", "?"))
            row["derived_values_informational"] = {"hp_max": parsed.get("hp_max"), "ac": parsed.get("ac")}
            row["valid"] = not row["problems"]
            rows.append(row)
        browser.close()
    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    (folder / "manifest.json").write_text(json.dumps({"validated_at": stamp, "files": rows}, indent=1, ensure_ascii=False), encoding="utf-8")
    lines = [f"# Export manifest ({stamp})", "", "| File | Name | Class / level | SHA-256 (16) | Valid | Problems |", "|---|---|---|---|---|---|"]
    for r in rows:
        lines.append(f"| {r['file']} | {r.get('name')} | {r.get('class') or r.get('classes')} {r.get('level')} | {r['sha256'][:16]} | "
                     f"{'yes' if r['valid'] else '**NO**'} | {'; '.join(r['problems'])} |")
    (folder / "manifest.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    bad = [r for r in rows if not r["valid"]]
    print(f"{len(rows)} files, {len(rows) - len(bad)} valid, {len(bad)} invalid")
    for r in bad:
        print("INVALID", r["file"], r["problems"])
    sys.exit(1 if bad or not rows else 0)


if __name__ == "__main__":
    main(sys.argv[1])
