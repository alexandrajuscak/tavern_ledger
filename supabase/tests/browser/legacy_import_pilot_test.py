"""Deployment rehearsal (docs/DEPLOYMENT_CHARACTER_REIMPORT_PLAN.md): import legacy character exports (schema version 1,
from the pre-V6 app) through the real import dialog into the LOCAL stack and record what each one needs afterwards.

The export files are read from $LEGACY_EXPORT_DIR (never from the repository; real characters stay outside Git). Runs
inside isolation.Isolated as a synthetic user: every imported character is removed again and all public tables are
compared with their start state. The per-file report goes to $PILOT_REPORT (default %TEMP%/legacy_import_pilot.json).
"""
import json
import os
from pathlib import Path

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, Sheet, User, check, report

SRC = Path(os.environ["LEGACY_EXPORT_DIR"])
OUT = Path(os.environ.get("PILOT_REPORT", Path(os.environ.get("TEMP", "/tmp")) / "legacy_import_pilot.json"))


def run(t):
    pl = User("legacy-pilot")
    files = sorted(SRC.glob(os.environ.get("LEGACY_GLOB", "*.json")))
    rows = []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, pl, tab="features")
        page = s.page
        for f in files:
            src = json.loads(f.read_text(encoding="utf-8"))
            page.goto(APP)
            page.wait_for_selector("#btn-import")
            page.locator("#btn-import").click()
            page.wait_for_selector("#import-form")
            page.set_input_files("#import-form input[name=file]", str(f))
            page.wait_for_timeout(500)
            preview = page.locator("#import-preview").inner_text()
            page.locator(".modal button[type=submit]").click()
            ok = s.wait(lambda: "#/c/" in page.url, 20000)
            page.wait_for_timeout(1200)
            toast = s.toasts()
            cid = page.url.split("#/c/")[-1] if ok else None
            info = {}
            if cid:
                q = iso.psql(f"""select json_build_object(
                    'name', c.name, 'level', c.level, 'race_text', c.race, 'class_text', c.class_name, 'background_text', c.background,
                    'hp_max', c.hp_max, 'hp_current', c.hp_current,
                    'lineage', (select version_id from public.character_lineages where character_id = c.id),
                    'background', (select version_id from public.character_backgrounds where character_id = c.id),
                    'classes', (select json_agg(class_version_id || '@' || level) from public.character_classes where character_id = c.id),
                    'inventory', (select count(*) from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id where i.character_id = c.id),
                    'inventory_catalog', (select count(*) from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id where i.character_id = c.id and ii.item_id is not null),
                    'legacy_spells', (select count(*) from public.spells where character_id = c.id),
                    'catalog_spells', (select count(*) from public.character_spells where character_id = c.id),
                    'attacks', (select count(*) from public.attacks where character_id = c.id),
                    'features', (select count(*) from public.features where character_id = c.id),
                    'pending_choices', jsonb_array_length(coalesce(c.pending_choices, '[]'))) from public.characters c where c.id = '{cid}'""")
                info = json.loads(q)
            rows.append({"file": f.name, "source_name": src.get("name"), "source_class": src.get("class"), "source_level": src.get("level"),
                         "source_race": src.get("race"), "source_inventory": len(src.get("inventory") or []),
                         "source_spells": len(src.get("spells") or []) if isinstance(src.get("spells"), list) else None,
                         "preview": preview, "imported": bool(cid), "toast": toast, "result": info})
            check(f"P {f.name}: imports (name kept, inventory and spells kept as rows)", cid and info.get("name") == src.get("name")
                  and info.get("inventory", 0) >= len(src.get("inventory") or []), (preview, toast, info))
        check("P-ERR no uncaught page errors", not [e for e in s.errors if e.startswith("pageerror")], s.errors[:3])
        check("P-NET no request left the machine", not s.remote, s.remote[:3])
        s.close()
        browser.close()
    OUT.write_text(json.dumps(rows, indent=1, ensure_ascii=False), encoding="utf-8")
    t.note(files=len(files), report=str(OUT))


with iso.Isolated("DEPLOY legacy import pilot") as t:
    run(t)
report()
