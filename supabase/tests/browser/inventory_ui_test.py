"""Browser test of the inventory UI against a LOCAL Supabase stack.

Not a project dependency: run it from a throwaway virtualenv with `pip install playwright==1.55.0`.
It drives an installed Microsoft Edge (channel "msedge"), so no browser download is needed.
Run by supabase/tests/run_browser_local.sh, which provides API_URL / ANON_KEY / SERVICE_ROLE_KEY from
`supabase status` of the local stack and serves the app on http://localhost:<port>/. Refuses non-local URLs.
Synthetic users and characters only. Prints PASSED / FAILED per check; screenshots go to $SCREENSHOT_DIR.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright, expect

sys.stdout.reconfigure(encoding="utf-8")

API = os.environ["API_URL"].rstrip("/")
ANON = os.environ["ANON_KEY"]
SERVICE = os.environ["SERVICE_ROLE_KEY"]
APP = os.environ.get("APP_URL", "http://localhost:5173/")
SHOTS = Path(os.environ.get("SCREENSHOT_DIR", "."))
for u in (API, APP):
    if urlparse(u).hostname not in ("127.0.0.1", "localhost"):
        sys.exit(f"refusing to run: {u} is not local")
PW = "local-test-password-1!"
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(("PASSED  " if ok else "FAILED  ") + name + ("" if ok else f"   <-- {detail}"), flush=True)


def call(method, path, body=None, headers=None, token=SERVICE, key=SERVICE):
    h = {"apikey": key, "Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    h.update(headers or {})
    req = urllib.request.Request(API + path, data=json.dumps(body).encode() if body is not None else None, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def user(email):
    call("POST", "/auth/v1/admin/users", {"email": email, "password": PW, "email_confirm": True})
    st, body = call("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": PW}, token=ANON, key=ANON)
    return body["user"]["id"], body["access_token"]


def fixtures():
    rep = {"Prefer": "return=representation"}
    alice, _ = user("ui-alice@example.test")
    bob, _ = user("ui-bob@example.test")
    dm, _ = user("ui-dm@example.test")
    _, camp = call("POST", "/rest/v1/campaigns", {"name": "UI Test Campaign", "created_by": dm}, rep)
    camp = camp[0]["id"]
    call("POST", "/rest/v1/campaign_members", [{"campaign_id": camp, "user_id": u, "role": r}
                                              for u, r in ((alice, "player"), (bob, "player"), (dm, "dm"))])
    _, chars = call("POST", "/rest/v1/characters", [
        {"owner_id": alice, "name": "Empty Hero", "campaign_id": camp, "gp": 0, "sp": 0},
        {"owner_id": alice, "name": "Legacy Hero", "campaign_id": camp, "gp": 12, "sp": 5},
        {"owner_id": alice, "name": "Test Hero", "campaign_id": camp, "gp": 50, "sp": 0}], rep)
    ids = {c["name"]: c["id"] for c in chars}
    _, legacy = call("POST", "/rest/v1/inventory_items", [
        {"character_id": ids["Legacy Hero"], "name": "Quarterstaff", "quantity": 1, "weight": 4, "description": "worn smooth", "sort_order": 0},
        {"character_id": ids["Legacy Hero"], "name": "Leather Armor", "quantity": 1, "weight": 10, "description": "", "sort_order": 1},
        {"character_id": ids["Legacy Hero"], "name": "Letter from a dead colleague", "quantity": 1, "weight": 0, "description": "sealed", "sort_order": 2}], rep)
    armor = next(r for r in legacy if r["name"] == "Leather Armor")
    call("POST", "/rest/v1/legacy_inventory_review", {"inventory_item_id": armor["id"], "character_id": ids["Legacy Hero"],
         "legacy_name": "Leather Armor", "legacy_quantity": 1, "legacy_equipped": True, "category": "equipped_manual",
         "status": "manual_review", "detail": {"reason": "not linked to a catalog item"}})
    return ids


def main():
    ids = fixtures()
    SHOTS.mkdir(parents=True, exist_ok=True)
    errors = []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)

        def new_page(email, viewport=None):
            ctx = browser.new_context(viewport=viewport or {"width": 1366, "height": 900})
            ctx.add_init_script(f"localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({{url: {json.dumps(API)}, key: {json.dumps(ANON)}}}));"
                                "localStorage.setItem('tavern-ledger:tab', 'inventory');")
            page = ctx.new_page()
            page.on("console", lambda m: errors.append(f"{email}: {m.text}") if m.type == "error" else None)
            page.on("pageerror", lambda e: errors.append(f"{email}: {e}"))
            page.goto(APP)
            page.fill("input[name=email]", email)
            page.fill("input[name=password]", PW)
            page.click("button[value=signin]")
            page.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)
            return page

        def open_char(page, name):
            page.goto(f"{APP}#/c/{ids[name]}")
            page.wait_for_selector(".inv, .inv-state", timeout=20000)
            page.wait_for_function("!document.querySelector('#inventory-app .spinner')", timeout=20000)

        def toast_text(page):
            page.wait_for_selector(".toast.show", timeout=8000)
            return " | ".join(page.locator(".toast").all_inner_texts())

        def row(page, name):
            return page.locator(".inv-item", has=page.locator(".inv-item-name", has_text=re.compile(f"^{re.escape(name)}$"))).first

        def wait_idle(page):
            page.wait_for_timeout(300)
            page.wait_for_function("!document.querySelector('#inventory-app [aria-busy=true]')", timeout=15000)
            page.wait_for_timeout(500)

        page = new_page("ui-alice@example.test")

        # 1. character without inventory
        open_char(page, "Empty Hero")
        check("1 empty character shows the empty state", page.get_by_text("This character has no items yet.").is_visible()
              and page.get_by_text("Nothing equipped yet.").is_visible())

        # 2. legacy rows
        open_char(page, "Legacy Hero")
        check("2a legacy rows are shown (nothing disappears)", page.locator(".inv-item.legacy").count() == 3)
        check("2b legacy equipped row shows 'Check where it is equipped'", row(page, "Leather Armor").get_by_text("Check where it is equipped").is_visible())
        check("2c summary shows coins", "12 gp" in " ".join(page.locator(".inv-summary").inner_text().split()))
        row(page, "Quarterstaff").locator(".inv-item-main").click()
        page.wait_for_selector(".inv-link .inv-pick-item, .inv-link p.muted:not(:has-text('Looking'))", timeout=10000)
        # suggestions are never linked directly: Compare… opens the comparison, Link confirms it
        page.locator(".inv-link [data-compare]").first.click()
        page.wait_for_selector(".modal [data-ok]", timeout=10000)
        page.locator(".modal [data-ok]").click()
        expect(page.locator(".toast", has_text="Linked to Quarterstaff")).to_be_visible(timeout=10000)
        t = "Linked to Quarterstaff"
        wait_idle(page)
        check("2d legacy row linked to the catalog after confirmation", "Linked to Quarterstaff" in t
              and not row(page, "Quarterstaff").locator(".inv-b-legacy").count(), t)
        page.screenshot(path=str(SHOTS / "legacy.png"), full_page=True)

        # 3. catalog paging
        open_char(page, "Test Hero")
        page.get_by_role("button", name="+ Add item").click()
        status = page.locator("[data-status]")
        expect(status).to_have_text(re.compile(r"Showing 50 of 1146 items"), timeout=15000)
        check("3a catalog shows page 1 of more than 1000 items", True)
        page.locator("[data-more]").click()
        expect(status).to_have_text(re.compile(r"Showing 100 of 1146"), timeout=15000)
        ids_dom = page.locator(".inv-result").evaluate_all("els => els.map(e => e.dataset.id)")
        check("3b Load more appends without duplicates", len(ids_dom) == 100 == len(set(ids_dom)), len(ids_dom))
        page.fill("input[name=search]", "lo")
        page.fill("input[name=search]", "potion of healing")
        expect(status).to_have_text(re.compile(r"Showing 4 of 4 items"), timeout=15000)
        names = page.locator(".inv-result b").all_inner_texts()
        check("3c search resets paging and ignores the older response", all("Potion of Healing" in n for n in names) and len(names) == 4, names)
        page.fill("input[name=search]", "")
        page.select_option("select[name=kindId]", "weapon")
        expect(status).to_have_text(re.compile(r"of 193 items"), timeout=15000)
        check("3d kind filter resets paging (193 weapons)", page.locator(".inv-result").count() == 50)
        page.fill("input[name=search]", "zzzz-nothing")
        expect(page.get_by_text("No items match the selected filters.")).to_be_visible(timeout=15000)
        check("3e no-results state", True)

        def add(name, qty=1):
            page.select_option("select[name=kindId]", "")
            page.fill("input[name=search]", name)
            # wait until the debounced search has replaced the previous result list
            page.wait_for_function("""(n) => { const r = [...document.querySelectorAll('.inv-result b')];
                return r.length > 0 && r.every(b => b.textContent.toLowerCase().includes(n.toLowerCase()))
                  && !/Searching|Loading/.test(document.querySelector('[data-status]').textContent); }""", arg=name, timeout=15000)
            item = page.locator(".inv-result", has=page.locator("b", has_text=re.compile(f"^{re.escape(name)}$"))).first
            item.wait_for(timeout=15000)
            item.locator("[data-qty]").fill(str(qty))
            item.locator("[data-pick]").click()
            expect(page.locator(".toast", has_text=f"Added {qty} × {name}")).to_be_visible(timeout=10000)

        for n, q in (("Javelin", 5), ("Longsword", 1), ("Shield", 1), ("Greatsword", 1), ("Potion of Healing", 2), ("Longbow", 1),
                     ("Sack", 1), ("Sledgehammer", 4), ("Spell Scroll", 1)):
            add(n, q)
        page.locator(".modal [data-close]").first.click()
        wait_idle(page)
        check("4 items added through the RPC (several pieces)", row(page, "Javelin").locator(".inv-qty-n").inner_text() == "5"
              and page.locator(".inv-item-name", has_text="Sledgehammer").count() == 4)

        # 5. quantity
        row(page, "Javelin").locator("[data-inv=inc]").click(); wait_idle(page)
        row(page, "Javelin").locator("[data-inv=dec]").click(); wait_idle(page)
        check("5a + / − change a stack through the RPCs", row(page, "Javelin").locator(".inv-qty-n").inner_text() == "5")
        check("5b non-stackable items show ×1 without −/+", row(page, "Longsword").locator("[data-inv=dec]").count() == 0)

        # 6. equip from a stack, unequip
        row(page, "Javelin").locator("[data-inv=equip]").click()
        page.locator(".inv-pick-item[data-slot=main_hand]").click()
        expect(page.locator(".toast", has_text="Equipped Javelin (Main Hand) — one piece was taken from the stack")).to_be_visible(timeout=10000)
        wait_idle(page)
        jav = page.locator(".inv-item", has=page.locator(".inv-item-name", has_text="Javelin"))
        qtys = sorted(jav.locator(".inv-qty-n").all_inner_texts())
        check("6a equipping one javelin splits the stack (4 + 1 equipped)", qtys == ["4", "×1"], qtys)
        check("6b main hand slot shows the equipped javelin", "Javelin" in page.locator(".inv-slot", has_text="Main Hand").inner_text())
        page.locator(".inv-slot", has_text="Main Hand").locator("[data-inv=slot-unequip]").click(); wait_idle(page)
        check("6c unequip rejoins the stack", row(page, "Javelin").locator(".inv-qty-n").inner_text() == "5")

        # 7. shield + two-handed
        row(page, "Shield").locator("[data-inv=equip]").click(); wait_idle(page)
        row(page, "Greatsword").locator("[data-inv=equip]").click()
        page.locator(".inv-pick-item[data-slot=main_hand]").click()
        msg = page.locator(".toast", has_text="two-handed weapon needs both hands")
        expect(msg).to_be_visible(timeout=10000)
        wait_idle(page)
        check("7a shield + two-handed weapon is rejected with a clear message", True)
        check("7b the shield went to the shield slot (not the armor slot)", "Shield" in page.locator(".inv-slot", has_text="Shield").last.inner_text()
              and "Empty" in page.locator(".inv-slot", has=page.locator(".inv-slot-name", has_text=re.compile("^Armor$"))).text_content())   # empty slots are folded

        # 8. potion
        row(page, "Potion of Healing").locator("[data-inv=use]").click()
        page.wait_for_selector(".modal .inv-effects", timeout=10000)
        txt = page.locator(".modal").last.inner_text()
        check("8a healing potion shows its effect, HP unchanged note", "Healing: 2d4 + 2" in txt and "not changed automatically" in txt, txt)
        page.locator(".modal .btn-gold[data-close]").click(); wait_idle(page)
        check("8b quantity went from 2 to 1", row(page, "Potion of Healing").locator(".inv-qty-n").inner_text() == "1")
        row(page, "Potion of Healing").locator("[data-inv=use]").click()
        page.wait_for_selector(".modal :text('That was the last one')", timeout=10000)
        page.locator(".modal .btn-gold[data-close]").click(); wait_idle(page)
        check("8c last potion removed", page.locator(".inv-item", has_text="Potion of Healing").count() == 0)

        # 9. scroll
        row(page, "Spell Scroll").locator("[data-inv=use]").click()
        page.wait_for_selector(".modal :text('That was the last one')", timeout=10000)
        page.locator(".modal .btn-gold[data-close]").click(); wait_idle(page)
        check("9 scroll is consumed", page.locator(".inv-item", has_text="Spell Scroll").count() == 0)

        # 10. ammunition
        check("10a missing ammunition is reported", "No compatible ammunition" in row(page, "Longbow").inner_text())
        add_open = page.get_by_role("button", name="+ Add item"); add_open.click()
        add("Arrows", 3); page.locator(".modal [data-close]").first.click(); wait_idle(page)
        check("10b compatible ammunition is shown with a low-ammo warning", "Ammunition: Arrow ×3 — running low" in row(page, "Longbow").inner_text(),
              row(page, "Longbow").inner_text())

        # 11. container warning
        for _ in range(4):   # 4 x 10 lb into a sack that holds 30 lb
            top = page.evaluate("""() => [...document.querySelectorAll('.inv-list > .inv-item')]
                .find(e => e.querySelector(':scope > .inv-item-row .inv-item-name').textContent === 'Sledgehammer')?.dataset.row""")
            page.locator(f'.inv-item-main[data-id="{top}"]').click()
            page.select_option(".modal select[name=container]", label="Sack")
            page.locator(".modal [data-form=move] button[type=submit]").click()
            wait_idle(page)
        check("11 over-capacity container is reported (not blocked)", "over capacity" in row(page, "Sack").inner_text().lower(), row(page, "Sack").inner_text())

        # 12. remove the last piece
        row(page, "Longsword").locator(".inv-item-main").click()
        page.locator(".modal [data-x=remove]").click()
        page.locator(".modal [data-ok]").last.click(); wait_idle(page)
        check("12 removing the last piece deletes the row", page.locator(".inv-item", has_text="Longsword").count() == 0)

        # 13. attunement limit
        page.get_by_role("button", name="+ Add item").click()
        for n in ("Amulet of Health", "Belt of Dwarvenkind", "Cloak of Protection", "Bracers of Defense"):
            add(n)
        page.locator(".modal [data-close]").first.click(); wait_idle(page)
        for n in ("Amulet of Health", "Belt of Dwarvenkind", "Cloak of Protection"):
            row(page, n).locator(".inv-item-main").click(); page.locator(".modal [data-x=attune]").click(); wait_idle(page)
        check("13a attune three items (3 / 3)", "3/3" in "".join(page.locator(".inv-summary .inv-m-attuned .inv-metric-num").inner_text().split()))
        row(page, "Bracers of Defense").locator(".inv-item-main").click()
        page.locator(".modal [data-x=attune]").click()
        expect(page.locator(".toast", has_text="already attuned to 3 items")).to_be_visible(timeout=10000)
        t = "already attuned to 3 items"
        check("13b attunement limit is explained and the attuned items are listed", "already attuned to 3 items" in t
              and page.get_by_text("Attuned items (3 / 3)").is_visible(), t)
        page.locator(".modal [data-close]").last.click()

        # 14. refresh keeps the server state
        before = page.locator(".inv-item-name").all_inner_texts()
        page.reload(); page.wait_for_selector(".inv"); wait_idle(page)
        check("14 reload shows the same server state", sorted(page.locator(".inv-item-name").all_inner_texts()) == sorted(before))
        page.screenshot(path=str(SHOTS / "desktop.png"), full_page=True)

        # 15. DM and another player
        dm = new_page("ui-dm@example.test")
        open_char(dm, "Test Hero")
        check("15a the campaign DM sees the player's inventory", dm.locator(".inv-item").count() >= 5)
        bob = new_page("ui-bob@example.test")
        bob.goto(f"{APP}#/c/{ids['Test Hero']}")
        bob.wait_for_timeout(4000)
        check("15b another player cannot open the inventory", bob.locator(".inv-item").count() == 0)
        st, body = call("POST", "/rest/v1/rpc/add_inventory_item", {"p_inventory": "00000000-0000-0000-0000-000000000000", "p_item": "dagger"},
                        token=ANON, key=ANON)
        check("15c the API refuses inventory writes without a user", st in (401, 403), st)

        # 16r. realtime: a change made elsewhere (the DM through the API) appears without a reload
        _, invs = call("GET", f"/rest/v1/inventories?character_id=eq.{ids['Test Hero']}&select=id")
        dm_token = call("POST", "/auth/v1/token?grant_type=password", {"email": "ui-dm@example.test", "password": PW}, token=ANON, key=ANON)[1]["access_token"]
        open_char(page, "Test Hero")
        st, _ = call("POST", "/rest/v1/rpc/add_inventory_item", {"p_inventory": invs[0]["id"], "p_item": "hooded-lantern", "p_quantity": 1},
                     token=dm_token, key=ANON)
        try:
            page.wait_for_selector(".inv-item-name:text-is('Lantern - Hooded')", timeout=15000)
            ok = True
        except Exception:  # noqa: BLE001
            ok = False
        check("16r realtime: an item added by the DM appears on the player's open page without a reload", st == 200 and ok, st)

        # 16. mobile
        m = new_page("ui-alice@example.test", {"width": 390, "height": 844})
        open_char(m, "Test Hero")
        overflow = m.evaluate("document.scrollingElement.scrollWidth - window.innerWidth")
        check("16a mobile: no horizontal overflow", overflow <= 0, overflow)
        check("16b mobile: equipment is collapsible and closed by default", m.locator("details.inv-eq").get_attribute("open") is None)
        check("16c mobile: quick actions visible without hover", row(m, "Javelin").locator("[data-inv=equip]").is_visible())
        row(m, "Javelin").locator(".inv-item-main").click()
        check("16d mobile: detail opens as a sheet", m.locator(".modal").is_visible())
        m.screenshot(path=str(SHOTS / "mobile.png"), full_page=True)

        browser.close()

    # Expected: 4xx responses of rejected actions, and the existing "character not found" error the app logs when
    # another player opens a character they may not see (PGRST116 on the bob page).
    relevant = [e for e in errors if "favicon" not in e and "fonts.g" not in e and "status of 4" not in e
                and not (e.startswith("ui-bob@") and "PGRST116" in e)]
    check("17 browser console has no errors (expected 4xx responses of rejected actions excluded)", not relevant, relevant[:5])
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
