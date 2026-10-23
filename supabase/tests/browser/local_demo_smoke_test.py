"""Focused smoke test of the LOCAL demo data for manual testing (docs/LOCAL_MANUAL_TESTING.md).

Runs in Microsoft Edge against the running local stack and the demo characters of scripts/seed-local-demo.ps1, signed in
as the local demo player. Deterministic and self-restoring (v6.1): before the checks it snapshots every row of the three demo
characters it changes (Local Hero, Local Wizard, Local Warlock), sets the slot state the checks expect, and afterwards puts
the exact rows back (triggers off, so timestamps and history match) and verifies that no table kept extra rows. Whatever the
demo characters looked like before (seeded or edited by hand) is what they look like after. Records every request host and
fails on anything that is not local (fonts and supabase-js are self-hosted). Refuses non-local URLs.

    API_URL=... ANON_KEY=... python supabase/tests/browser/local_demo_smoke_test.py
"""
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

sys.stdout.reconfigure(encoding="utf-8")
API = os.environ["API_URL"].rstrip("/")
ANON = os.environ["ANON_KEY"]
APP = os.environ.get("APP_URL", "http://127.0.0.1:5173/")
SHOTS = Path(os.environ.get("SCREENSHOT_DIR", "."))
for u in (API, APP):
    if urlparse(u).hostname not in ("127.0.0.1", "localhost"):
        sys.exit(f"refusing to run: {u} is not local")
EMAIL, PW = "local-player@example.test", "local-dev-password"   # synthetic, LOCAL ONLY
CDN = ()   # everything is self-hosted since v6.1 (fonts, supabase-js)
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(("PASSED  " if ok else "FAILED  ") + name + ("" if ok else f"   <-- {detail}"), flush=True)


DB = "supabase_db_tavern_ledger"
TOUCHED = ["Local Hero", "Local Wizard", "Local Warlock"]   # the demo characters this test changes


def psql(sql):
    r = subprocess.run(["docker", "exec", "-i", DB, "psql", "-U", "postgres", "-qAt", "-v", "ON_ERROR_STOP=1"], input=sql.encode("utf-8"), capture_output=True)
    if r.returncode:
        raise SystemExit("psql failed: " + r.stderr.decode("utf-8", "replace")[:500])
    return r.stdout.decode("utf-8").strip()


def child_tables():
    return psql("""select c.table_name from information_schema.columns c join information_schema.tables t using (table_schema, table_name)
      where c.table_schema = 'public' and c.column_name = 'character_id' and t.table_type = 'BASE TABLE' order by 1""").split()


def inventory_tables():
    """Tables keyed by inventory (inventory_events …) without a character_id of their own."""
    return psql("""select c.table_name from information_schema.columns c join information_schema.tables t using (table_schema, table_name)
      where c.table_schema = 'public' and c.column_name = 'inventory_id' and t.table_type = 'BASE TABLE'
        and c.table_name not in (select table_name from information_schema.columns where table_schema = 'public' and column_name = 'character_id')
      order by 1""").split()


def row_counts():
    tables = psql("select table_name from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' order by 1").split()
    out = psql(" union all ".join(f"select '{t}', count(*) from public.{t}" for t in tables))
    return dict(line.split("|") for line in out.splitlines())


def snapshot(ids):
    lst = ",".join(f"'{i}'" for i in ids)
    snap = {"characters": psql(f"select coalesce(json_agg(t), '[]') from public.characters t where id in ({lst})")}
    for t in child_tables():
        snap[t] = psql(f"select coalesce(json_agg(t), '[]') from public.{t} t where character_id in ({lst})")
    for t in inventory_tables():
        snap["inv:" + t] = psql(f"select coalesce(json_agg(t), '[]') from public.{t} t where inventory_id in (select id from public.inventories where character_id in ({lst}))")
    return snap


def restore(snap, ids):
    """Put the exact rows back in one transaction with triggers off (no audit rows, timestamps as before)."""
    lst = ",".join(f"'{i}'" for i in ids)
    sql = ["begin;", "set local session_replication_role = replica;"]
    for name, rows in snap.items():
        t = name.removeprefix("inv:")
        where = (f"id in ({lst})" if t == "characters" else f"character_id in ({lst})" if not name.startswith("inv:")
                 else f"inventory_id in (select id from public.inventories where character_id in ({lst}))")
        sql.append(f"delete from public.{t} where {where};")
        # identity columns are GENERATED ALWAYS: the original ids go back unchanged
        sql.append(f"insert into public.{t} overriding system value select * from json_populate_recordset(null::public.{t}, $snap${rows}$snap$);")
    sql.append("commit;")
    psql("\n".join(sql))


def demo_ids():
    def call(method, path, body=None, token=ANON):
        r = urllib.request.Request(API + path, data=json.dumps(body).encode() if body is not None else None, method=method,
                                   headers={"apikey": ANON, "Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        with urllib.request.urlopen(r, timeout=30) as x:
            return json.loads(x.read().decode() or "null")
    tok = call("POST", "/auth/v1/token?grant_type=password", {"email": EMAIL, "password": PW})["access_token"]
    return {c["name"]: c["id"] for c in call("GET", "/rest/v1/characters?select=id,name", token=tok)}


def main():
    ids = demo_ids()
    need = ["Local Hero", "Local Sidekick", "Local Spellcaster", "Local Wizard", "Local Artificer", "Local Paladin", "Local Warlock", "Local Multiclass"]
    if any(n not in ids for n in need):
        sys.exit(f"demo characters missing ({[n for n in need if n not in ids]}): run .\\scripts\\seed-local-demo.ps1 first")
    SHOTS.mkdir(parents=True, exist_ok=True)
    touched = [ids[n] for n in TOUCHED]
    before_counts = row_counts()
    snap = snapshot(touched)
    # establish the slot state the checks expect (instead of assuming the seeded state survived earlier sessions)
    wiz, wl = ids["Local Wizard"], ids["Local Warlock"]
    psql(f"""update public.character_spell_slot_state set expended = case slot_level when 1 then 1 else 0 end
               where character_id = '{wiz}' and pool = 'standard';
             update public.character_spell_slot_state set expended = 1 where character_id = '{wl}' and pool = 'pact';""")
    try:
        run_checks(ids, need)
    finally:
        restore(snap, touched)
        after = snapshot(touched)
        rows = lambda j: sorted(json.dumps(r, sort_keys=True) for r in json.loads(j))  # noqa: E731  (json_agg has no order)
        same = all(rows(after[t]) == rows(snap[t]) for t in snap)   # every table, incl. inventory events
        extra = {t: (before_counts.get(t), n) for t, n in row_counts().items() if n != before_counts.get(t)}
        check("23 the demo characters are exactly as before the test (rows restored) and no table kept extra rows", same and not extra, extra)
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


def run_checks(ids, need):
    errors, hosts = [], set()
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        ctx = browser.new_context(viewport={"width": 1366, "height": 900})
        ctx.add_init_script("localStorage.setItem('tavern-ledger:tab', 'combat');")
        ctx.on("request", lambda r: hosts.add(urlparse(r.url).hostname))
        page = ctx.new_page()
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(f"pageerror: {e}"))

        def tab(name):
            page.locator(f'.tab[data-tab="{name}"]').click()
            page.wait_for_timeout(400)

        def open_char(name, tab_name=None):
            if tab_name:
                page.evaluate(f"localStorage.setItem('tavern-ledger:tab', '{tab_name}')")
            page.goto(f"{APP}#/c/{ids[name]}")
            page.wait_for_selector(".sheet-header", timeout=20000)
            page.wait_for_timeout(1200)

        def wait_text(sel, text, timeout=15):
            t0 = time.time()
            while time.time() - t0 < timeout:
                if text in page.locator(sel).inner_text():
                    return True
                page.wait_for_timeout(200)
            return False

        # 1-3 load, login, character list
        page.goto(APP)
        check("1 Tavern Ledger loads on localhost", page.locator("input[name=email]").count() == 1)
        page.fill("input[name=email]", EMAIL)
        page.fill("input[name=password]", PW)
        page.click("button[value=signin]")
        page.wait_for_selector(".char-card", timeout=20000)
        check("2 local demo login works", page.locator(".char-card").count() >= 8)
        names = page.locator(".char-card").all_inner_texts()
        check("3 the demo character list shows all eight demo characters", all(any(n in t for t in names) for n in need), names)

        # 4-7 inventory, AC, warnings
        open_char("Local Hero", "inventory")
        page.wait_for_selector(".inv-item", timeout=20000)
        inv = page.locator("#inventory-app").inner_text()
        check("4 Local Hero opens; inventory lists armor, weapons, potion, legacy and homebrew items",
              all(x in inv for x in ("Chain Mail", "Leather", "Scale Mail", "Shield", "Longsword", "Mace", "Shortbow", "Arrows",
                                      "Potion of Healing", "Ring of Protection", "Old Lucky Coin", "Local Moonblade")), inv[:400])
        arrows = page.locator(".inv-item", has=page.locator(".inv-item-name", has_text=re.compile("^Arrows$"))).first
        arrows.locator("[data-inv=inc]").click()
        ok_inc = wait_text("#inventory-app", "21")
        arrows.locator("[data-inv=dec]").click()
        page.wait_for_timeout(800)
        check("5 inventory works (Arrows 20 -> 21 -> 20 through the RPCs)", ok_inc and arrows.locator(".inv-qty-n").inner_text() == "20",
              arrows.inner_text())
        tab("combat")
        page.locator('[data-action="ac-breakdown"]').click()
        page.wait_for_selector(".modal", timeout=10000)
        body = page.locator(".modal").last.inner_text()
        check("6 AC breakdown opens: 18 = Chain Mail 16 + Shield 2", "18" in body and "Chain Mail" in body and "Shield" in body, body[:300])
        page.keyboard.press("Escape")
        page.wait_for_timeout(400)
        check("19 closing the dialog returns focus to the AC button",
              page.evaluate("document.activeElement?.dataset?.focusKey") == "ac-breakdown", page.evaluate("document.activeElement?.outerHTML?.slice(0,80)"))
        open_char("Local Sidekick", "combat")
        page.wait_for_function("() => (document.querySelector('[data-derived=\"ac-note\"]')?.textContent || '').trim().length > 0", timeout=20000)
        note = page.locator('[data-derived="ac-note"]').inner_text()
        page.locator('[data-action="ac-breakdown"]').click()
        page.wait_for_selector(".modal", timeout=10000)
        txt = page.locator(".modal").last.inner_text().lower()
        page.keyboard.press("Escape")
        check("7 proficiency warnings render (Local Sidekick: AC note + breakdown name the armor proficiency and Strength)",
              note.strip() and "proficien" in txt and "strength" in txt, (note, txt[:400]))

        # 8 lineage card
        open_char("Local Hero", "features")
        page.wait_for_selector("#lineage-card-body", timeout=20000)
        check("8 lineage card shows Mountain Dwarf", wait_text("#lineage-card", "Mountain Dwarf"), page.locator("#lineage-card").inner_text()[:200])

        # 9-11 spells
        open_char("Local Spellcaster", "spells")
        page.wait_for_selector("#spellbook-list .sp-card", timeout=20000)
        thaum = page.locator("#spellbook-list .sp-card", has=page.locator(".sp-name", has_text=re.compile("^Thaumaturgy$")))
        check("10 spellbook works: Thaumaturgy is one card with two grants (lineage + manual)", thaum.count() == 1 and thaum.locator(".sp-src").count() == 2,
              thaum.inner_text() if thaum.count() else "")
        art = page.locator("#spellcasting-sources .sp-source", has_text="Artificer").inner_text()
        check("11 Spell Save DC 14 and Spell Attack +6 for the Artificer source; Wand fixed DC 15",
              "14" in art and "+6" in art and "15" in page.locator("#spellcasting-sources .sp-source", has_text="Wand").inner_text(), art[:300])
        page.click("[data-action=spell-add]")
        page.wait_for_selector(".modal .sp-pick", timeout=20000)
        page.fill(".modal [data-cf=q]", "Cure")
        page.wait_for_timeout(400)
        check("9 the spell catalog loads and searches (Cure Wounds)", page.locator(".modal .sp-pick", has_text="Cure Wounds").count() >= 1)
        page.locator(".modal [data-close]").first.click()

        # 12-17 classes, slots, Pact Magic, rests
        open_char("Local Wizard", "features")
        check("12 Classes section loads (Wizard 5, proficiency +3)", wait_text("#class-card-body", "Level 5") and "Proficiency bonus +3" in page.locator("#class-card-body").inner_text())
        tab("spells")
        page.wait_for_selector("#slot-tracker [data-slot-pool=standard]", timeout=20000)
        std = "#slot-tracker [data-slot-pool=standard]"
        check("13 Spell Slot Tracker loads (1st 3 / 4 with one used; 2nd 3 / 3; 3rd 2 / 2)",
              all(x in page.locator(std).inner_text() for x in ("3 / 4 remaining", "3 / 3 remaining", "2 / 2 remaining")), page.locator(std).inner_text()[:300])
        page.locator("#slot-tracker [data-action=slot-use][data-level='2']").click()
        a = wait_text(std, "2 / 3 remaining")
        page.locator("#slot-tracker [data-action=slot-restore][data-level='2']").click()
        check("14 spending and restoring a standard slot works (2nd level 3 -> 2 -> 3)", a and wait_text(std, "3 / 3 remaining"))
        page.locator("#slot-tracker [data-action=long-rest]").click()
        page.locator(".modal [data-ok]").last.click()
        page.wait_for_selector(".modal [data-rest-summary]", timeout=15000); page.locator(".modal [data-rest-ok]").last.click(); page.wait_for_selector(".modal [data-rest-summary]", state="detached", timeout=5000)
        check("17 Long Rest restores the used 1st-level slot (4 / 4)", wait_text(std, "4 / 4 remaining"))
        open_char("Local Warlock", "spells")
        page.wait_for_selector("#slot-tracker [data-slot-pool=pact]", timeout=20000)
        pact = "#slot-tracker [data-slot-pool=pact]"
        check("15a Pact Magic is a separate panel (Slot level 3rd, 1 / 2 remaining) and there are no standard slots",
              "Slot level: 3rd" in page.locator(pact).inner_text() and "1 / 2 remaining" in page.locator(pact).inner_text()
              and page.locator("#slot-tracker [data-slot-pool=standard]").count() == 0, page.locator("#slot-tracker").inner_text()[:300])
        page.locator("#slot-tracker [data-action=pact-use]").click()
        check("15b spending a Pact slot works (0 / 2)", wait_text(pact, "0 / 2 remaining"))
        page.locator("#slot-tracker [data-action=short-rest]").click()
        dlg = page.locator(".modal").last.inner_text()
        page.locator(".modal [data-ok]").last.click()
        page.wait_for_selector(".modal [data-rest-summary]", timeout=15000); page.locator(".modal [data-rest-ok]").last.click(); page.wait_for_selector(".modal [data-rest-summary]", state="detached", timeout=5000)
        check("16 Short Rest restores Pact Magic (2 / 2) and says standard slots are not restored",
              wait_text(pact, "2 / 2 remaining") and "not restored" in dlg, dlg)

        # 20 mobile
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(500)
        ov1 = page.evaluate("() => document.documentElement.scrollWidth - document.documentElement.clientWidth")
        tab("inventory")
        ov2 = page.evaluate("() => document.documentElement.scrollWidth - document.documentElement.clientWidth")
        page.screenshot(path=str(SHOTS / "demo_smoke_mobile.png"))
        check("20 no horizontal overflow on a phone (Spells, Inventory)", ov1 <= 1 and ov2 <= 1, (ov1, ov2))

        # 22 no privileged key in the browser configuration
        cfg = page.evaluate("fetch('/js/config.local.js').then(r => r.text())")
        key = re.search(r"LOCAL_SUPABASE_ANON_KEY = '([^']+)'", cfg)
        role = json.loads(base64.urlsafe_b64decode(key.group(1).split(".")[1] + "==")).get("role") if key else None
        check("22 the browser config holds only the local URL and the local anon key (no service_role)",
              role == "anon" and "service_role" not in cfg and "127.0.0.1" in cfg, role)
        check("18 no uncaught console errors", not errors, errors)
        bad = sorted(h for h in hosts if h not in ("127.0.0.1", "localhost") and h not in CDN)
        check("21 all Supabase traffic is local (hosts: " + ", ".join(sorted(h for h in hosts if h)) + ")",
              not bad and not any("supabase.co" in (h or "") for h in hosts), bad)
        browser.close()


if __name__ == "__main__":
    main()
