"""Focused smoke test of the LOCAL development environment started by scripts/start-local.ps1.

Unlike inventory_ui_test.py it injects NO Supabase settings: the app must find the local stack by itself
(js/config.local.js), exactly as when a developer opens http://127.0.0.1:5173/. A fresh synthetic user signs up through
the UI. The legacy check uses the demo data of scripts/seed-local-demo.ps1 (Local Hero), if present.
Read-only database checks go through `docker exec` into the local container. Every request is recorded: any request to
a non-local Supabase host, or any privileged key in a request, fails the test.
Run from a throwaway venv with playwright (drives installed Microsoft Edge):
  <venv>\\Scripts\\python.exe supabase/tests/browser/local_dev_smoke_test.py
"""
import base64
import json
import os
import re
import subprocess
import sys
import time
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright, expect

sys.stdout.reconfigure(encoding="utf-8")
APP = os.environ.get("APP_URL", "http://127.0.0.1:5173/")
if urlparse(APP).hostname not in ("127.0.0.1", "localhost"):
    sys.exit(f"refusing to run: {APP} is not local")
DB = "supabase_db_tavern_ledger"
RUN = str(int(time.time()))
EMAIL, PW = f"local-smoke-{RUN}@example.test", "local-dev-password"
LOCAL = ("127.0.0.1", "localhost")
STATIC_CDNS = ()   # fonts and supabase-js are self-hosted since v6.1: no static CDN is expected
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(("PASSED  " if ok else "FAILED  ") + name + ("" if ok else f"   <-- {detail}"), flush=True)


def sql(q):
    return subprocess.run(["docker", "exec", DB, "psql", "-U", "postgres", "-At", "-q", "-c", q],
                          capture_output=True, text=True, check=True).stdout.strip()


def privileged(token):
    if not token:
        return False
    if token.startswith("sb_secret_"):
        return True
    try:
        part = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))).get("role") == "service_role"
    except Exception:  # noqa: BLE001
        return False


def main():
    errors, remote, bad_keys, supabase_hosts = [], [], [], set()
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)

        def context():
            ctx = browser.new_context(viewport={"width": 1366, "height": 900})
            ctx.add_init_script("localStorage.setItem('tavern-ledger:tab', 'inventory');")   # UI preference only

            def on_request(r):
                host = urlparse(r.url).hostname or ""
                if host not in LOCAL and host not in STATIC_CDNS:
                    remote.append(r.url)
                if "/rest/v1/" in r.url or "/auth/v1/" in r.url or "/realtime/v1/" in r.url:
                    supabase_hosts.add(f"{urlparse(r.url).scheme}://{urlparse(r.url).netloc}")
                h = r.headers
                for tok in (h.get("apikey"), (h.get("authorization") or "").removeprefix("Bearer ")):
                    if privileged(tok):
                        bad_keys.append(r.url)
            ctx.on("request", on_request)
            page = ctx.new_page()
            page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
            page.on("pageerror", lambda e: errors.append(f"pageerror: {e}"))
            return page

        def wait_idle(page):
            page.wait_for_timeout(300)
            page.wait_for_function("!document.querySelector('#inventory-app [aria-busy=true]')", timeout=15000)
            page.wait_for_timeout(500)

        def row(page, name):
            return page.locator(".inv-item", has=page.locator(".inv-item-name", has_text=re.compile(f"^{re.escape(name)}$"))).first

        def add(page, name, qty=1):
            page.select_option("select[name=kindId]", "")
            page.fill("input[name=search]", name)
            page.wait_for_function("""(n) => { const r = [...document.querySelectorAll('.inv-result b')];
                return r.length > 0 && r.every(b => b.textContent.toLowerCase().includes(n.toLowerCase()))
                  && !/Searching|Loading/.test(document.querySelector('[data-status]').textContent); }""", arg=name, timeout=15000)
            item = page.locator(".inv-result", has=page.locator("b", has_text=re.compile(f"^{re.escape(name)}$"))).first
            item.locator("[data-qty]").fill(str(qty))
            item.locator("[data-pick]").click()
            expect(page.locator(".toast", has_text=f"Added {qty} × {name}")).to_be_visible(timeout=10000)

        # 1-3. app opens on localhost, modules load, local config is used
        page = context()
        page.goto(APP)
        page.wait_for_selector("#auth-form", timeout=20000)
        check("1 Tavern Ledger opens on localhost (sign-in screen)", page.title() == "Tavern Ledger")
        cfg = page.evaluate("import('./js/config.local.js').then(m => ({url: m.LOCAL_SUPABASE_URL, key: m.LOCAL_SUPABASE_ANON_KEY}))")
        check("2 JavaScript modules load (no page error) and js/config.local.js is local",
              not [e for e in errors if e.startswith("pageerror")] and urlparse(cfg["url"]).hostname in LOCAL, (errors[:3], cfg["url"]))
        check("20a browser configuration holds no service_role / secret key", not privileged(cfg["key"])
              and "service_role" not in page.content(), "privileged key in config")

        # 4. sign up through the UI (local Auth, no e-mail confirmation)
        page.fill("input[name=email]", EMAIL)
        page.fill("input[name=password]", PW)
        page.click("button[value=signup]")
        try:
            page.wait_for_selector("#btn-new, #btn-new-empty", timeout=20000)
            ok = True
        except Exception:  # noqa: BLE001
            ok = False
        check("4 a synthetic local user signs up and is signed in immediately", ok, errors[-3:])

        # 5. create a character through the UI
        page.locator("#btn-new, #btn-new-empty").first.click()
        page.fill("#new-char input[name=name]", f"Smoke Ranger {RUN}")
        page.locator(".modal button[type=submit][form=new-char]").click()
        # the new-character steps (lineage, class) can be skipped and finished later on Build
        page.locator(".modal [data-nc-skip]").click()
        page.wait_for_selector(".modal [data-nc-class]", timeout=15000)
        page.locator(".modal [data-nc-skip]").click()
        page.locator(".modal [data-nc-open]").click()
        page.wait_for_url(re.compile(r"#/c/"), timeout=15000)
        cid = page.url.split("#/c/")[1]
        page.wait_for_selector(".inv", timeout=20000)
        page.wait_for_function("!document.querySelector('#inventory-app .spinner')", timeout=20000)
        check("5 a synthetic character is created and opened", bool(cid))
        check("6 inventory opens", page.locator(".inv").is_visible())
        # since 20261019000100 only DMs author mechanical items (steps 10-14): the user DMs a campaign of their own
        sql(f"insert into public.campaigns (name, created_by) select 'UI Test Campaign', id from auth.users where email = '{EMAIL}';"
            f"insert into public.campaign_members (campaign_id, user_id, role) select c.id, c.created_by, 'dm' from public.campaigns c"
            f" join auth.users u on u.id = c.created_by where u.email = '{EMAIL}'")
        page.reload()
        page.wait_for_selector(".inv", timeout=20000)
        page.wait_for_function("!document.querySelector('#inventory-app .spinner')", timeout=20000)

        # 7-9. catalog, pagination, official item
        page.get_by_role("button", name="+ Add item").click()
        status = page.locator("[data-status]")
        expect(status).to_have_text(re.compile(r"Showing 50 of 1146 items"), timeout=15000)
        check("7 the official catalog loads (1146 items)", True)
        page.locator("[data-more]").click()
        expect(status).to_have_text(re.compile(r"Showing 100 of 1146"), timeout=15000)
        ids = page.locator(".inv-result").evaluate_all("els => els.map(e => e.dataset.id)")
        check("8 catalog pagination: Load more appends 50 without duplicates", len(ids) == 100 == len(set(ids)), len(ids))
        add(page, "Longsword", 1)
        add(page, "Potion of Healing", 2)
        page.locator(".modal [data-close]").first.click()
        wait_idle(page)
        check("9 an official item is added", row(page, "Longsword").count() == 1)

        # 10-14. private homebrew
        hb = f"Smoke Moonblade {RUN}"
        page.get_by_role("button", name="+ Add item").click()
        page.locator("[data-create]").click()
        page.wait_for_selector(".hb-form", timeout=10000)
        page.fill("#hb-name", hb)
        page.locator(".modal input[name=visibility][value=private]").check()
        page.locator(".modal [data-submit]").click()
        try:
            expect(page.locator(".toast", has_text=f"Created {hb}")).to_be_visible(timeout=15000)
            ok = True
        except Exception:  # noqa: BLE001
            ok = False
        wait_idle(page)
        check("10 a private homebrew item is created", ok and sql(f"select count(*) from public.items where name = '{hb}' and campaign_id is null "
                                                              "and data_source_id = 'homebrew'") == "1", errors[-3:])
        page.get_by_role("button", name="+ Add item").click()
        page.select_option("select[name=visibility]", "private")
        expect(status).to_have_text(re.compile(r"Showing 1 of 1 item"), timeout=15000)
        check("11 the homebrew item appears in My Homebrew", hb in page.locator(".inv-results").inner_text())
        page.locator(".inv-result", has=page.locator("b", has_text=hb)).locator("[data-pick]").click()
        expect(page.locator(".toast", has_text=f"Added 1 × {hb}")).to_be_visible(timeout=10000)
        page.locator(".modal [data-close]").first.click()
        wait_idle(page)
        check("12 the homebrew item is added to the inventory (created copy + one added from My Homebrew)",
              page.locator(".inv-item-name", has_text=hb).count() == 2)
        row(page, hb).locator(".inv-item-main").click()
        page.wait_for_selector(".modal [data-form=text]")
        page.fill(".modal input[name=custom_name]", "Grandpa's smoke blade")
        page.locator(".modal [data-form=text] button[type=submit]").click()
        expect(page.locator(".toast", has_text="Saved.")).to_be_visible(timeout=10000)
        wait_idle(page)
        check("13 the inventory-instance custom name is changed", page.locator(".inv-item-name", has_text="Grandpa's smoke blade").count() == 1)
        check("14 the custom name does not change the catalog definition",
              sql(f"select count(*) from public.items where name = '{hb}'") == "1"
              and sql("select count(*) from public.items where name = 'Grandpa''s smoke blade'") == "0")

        # 15. equip / unequip
        row(page, "Longsword").locator("[data-inv=equip]").click()
        pick = page.locator(".inv-pick-item[data-slot=main_hand]")
        try:
            pick.wait_for(timeout=3000)
            pick.click()
        except Exception:  # noqa: BLE001
            pass   # equipped directly without a slot choice
        wait_idle(page)
        main_hand = page.locator(".inv-slot", has=page.locator(".inv-slot-name", has_text=re.compile("^Main Hand$")))
        equipped = "Longsword" in main_hand.inner_text()
        main_hand.locator("[data-inv=slot-unequip]").click()
        wait_idle(page)
        check("15 an item is equipped (Main Hand) and unequipped", equipped and "Longsword" not in main_hand.inner_text(), main_hand.inner_text())

        # 16. potion
        row(page, "Potion of Healing").locator("[data-inv=use]").click()
        page.wait_for_selector(".modal .inv-effects", timeout=10000)
        page.locator(".modal .btn-gold[data-close]").click()
        wait_idle(page)
        check("16 a potion is used (2 -> 1)", row(page, "Potion of Healing").locator(".inv-qty-n").inner_text() == "1")

        # 18. focus restoration after closing a modal
        focus_key = "document.activeElement?.dataset?.focusKey || document.activeElement?.tagName"
        rid = row(page, "Longsword").get_attribute("data-row")
        key = f"inventory-item:{rid}:details"
        page.locator(f'[data-focus-key="{key}"]').click()
        page.wait_for_selector(".modal")
        page.keyboard.press("Escape")
        page.wait_for_timeout(1500)
        check("18 focus returns to the item after closing its modal", page.evaluate(focus_key) == key, page.evaluate(focus_key))

        # 17. legacy item (demo data)
        hero = sql("select c.id from public.characters c join public.profiles p on p.id = c.owner_id "
                   "where p.email = 'local-player@example.test' and c.name = 'Local Hero' limit 1")
        if hero:
            demo = context()
            demo.goto(APP)
            demo.fill("input[name=email]", "local-player@example.test")
            demo.fill("input[name=password]", PW)
            demo.click("button[value=signin]")
            demo.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)
            demo.goto(f"{APP}#/c/{hero}")
            demo.wait_for_selector(".inv", timeout=20000)
            demo.wait_for_function("!document.querySelector('#inventory-app .spinner')", timeout=20000)
            demo.wait_for_timeout(800)
            check("17 the legacy demo item stays visible (marked legacy)",
                  demo.locator(".inv-item.legacy", has_text="Old Lucky Coin").count() == 1)
        else:
            print("NOT RUN 17 legacy item: no demo data (run scripts/seed-local-demo.ps1)")
        browser.close()

    relevant = [e for e in errors if "favicon" not in e]
    check("3 no uncaught browser errors or console errors", not relevant, relevant[:5])
    check("19 no browser request went to a hosted Supabase URL (Supabase traffic only to: "
          + ", ".join(sorted(supabase_hosts)) + ")", not remote and all(urlparse(h).hostname in LOCAL for h in supabase_hosts), remote[:5])
    check("20b no service_role / secret key in browser traffic", not bad_keys, bad_keys[:3])
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed  (user {EMAIL}, character {cid})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
