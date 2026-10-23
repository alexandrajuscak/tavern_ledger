"""Browser test of derived character stats (AC, armor warnings, weapon proficiency) against the LOCAL Supabase stack.

Run like inventory_ui_test.py (API_URL / ANON_KEY / SERVICE_ROLE_KEY from `supabase status`, app served locally,
installed Microsoft Edge through playwright). The service role only creates synthetic fixtures (users, characters,
items); every action under test goes through the UI. Refuses non-local URLs.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright, expect

sys.stdout.reconfigure(encoding="utf-8")
API = os.environ["API_URL"].rstrip("/")
ANON = os.environ["ANON_KEY"]
SERVICE = os.environ["SERVICE_ROLE_KEY"]
APP = os.environ.get("APP_URL", "http://127.0.0.1:5173/")
SHOTS = Path(os.environ.get("SCREENSHOT_DIR", "."))
for u in (API, APP):
    if urlparse(u).hostname not in ("127.0.0.1", "localhost"):
        sys.exit(f"refusing to run: {u} is not local")
PW = "local-test-password-1!"
RUN = str(int(time.time()))
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


def fixtures():
    email = f"ui-derived-{RUN}@example.test"
    call("POST", "/auth/v1/admin/users", {"email": email, "password": PW, "email_confirm": True})
    _, body = call("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": PW}, token=ANON, key=ANON)
    uid, jwt = body["user"]["id"], body["access_token"]
    _, chars = call("POST", "/rest/v1/characters", [
        {"owner_id": uid, "name": "Derived A", "level": 5, "strength": 16, "dexterity": 18, "speed": 30},
        {"owner_id": uid, "name": "Derived B", "level": 1, "strength": 12, "dexterity": 14, "speed": 30}], {"Prefer": "return=representation"})
    ids = {c["name"]: c["id"] for c in chars}
    rpc = lambda fn, **a: call("POST", f"/rest/v1/rpc/{fn}", a, token=jwt, key=ANON)   # noqa: E731
    for g in ("light-armor", "medium-armor", "heavy-armor", "shields", "simple-weapons", "martial-weapons"):
        rpc("set_character_proficiency", p_character=ids["Derived A"], p_group=g)
    for name, items in (("Derived A", ["leather", "half-plate", "plate", "shield", "longsword", "ring-of-protection"]),
                        ("Derived B", ["chain-mail", "shield", "longsword", "thieves-tools"])):
        _, inv = call("GET", f"/rest/v1/inventories?character_id=eq.{ids[name]}&select=id")
        for it in items:
            rpc("add_inventory_item", p_inventory=inv[0]["id"], p_item=it, p_quantity=1)
    return email, ids


def main():
    email, ids = fixtures()
    SHOTS.mkdir(parents=True, exist_ok=True)
    errors, remote = [], []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        ctx = browser.new_context(viewport={"width": 1366, "height": 900})
        ctx.add_init_script(f"localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({{url: {json.dumps(API)}, key: {json.dumps(ANON)}}}));"
                            "localStorage.setItem('tavern-ledger:tab', 'inventory');")
        ctx.on("request", lambda r: remote.append(r.url) if urlparse(r.url).hostname not in ("127.0.0.1", "localhost")
               else None)  # fonts and supabase-js are self-hosted since v6.1: any other host is unexpected
        page = ctx.new_page()
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(f"pageerror: {e}"))
        page.goto(APP)
        page.fill("input[name=email]", email)
        page.fill("input[name=password]", PW)
        page.click("button[value=signin]")
        page.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)

        ac = page.locator('[data-derived="ac"]')

        def open_char(name):
            page.goto(f"{APP}#/c/{ids[name]}")
            page.wait_for_selector(".inv", timeout=20000)
            page.wait_for_function("!document.querySelector('#inventory-app .spinner')", timeout=20000)

        def tab(key):
            page.locator(f'.tab[data-tab="{key}"]').click()

        def row(name):
            return page.locator(".inv-item", has=page.locator(".inv-item-name", has_text=re.compile(f"^{re.escape(name)}$"))).first

        def equip(name, slot=None):
            tab("inventory")
            row(name).locator("[data-inv=equip]").click()
            if slot:
                page.locator(f".inv-pick-item[data-slot={slot}]").click()
            else:
                confirm = page.locator(".modal [data-ok]")
                try:
                    confirm.wait_for(timeout=1500)
                    confirm.click()
                except Exception:  # noqa: BLE001
                    pass
            expect(page.locator(".toast", has_text=f"Equipped {name}").last).to_be_visible(timeout=10000)

        def unequip(name):
            tab("inventory")
            row(name).locator("[data-inv=unequip]").click()
            expect(page.locator(".toast", has_text=f"Unequipped {name}").last).to_be_visible(timeout=10000)

        def expect_ac(v, label):
            try:
                expect(ac).to_have_text(str(v), timeout=10000)
                check(label, True)
            except AssertionError:
                check(label, False, ac.inner_text())

        def breakdown():
            page.locator('[data-action="ac-breakdown"]').click()
            page.wait_for_selector(".modal .ac-table", timeout=10000)
            return page.locator(".modal").last.inner_text()

        def close_modal():
            page.keyboard.press("Escape")
            page.wait_for_timeout(500)

        # ---- character A: proficient, DEX 18 (+4), STR 16, level 5 ---------------------------------------------
        open_char("Derived A")
        expect_ac(14, "1 the sheet shows the derived unarmored AC (10 + DEX 4 = 14)")
        equip("Leather")
        expect_ac(15, "2 equipping Leather: 11 + full DEX 4 = 15")
        equip("Half Plate")
        expect_ac(17, "3a equipping Half Plate: 15 + DEX capped at +2 = 17")
        txt = breakdown()
        check("3b the breakdown explains the Dexterity cap", "maximum of +2" in txt and "Half Plate" in txt, txt[:300])
        close_modal()
        equip("Plate")
        expect_ac(18, "4 equipping Plate: fixed 18, DEX ignored")
        equip("Shield")
        expect_ac(20, "5 equipping a Shield adds +2 (20)")
        unequip("Shield")
        expect_ac(18, "6 unequipping the Shield reverses it (18)")
        equip("Shield")
        expect_ac(20, "6b re-equipping the Shield (20)")
        txt = breakdown()
        check("7 the AC breakdown lists every source (Plate 18, Dexterity not applied, Shield +2, total 20)",
              all(s in txt for s in ("Plate", "Dexterity modifier", "not applied", "Shield", "Calculated AC")) and "20" in txt, txt[:400])
        check("8 the Stealth disadvantage warning appears with the armor warnings", "Stealth checks have disadvantage while wearing Plate" in txt, txt)
        close_modal()
        check("20a closing the breakdown returns focus to the AC button",
              page.evaluate("document.activeElement?.dataset?.focusKey") == "ac-breakdown", page.evaluate("document.activeElement?.outerHTML?.slice(0,80)"))
        tab("stats")
        check("8b the Stealth skill shows a visible 'disadvantage' marker",
              page.locator('[data-dis="skill:stealth"]').is_visible() and not page.locator('[data-dis="skill:perception"]').is_visible())

        equip("Longsword", slot="main_hand")
        tab("combat")
        card = page.locator(".derived-weapon", has_text="Longsword")
        try:
            expect(card.locator("[data-attack-bonus]")).to_have_text("+6", timeout=10000)
            ok = True
        except AssertionError:
            ok = False
        check("15 a proficient weapon includes the proficiency bonus (STR +3, PB +3 -> +6)", ok, card.inner_text() if card.count() else "no card")
        tab("stats")
        page.locator('[data-action="toggle-equip"][data-k="martial"]').click()
        tab("combat")
        try:
            expect(card.locator("[data-attack-bonus]")).to_have_text("+3", timeout=10000)
            ok = "Not proficient with Martial Weapons" in card.inner_text()
        except AssertionError:
            ok = False
        check("16 removing the weapon proficiency updates the attack bonus (+3) and explains why", ok, card.inner_text())
        card.locator("summary").click()
        check("16b 'How this is calculated' shows the modifier, proficiency (+0) and total",
              all(s in card.inner_text() for s in ("Strength modifier", "Proficiency bonus", "+0", "not proficient", "Attack bonus")), card.inner_text())

        equip("Ring of Protection", slot="ring_1")
        expect_ac(20, "18a an equipped but unattuned Ring of Protection does not change AC (20)")
        tab("inventory")
        row("Ring of Protection").locator(".inv-item-main").click()
        page.locator(".modal [data-x=attune]").click()
        expect_ac(21, "18 attuning the Ring of Protection applies +1 (21)")
        page.wait_for_timeout(500)
        if page.locator(".modal-backdrop").count():
            close_modal()
        tab("inventory")
        row("Ring of Protection").locator(".inv-item-main").click()
        page.locator(".modal [data-x=unattune]").click()
        expect_ac(20, "19 ending attunement removes the effect (20)")
        page.wait_for_timeout(500)
        if page.locator(".modal-backdrop").count():
            close_modal()

        # ---- character B: no proficiencies, STR 12, DEX 14 ---------------------------------------------------------
        open_char("Derived B")
        expect_ac(12, "1b character B unarmored: 12")
        equip("Chain Mail")
        expect_ac(16, "10 non-proficient heavy armor can still be equipped and sets AC (16)")
        check("10b the equipped slot says 'Not proficient' in text", "Not proficient" in page.locator(".inv-slot", has_text="Chain Mail").inner_text())
        txt = breakdown()
        check("11 the missing armor proficiency warning appears (text, penalties listed)",
              "Not proficient with Heavy Armor" in txt and "disadvantage on Strength and Dexterity checks" in txt and "can’t cast spells" in txt, txt)
        check("9 the Strength requirement warning appears (needs 13, has 12, speed reduced)",
              "requires Strength 13" in txt and "Your Strength is 12" in txt, txt)
        close_modal()
        check("9b the speed tile shows the reduced speed", "now 20 ft" in page.locator('[data-derived="speed-note"]').inner_text())
        equip("Shield")
        expect_ac(18, "12a non-proficient shield still adds +2 (18)")
        txt = breakdown()
        check("12 the missing shield proficiency warning appears", "Not proficient with Shields" in txt, txt)
        close_modal()
        tab("stats")
        page.locator('[data-action="toggle-equip"][data-k="heavy"]').click()
        try:
            expect(page.locator('[data-action="toggle-equip"][data-k="heavy"]')).to_have_attribute("aria-pressed", "true", timeout=5000)
            ok = True
        except AssertionError:
            ok = False
        check("13 the proficiency chips add an armor proficiency", ok)
        page.wait_for_timeout(1500)
        txt = breakdown()
        check("14 adding the proficiency removes the armor warning (shield warning stays)",
              "Not proficient with Heavy Armor" not in txt and "Not proficient with Shields" in txt, txt)
        close_modal()
        tab("stats")
        tools_text = page.locator("#tool-profs").inner_text().replace("’", "'")
        tab("inventory")
        tool_row = page.locator(".inv-item", has=page.locator(".inv-item-name", has_text=re.compile("Thieves")))
        check("17 a tool without proficiency is listed as 'not proficient', stays in the inventory with no warning",
              "thieves' tools (not proficient)" in tools_text.lower() and tool_row.count() == 1 and "Not proficient" not in tool_row.inner_text(),
              tools_text)
        tab("stats")
        page.locator('[data-action="manage-profs"]').click()
        page.fill(".modal input[name=q]", "longsword")
        page.locator(".modal [data-add-prof=longsword]").click()
        expect(page.locator(".modal [data-list]")).to_contain_text("Longsword", timeout=10000)
        check("21b the specific-proficiency dialog adds a Longsword proficiency", True)
        close_modal()
        check("20b closing the proficiency dialog returns focus to its button",
              page.evaluate("document.activeElement?.dataset?.focusKey") == "manage-profs")
        equip("Longsword", slot="main_hand")
        tab("combat")
        try:
            expect(page.locator(".derived-weapon", has_text="Longsword").locator("[data-attack-bonus]")).to_have_text("+3", timeout=10000)
            ok = True
        except AssertionError:
            ok = False
        check("15b a specific weapon proficiency adds PB (STR +1, PB +2 -> +3)", ok)
        page.screenshot(path=str(SHOTS / "derived-desktop.png"), full_page=True)

        # ---- mobile ----------------------------------------------------------------------------------------------
        m = ctx.new_page()
        m.on("pageerror", lambda e: errors.append(f"pageerror: {e}"))
        m.set_viewport_size({"width": 390, "height": 844})
        m.goto(f"{APP}#/c/{ids['Derived B']}")
        m.wait_for_selector(".combat-bar", timeout=20000)
        if "compact" in (m.locator(".combat-bar").get_attribute("class") or ""):   # phones start with the vitals collapsed (2026-10-22 v5)
            m.locator(".compact-toggle").click()
        m.wait_for_selector('[data-derived="ac"]', timeout=20000)
        expect(m.locator('[data-derived="ac"]')).to_have_text("18", timeout=15000)
        m.locator('[data-action="ac-breakdown"]').click()
        m.wait_for_selector(".modal .ac-table")
        overflow = m.evaluate("document.scrollingElement.scrollWidth - window.innerWidth")
        modal_overflow = m.evaluate("(() => { const b = document.querySelector('.modal-body'); return b.scrollWidth - b.clientWidth; })()")
        m.screenshot(path=str(SHOTS / "derived-mobile.png"), full_page=False)
        check("23 mobile (390px): the AC breakdown has no horizontal overflow", overflow <= 0 and modal_overflow <= 0, (overflow, modal_overflow))
        browser.close()

    relevant = [e for e in errors if "status of 4" not in e and "favicon" not in e]
    check("21 no uncaught browser errors or console errors", not relevant, relevant[:5])
    check("22 no request went to a hosted Supabase URL", not remote, remote[:5])
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
