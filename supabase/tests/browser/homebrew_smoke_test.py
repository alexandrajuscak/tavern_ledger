"""Focused browser smoke test of the homebrew / legacy inventory UI against a LOCAL Supabase stack.

Run like inventory_ui_test.py (API_URL / ANON_KEY / SERVICE_ROLE_KEY from `supabase status`, app served locally).
Refuses non-local URLs. Synthetic users only. Prints PASSED / FAILED per check.
"""
import json
import os
import re
import sys
import uuid
import urllib.error
import urllib.request
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright, expect

sys.stdout.reconfigure(encoding="utf-8")
API = os.environ["API_URL"].rstrip("/")
ANON = os.environ["ANON_KEY"]
SERVICE = os.environ["SERVICE_ROLE_KEY"]
APP = os.environ.get("APP_URL", "http://127.0.0.1:5173/")
for u in (API, APP):
    if urlparse(u).hostname not in ("127.0.0.1", "localhost"):
        sys.exit(f"refusing to run: {u} is not local")
PW = "local-test-password-1!"
RUN = uuid.uuid4().hex[:6]
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(("PASSED  " if ok else "FAILED  ") + name + ("" if ok else f"   <-- {detail}"), flush=True)


def call(method, path, body=None, headers=None, token=SERVICE, key=SERVICE):
    h = {"apikey": key, "Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    h.update(headers or {})
    req = urllib.request.Request(API + path.replace(" ", "%20"), data=json.dumps(body).encode() if body is not None else None,
                                 method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def fixtures():
    email = f"hb-smoke-{RUN}@example.test"
    call("POST", "/auth/v1/admin/users", {"email": email, "password": PW, "email_confirm": True})
    st, body = call("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": PW}, token=ANON, key=ANON)
    uid, token = body["user"]["id"], body["access_token"]
    rep = {"Prefer": "return=representation"}
    # since 20261019000100 only DMs author mechanical items: the editor's user DMs a campaign of their own
    _, own = call("POST", "/rest/v1/campaigns", {"name": "UI Test Campaign", "created_by": uid}, rep)
    call("POST", "/rest/v1/campaign_members", {"campaign_id": own[0]["id"], "user_id": uid, "role": "dm"})
    _, chars = call("POST", "/rest/v1/characters", [{"owner_id": uid, "name": f"Smoke Hero {RUN}"}], rep)
    cid = chars[0]["id"]
    # an existing legacy row (old data), created by the service role as a fixture
    call("POST", "/rest/v1/inventory_items", {"character_id": cid, "name": "Quarterstaffs", "quantity": 1, "weight": 4,
                                             "description": "worn smooth"})
    return email, uid, token, cid


def main():
    email, uid, token, cid = fixtures()
    hb_name = f"Moon Blade {RUN}"
    errors, requests_remote = [], []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        ctx = browser.new_context(viewport={"width": 1366, "height": 900})
        ctx.add_init_script(f"localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({{url: {json.dumps(API)}, key: {json.dumps(ANON)}}}));"
                            "localStorage.setItem('tavern-ledger:tab', 'inventory');")
        page = ctx.new_page()
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(f"pageerror: {e}"))
        page.on("request", lambda r: requests_remote.append(r.url) if urlparse(r.url).hostname not in ("127.0.0.1", "localhost")
                else None)  # fonts and supabase-js are self-hosted since v6.1: any other host is unexpected

        page.goto(APP)
        page.fill("input[name=email]", email)
        page.fill("input[name=password]", PW)
        page.click("button[value=signin]")
        page.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)
        check("1 JavaScript modules load (no page error)", not [e for e in errors if e.startswith("pageerror")], errors[:3])

        page.goto(f"{APP}#/c/{cid}")
        try:
            page.wait_for_selector(".inv", timeout=20000)
            page.wait_for_function("!document.querySelector('#inventory-app .spinner')", timeout=20000)
            ok = True
        except Exception as e:  # noqa: BLE001
            ok = False
        check("2 inventory screen loads", ok, errors[:3])

        page.get_by_role("button", name="+ Add item").click()
        expect(page.locator("[data-status]")).to_have_text(re.compile(r"Showing 50 of"), timeout=15000)
        check("3 Add Item modal opens (catalog paging)", True)

        page.locator("[data-create]").click()
        page.wait_for_selector(".hb-form", timeout=10000)
        check("4 Create Homebrew modal opens", page.locator(".hb-form").is_visible())
        page.locator(".modal [data-submit]").click()
        err = page.locator("#hb-name-err")
        check("4b empty name shows a field error linked by aria-describedby",
              err.is_visible() and page.locator("#hb-name").get_attribute("aria-describedby") == "hb-name-err"
              and page.locator("#hb-name").get_attribute("aria-invalid") == "true", err.inner_text() if err.count() else "")
        page.fill("#hb-name", hb_name)
        page.locator(".modal input[name=visibility][value=private]").check()
        page.locator(".modal [data-submit]").click()
        try:
            expect(page.locator(".toast", has_text=f"Created {hb_name}")).to_be_visible(timeout=15000)
            ok = True
        except Exception:  # noqa: BLE001
            ok = False
        check("5 private homebrew is created and added to the inventory", ok, errors[-3:])
        page.wait_for_timeout(1200)
        st, rows = call("GET", f"/rest/v1/items?name=eq.{hb_name}&select=id,name,owner_id,campaign_id,data_source_id")
        check("5b exactly one item, owned by the user, private, labelled homebrew",
              st == 200 and len(rows) == 1 and rows[0]["owner_id"] == uid and rows[0]["campaign_id"] is None
              and rows[0]["data_source_id"] == "homebrew", rows)
        hb_id = rows[0]["id"] if rows else None
        item_row = page.locator(".inv-item", has=page.locator(".inv-item-name", has_text=hb_name)).first
        check("6 homebrew row shows the Homebrew badge (text, not colour only)", "Homebrew" in item_row.inner_text(), item_row.inner_text())

        page.get_by_role("button", name="+ Add item").click()
        page.select_option("select[name=visibility]", "private")
        expect(page.locator("[data-status]")).to_have_text(re.compile(r"Showing 1 of 1 item"), timeout=15000)
        check("7 My homebrew filter shows the new item", hb_name in page.locator(".inv-results").inner_text())
        page.keyboard.press("Escape")
        page.wait_for_timeout(400)
        check("12 Escape closes the active modal", page.locator(".modal-backdrop").count() == 0)

        item_row.locator(".inv-item-main").click()
        page.wait_for_selector(".modal [data-form=text]")
        page.fill(".modal input[name=custom_name]", "Grandpa's blade")
        page.locator(".modal [data-form=text] button[type=submit]").click()
        expect(page.locator(".toast", has_text="Saved.")).to_be_visible(timeout=10000)
        page.wait_for_timeout(1000)
        st, rows = call("GET", f"/rest/v1/items?id=eq.{hb_id}&select=name")
        check("8 custom inventory name does not change the catalog definition",
              rows == [{"name": hb_name}] and page.locator(".inv-item-name", has_text="Grandpa's blade").count() == 1, rows)

        leg = page.locator(".inv-item.legacy").first
        leg.locator(".inv-item-main").click()
        try:
            page.wait_for_selector(".modal .inv-link [data-link-search]", timeout=10000)
            body = page.locator(".modal").last.inner_text()
            ok = "Legacy item" in body and page.locator(".modal [data-x=convert]").count() == 1
        except Exception:  # noqa: BLE001
            ok, body = False, ""
        check("10 legacy item detail renders with link and convert options", ok, body[:300])
        check("10b legacy detail offers no quantity / free-text editing", page.locator(".modal [data-form=qty], .modal [data-form=text]").count() == 0)
        cmp = page.locator(".modal [data-compare]")
        if cmp.count():
            cmp.first.click()
            page.wait_for_selector(".modal .inv-compare, .modal :text('match')", timeout=10000)
            check("11 link comparison modal renders (nothing linked yet)", "Nothing changes until you confirm" in page.locator(".modal").last.inner_text())
            page.keyboard.press("Escape")
        else:
            check("11 link comparison modal renders", False, "no candidates for 'Quarterstaffs'")
        page.wait_for_timeout(400)
        st, rows = call("GET", f"/rest/v1/inventory_items?character_id=eq.{cid}&item_id=is.null&select=id")
        check("11b legacy row is still unlinked; no new legacy rows were created", st == 200 and len(rows) == 1, rows)
        st, _ = call("POST", "/rest/v1/inventory_items", {"character_id": cid, "name": "New free text"}, token=token, key=ANON)
        check("11c the API refuses a new client-created legacy row", st in (401, 403), st)

        # focus returns to the opener (or its re-rendered replacement), never to <body>
        focus_key = "document.activeElement?.dataset?.focusKey || document.activeElement?.tagName"
        row_id = page.locator(".inv-item", has=page.locator(".inv-item-name", has_text="Grandpa's blade")).first.get_attribute("data-row")
        details_key = f"inventory-item:{row_id}:details"
        page.locator(f'[data-focus-key="{details_key}"]').click()
        page.wait_for_selector(".modal")
        page.keyboard.press("Escape")
        page.wait_for_timeout(1500)   # let any queued refresh / Realtime re-render happen
        check("F1 Escape on item detail returns focus to the same item", page.evaluate(focus_key) == details_key, page.evaluate(focus_key))
        # a save closes the modal and re-renders the whole list afterwards: focus must move to the replacement element
        page.locator(f'[data-focus-key="{details_key}"]').click()
        page.wait_for_selector(".modal [data-form=text]")
        page.fill(".modal textarea[name=notes]", "focus test")
        page.locator(".modal [data-form=text] button[type=submit]").click()
        expect(page.locator(".toast", has_text="Saved.")).to_be_visible(timeout=10000)
        page.wait_for_timeout(1500)
        check("F2 after a save + list re-render, focus is on the replacement item button",
              page.evaluate(focus_key) == details_key and page.evaluate("document.activeElement.isConnected"), page.evaluate(focus_key))
        # nested: confirmation dialog over the item detail
        page.locator(f'[data-focus-key="{details_key}"]').click()
        page.wait_for_selector(".modal [data-x=remove]")
        page.locator(".modal [data-x=remove]").focus()
        page.keyboard.press("Enter")
        page.wait_for_selector(".modal [data-ok]")
        page.keyboard.press("Escape")
        page.wait_for_timeout(400)
        in_parent = page.evaluate("document.activeElement?.dataset?.x === 'remove' && !!document.activeElement.closest('.modal-backdrop:not([data-closing])')")
        check("F3 closing a child dialog returns focus inside the parent modal", in_parent, page.evaluate("document.activeElement?.outerHTML?.slice(0, 120)"))
        page.keyboard.press("Escape")
        page.wait_for_timeout(600)
        check("F4 closing the last modal returns focus to the page item", page.evaluate(focus_key) == details_key, page.evaluate(focus_key))
        # Add item -> Create homebrew (the picker is replaced by the form, not stacked) -> Escape -> Add item button
        page.locator('[data-focus-key="add-item-button"]').click()
        page.locator("[data-create]").click()
        page.wait_for_selector(".hb-form")
        page.keyboard.press("Escape")
        page.wait_for_timeout(600)
        check("F5 closing Create homebrew (opened from Add item) returns focus to Add item",
              page.evaluate(focus_key) == "add-item-button", page.evaluate(focus_key))
        check("F6 focus never ends on <body> in these flows", page.evaluate("document.activeElement !== document.body"))

        # optional: archive
        item_row = page.locator(".inv-item", has=page.locator(".inv-item-name", has_text="Grandpa's blade")).first
        item_row.locator(".inv-item-main").click()
        page.locator(".modal [data-x=archive-def]").click()
        page.wait_for_selector(".modal [data-ok]", timeout=10000)   # the confirmation appears after the usage count loads
        dlg = page.locator(".modal", has=page.locator("[data-ok]")).last.inner_text()
        page.locator(".modal [data-ok]").last.click()
        expect(page.locator(".toast", has_text="Archived")).to_be_visible(timeout=10000)
        page.wait_for_timeout(1000)
        check("14 archive succeeds (confirmation mentions the usage)", "used by 1 inventory entry" in dlg, dlg)
        check("16 the existing inventory entry stays, marked Archived definition",
              "Archived definition" in page.locator(".inv-item", has=page.locator(".inv-item-name", has_text="Grandpa's blade")).first.inner_text())
        page.get_by_role("button", name="+ Add item").click()
        page.select_option("select[name=visibility]", "private")
        expect(page.get_by_text("No items match the selected filters.")).to_be_visible(timeout=15000)
        check("15 archived homebrew disappears from Add Item", True)
        page.keyboard.press("Escape")

        # optional: mobile
        m = ctx.new_page()
        m.set_viewport_size({"width": 390, "height": 844})
        m.goto(f"{APP}#/c/{cid}")
        m.wait_for_selector(".inv", timeout=20000)
        m.get_by_role("button", name="+ Add item").click()
        m.locator("[data-create]").click()
        m.wait_for_selector(".hb-form")
        overflow = m.evaluate("document.scrollingElement.scrollWidth - window.innerWidth")
        modal_overflow = m.evaluate("(() => { const b = document.querySelector('.modal-body'); return b.scrollWidth - b.clientWidth; })()")
        check("17 mobile (emulated 390px): homebrew form has no horizontal overflow", overflow <= 0 and modal_overflow <= 0, (overflow, modal_overflow))
        browser.close()

    relevant = [e for e in errors if "status of 4" not in e and "favicon" not in e]
    check("13 no uncaught browser console errors", not relevant, relevant[:5])
    check("18 no request went to a remote Supabase project", not requests_remote, requests_remote[:5])
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
