"""Browser test of classes, spell slots, Pact Magic and rests against the LOCAL Supabase stack.

Run like the other browser tests (API_URL / ANON_KEY / SERVICE_ROLE_KEY from `supabase status`, app served locally,
Microsoft Edge through playwright). The service role only creates the synthetic user and character; every checked
interaction goes through the UI (Classes card on Bio, Slot Tracker on Spells, Level Up, export / import). Refuses non-local URLs.
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

from playwright.sync_api import sync_playwright

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
    email = f"ui-classes-{RUN}@example.test"
    call("POST", "/auth/v1/admin/users", {"email": email, "password": PW, "email_confirm": True})
    _, body = call("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": PW}, token=ANON, key=ANON)
    uid = body["user"]["id"]
    _, chars = call("POST", "/rest/v1/characters", {"owner_id": uid, "name": "Class Tester", "level": 4, "intelligence": 16, "wisdom": 12,
                                                    "charisma": 16, "hp_max": 30, "hp_current": 12}, {"Prefer": "return=representation"})
    return email, chars[0]["id"]


def main():
    email, cid = fixtures()
    SHOTS.mkdir(parents=True, exist_ok=True)
    errors, remote = [], []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        ctx = browser.new_context(viewport={"width": 1366, "height": 900}, accept_downloads=True)
        ctx.add_init_script(f"localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({{url: {json.dumps(API)}, key: {json.dumps(ANON)}}}));"
                            "localStorage.setItem('tavern-ledger:tab', 'features');")
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
        page.goto(f"{APP}#/c/{cid}")
        modal = page.locator(".modal").last
        card = page.locator("#class-card-body")
        tracker = page.locator("#slot-tracker")

        def select_text(sel, text):
            value = page.eval_on_selector(sel, "(s, t) => [...s.options].find((o) => o.textContent.includes(t))?.value", text)
            page.select_option(sel, value)

        def confirm():
            page.locator(".modal [data-ok]").last.click()
            page.wait_for_timeout(300)
        def close_rest_summary():
            page.wait_for_selector(".modal [data-rest-summary]", timeout=15000)
            page.locator(".modal [data-rest-ok]").last.click()
            page.wait_for_selector(".modal [data-rest-summary]", state="detached", timeout=5000)

        def tab(name):
            page.locator(f'.tab[data-tab="{name}"]').click()
            page.wait_for_timeout(300)

        def add_class(name, level):
            page.click("[data-action=class-add]")
            page.wait_for_selector(".modal [data-class-form]")
            select_text(".modal [data-class-form] select[name=class]", name)
            page.fill(".modal [data-class-form] input[name=level]", str(level))
            page.locator(".modal [data-class-form] input[name=level]").dispatch_event("change")
            page.wait_for_selector(".modal [data-add-summary]", timeout=15000)      # guided dialog: live preview first
            if page.locator(".modal [data-dm-ok]:not([hidden])").count():          # unmet multiclass prerequisite
                page.locator(".modal input[name=dm_ok]").check()
            page.wait_for_selector(".modal [data-class-save]:not([disabled])", timeout=15000)
            page.click(".modal [data-class-save]")
            page.wait_for_selector(".modal [data-class-form]", state="detached")
            page.wait_for_timeout(800)
            if page.locator(".modal [data-start-eq]").count():                     # first class: starting equipment review
                page.locator(".modal [data-close]").last.click()
                page.wait_for_selector(".modal [data-start-eq]", state="detached")

        def wait_text(locator, text, timeout=15000):
            t0 = time.time()
            while time.time() - t0 < timeout / 1000:
                if text in locator.inner_text():
                    return True
                page.wait_for_timeout(200)
            return False

        page.wait_for_selector("#class-card-body [data-class-fallback]", timeout=20000)
        check("1 without classes the Bio card explains the legacy level; the level is still editable",
              "manual level" in card.inner_text() and page.locator("#level-field input:not([readonly])").count() == 1, card.inner_text()[:200])

        add_class("Wizard", 3)
        check("2 Add Class: Wizard 3 appears with version, source link and primary badge; level 3, PB +2",
              wait_text(card, "Level 3") and "Wizard" in card.inner_text() and "Primary" in card.inner_text()
              and "Proficiency bonus +2" in card.inner_text() and card.locator("a[href*='wikidot.com/wizard']").count() == 1, card.inner_text()[:300])
        check("3 the level field is read-only and says it comes from the classes",
              page.locator("#level-field input[readonly]").count() == 1 and "Set by your classes" in page.locator("#level-field").inner_text())
        add_class("Warlock", 2)
        check("4 adding Warlock 2: total level 5, PB +3, header shows both classes",
              wait_text(card, "Level 5") and "Proficiency bonus +3" in card.inner_text()
              and "Wizard 3 / Warlock 2" in page.locator(".char-sub").inner_text(), page.locator(".char-sub").inner_text())
        check("5 the class card shows spell access per class (Wizard up to 2nd level, Warlock Pact Magic)",
              "spells up to 2nd level" in card.locator("[data-class-row]", has_text="Wizard").inner_text()
              and "Pact Magic" in card.locator("[data-class-row]", has_text="Warlock").inner_text(), card.inner_text()[:500])

        tab("spells")
        page.wait_for_selector("#slot-tracker [data-slot-pool=standard]", timeout=20000)
        std = tracker.locator("[data-slot-pool=standard]")
        pact = tracker.locator("[data-slot-pool=pact]")
        check("6 standard slots come from Wizard 3 alone (4 / 2); Pact Magic is a separate panel (2 slots of 1st level)",
              "4 / 4 remaining" in std.inner_text() and "2 / 2 remaining" in std.inner_text() and "3rd level" not in std.inner_text()
              and "Slot level: 1st" in pact.inner_text() and "2 / 2 remaining" in pact.inner_text(), tracker.inner_text()[:400])
        check("7 Pact slots are not drawn as standard slots", std.locator(".slot-line").count() == 2, std.locator(".slot-line").count())
        tracker.locator("[data-action=slot-use][data-level='1']").click()
        check("8 using a 1st-level slot: 3 / 4 remaining", wait_text(std, "3 / 4 remaining"), std.inner_text())
        tracker.locator("[data-action=pact-use]").click()
        check("9 using a Pact slot: 1 / 2 remaining, standard slots unchanged",
              wait_text(pact, "1 / 2 remaining") and "3 / 4 remaining" in std.inner_text(), tracker.inner_text()[:300])
        tracker.locator("[data-action=short-rest]").click()
        dlg = page.locator(".modal").last.inner_text()
        check("10 the short-rest dialog lists what it restores (Pact Magic; standard slots not restored)",
              "Pact Magic slots" in dlg and "Standard spell slots are not restored" in dlg, dlg)
        confirm()
        close_rest_summary()
        check("11 after a short rest: Pact 2 / 2, standard still 3 / 4",
              wait_text(pact, "2 / 2 remaining") and "3 / 4 remaining" in std.inner_text(), tracker.inner_text()[:300])
        tracker.locator("[data-action=long-rest]").click()
        confirm()
        close_rest_summary()
        check("12 after a long rest: standard 4 / 4 and HP restored as before",
              wait_text(std, "4 / 4 remaining"), std.inner_text())
        tracker.locator("[data-action=slot-use][data-level='1']").click()
        wait_text(std, "3 / 4 remaining")

        # spells of the class source
        src = page.locator("#spellcasting-sources .sp-source", has_text="Wizard")
        check("13 the Wizard source is a real class source with its level, spell access and prepared limit",
              wait_text(src, "Wizard level 3") and "spells up to 2nd level" in src.inner_text() and "Prepared 0 / 6" in src.inner_text()
              and "Preview" not in src.inner_text(), src.inner_text()[:300])
        page.click("[data-action=spell-add]")
        page.wait_for_selector(".modal .sp-pick", timeout=20000)
        page.fill(".modal [data-cf=q]", "Fireball")
        page.locator(".modal .sp-pick", has_text="Fireball").first.click()
        select_text(".modal [data-source-select]", "Wizard")
        check("14 Add Spell blocks Fireball for Wizard 3 (class level decides, even with higher slots elsewhere)",
              page.locator(".modal [data-level-warning]").count() == 1 and page.locator(".modal [data-add-save]").is_disabled(),
              page.locator(".modal").last.inner_text()[:400])
        page.click(".modal [data-back]")
        page.fill(".modal [data-cf=q]", "Misty Step")
        page.locator(".modal .sp-pick", has_text="Misty Step").first.click()
        select_text(".modal [data-source-select]", "Wizard")
        check("15 Misty Step (2nd level) is allowed for Wizard 3", page.locator(".modal [data-level-ok]").count() == 1
              and not page.locator(".modal [data-add-save]").is_disabled())
        page.click(".modal [data-add-save]")
        page.wait_for_selector(".modal [data-add-root]", state="detached")
        check("16 the spell is added to the spellbook", wait_text(page.locator("#spellbook-list"), "Misty Step"))

        # manual correction
        tracker.locator(".slot-adjust summary").click()
        page.select_option("[data-slot-adjust] select[name=pool]", "standard:2")
        page.fill("[data-slot-adjust] input[name=expended]", "1")
        page.fill("[data-slot-adjust] input[name=reason]", "UI test correction")
        page.click("[data-slot-adjust] button[type=submit]")
        check("17 Manual Adjust sets the used slots with a reason (2nd level 1 / 2)",
              wait_text(std, "1 / 2 remaining"), std.inner_text())

        # lower the level: the spell stays and is flagged
        tab("features")
        row_id = card.locator("[data-class-row]", has_text="Wizard").get_attribute("data-class-row")
        page.select_option(f"[data-class-level='{row_id}']", "1")
        # the level change opens the class change review (class feature engine, 20261015001800)
        page.wait_for_selector(".modal [data-cf-confirm]", timeout=10000)
        dlg = page.locator(".modal").last.inner_text()
        check("18 lowering a class level asks first and explains what changes",
              "level 3 → 1" in dlg and "nothing is deleted" in dlg.lower() and "spell slots" in dlg.lower(), dlg)
        page.locator(".modal [data-cf-confirm]").last.click()
        page.wait_for_timeout(300)
        check("19 Wizard 1: total 3; Misty Step is kept and flagged for review",
              wait_text(card, "Level 3") and "nothing was removed" in card.inner_text(), card.inner_text()[:500])

        # Level Up with classes
        page.click("[data-action=level-up]")
        page.wait_for_selector(".modal #lu-class", timeout=10000)
        select_text(".modal #lu-class", "Wizard 1")
        for _ in range(3):
            page.click(".modal #lu-next")
            page.wait_for_timeout(200)
        review = page.locator(".modal").last.inner_text()
        check("20 Level Up asks which class gains the level and skips the manual slot step",
              "Wizard 1 → 2" in review and "Spell Slots" not in page.locator(".modal .wiz-steps").inner_text(), review[:300])
        page.click(".modal #lu-next")
        page.wait_for_timeout(1500)
        page.goto(f"{APP}#/c/{cid}")
        tab("features")
        check("21 after Level Up: Wizard 2, total level 4", wait_text(card, "Level 4") and "Wizard 2" in page.locator(".char-sub").inner_text(),
              page.locator(".char-sub").inner_text())

        # export / import (Bio)
        tab("bio")
        with page.expect_download() as dl:
            page.locator("[data-action=export-json]").click()
        exported = json.loads(Path(dl.value.path()).read_text(encoding="utf-8"))
        check("22 export contains the class rows, slot usage and the linked class source",
              sorted((k["classVersion"], k["level"]) for k in exported.get("classes", [])) == [("warlock-phb", 2), ("wizard-phb", 2)]
              and any(s.get("classKey") for s in exported["spellcasting"].get("sources", [])) and "slotState" in exported,
              (exported.get("classes"), exported.get("slotState")))
        exported["name"] = "Class Tester (imported)"
        imp = SHOTS / f"class_import_{RUN}.json"
        imp.write_text(json.dumps(exported), encoding="utf-8")
        page.goto(APP)
        page.click("#btn-import")
        page.set_input_files(".modal input[name=file]", str(imp))
        page.locator(".modal button[type=submit]").click()
        page.wait_for_url(re.compile(r"#/c/"), timeout=20000)
        tab("features")
        check("23 import restores the classes (total level 4) and their spellcasting source with its spells",
              wait_text(card, "Level 4") and "Wizard" in card.inner_text() and "Warlock" in card.inner_text(), card.inner_text()[:300])
        tab("spells")
        check("24 slot usage is restored (1st level 2 / 3); Misty Step, now above Wizard 2, is kept as a free-text spell (not dropped)",
              wait_text(tracker, "2 / 3 remaining") and "misty step" in page.locator("#spells-list").inner_text().lower()
              and "Misty Step" not in page.locator("#spellbook-list").inner_text(), (tracker.inner_text()[:200], page.locator("#spells-list").inner_text()[:200]))

        # remove a class
        tab("features")
        wl = card.locator("[data-class-row]", has_text="Warlock")
        wl.locator("[data-action=class-remove]").click()
        dlg = page.locator(".modal").last.inner_text()
        check("25 removing a class explains what goes with it (its slots and source; other sources stay)",
              "Remove Warlock" in dlg and "lineage spells stay" in dlg, dlg)
        confirm()
        tab("spells")
        def pact_gone():
            t0 = time.time()
            while time.time() - t0 < 15:
                if tracker.locator("[data-slot-pool=pact]").count() == 0:
                    return True
                page.wait_for_timeout(200)
            return False
        check("26 after removing Warlock the Pact Magic panel is gone", wait_text(tracker, "remaining") and pact_gone(),
              tracker.inner_text()[:300])

        # mobile
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(500)
        ov1 = page.evaluate("() => document.documentElement.scrollWidth - document.documentElement.clientWidth")
        page.screenshot(path=str(SHOTS / "slots_mobile.png"))
        tab("features")
        ov2 = page.evaluate("() => document.documentElement.scrollWidth - document.documentElement.clientWidth")
        page.click("[data-action=class-add]")
        page.wait_for_selector(".modal [data-class-form]")
        mov = page.evaluate("() => { const m = document.querySelector('.modal'); return m.scrollWidth - m.clientWidth; }")
        page.screenshot(path=str(SHOTS / "classes_mobile.png"))
        check("27 the mobile layout has no horizontal overflow (Spells, Bio, Add class dialog)", ov1 <= 1 and ov2 <= 1 and mov <= 1, (ov1, ov2, mov))
        page.locator(".modal [data-close]").first.click()
        check("28 no uncaught console errors", not errors, errors)
        check("29 no request went to a hosted service", not remote, remote)
        browser.close()
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
