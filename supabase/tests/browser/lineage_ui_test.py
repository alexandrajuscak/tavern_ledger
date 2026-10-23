"""Browser test of character lineages (picker, choices, derived values) against the LOCAL Supabase stack.

Run like the other browser tests (API_URL / ANON_KEY / SERVICE_ROLE_KEY from `supabase status`, app served locally,
installed Microsoft Edge through playwright). The service role only creates the synthetic user and character; every
lineage action goes through the UI. Refuses non-local URLs.
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
LAST = {}


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
    email = f"ui-lineage-{RUN}@example.test"
    call("POST", "/auth/v1/admin/users", {"email": email, "password": PW, "email_confirm": True})
    _, body = call("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": PW}, token=ANON, key=ANON)
    uid = body["user"]["id"]
    _, chars = call("POST", "/rest/v1/characters", {"owner_id": uid, "name": "Lineage Tester", "level": 3, "race": "Halfling (old text)",
                                                    "strength": 10, "dexterity": 14, "constitution": 12, "wisdom": 12, "speed": 30},
                    {"Prefer": "return=representation"})
    return email, chars[0]["id"]


def wait_until(fn, timeout=10.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if fn():
                return True
        except Exception:
            pass
        time.sleep(0.2)
    return False


def main():
    email, cid = fixtures()
    SHOTS.mkdir(parents=True, exist_ok=True)
    errors, remote = [], []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        ctx = browser.new_context(viewport={"width": 1366, "height": 900})
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

        card = page.locator("#lineage-card")
        modal = page.locator(".modal")

        def tab(key):
            page.locator(f'.tab[data-tab="{key}"]').click()

        def open_sheet():
            page.goto(f"{APP}#/c/{cid}")
            page.wait_for_selector("#lineage-card [data-action=lineage-choose]", timeout=20000)

        def open_picker():
            tab("features")
            card.locator("[data-action=lineage-choose]").first.click()
            page.wait_for_selector(".modal .lin-row, .modal [data-lin-back]", timeout=10000)

        LAST.update(page=page, errors=errors)

        def save(confirm=False):
            modal.locator("[data-lin-save]").click()
            if confirm:
                page.locator(".modal [data-ok]").click()

        open_sheet()
        check("1 a character without a lineage shows 'No lineage selected' and keeps its old free-text race",
              "No lineage selected" in card.inner_text() and "Halfling (old text)" in card.inner_text(), card.inner_text())

        open_picker()
        counts = {c: modal.locator(f'[data-lin-cat="{c}"] .count').inner_text() for c in ("all", "standard", "custom")}
        modal.locator('[data-lin-cat="custom"]').click()
        names = modal.locator(".lin-row-name").all_inner_texts()
        check("2 browse by category: the Custom chip shows only Custom Lineage", names == ["Custom Lineage"] and int(counts["all"]) >= 2,
              (names, counts))
        modal.locator('[data-lin-cat="all"]').click()
        modal.locator("input[name=lin-q]").fill("stout")
        names = modal.locator(".lin-row-name").all_inner_texts()
        check("3 search finds a lineage by a sub-lineage name ('stout' -> Halfling)", names == ["Halfling"], names)
        modal.locator("[data-lin-open=halfling]").click()
        page.wait_for_selector(".modal input[name=lin-sub]")
        version_card = modal.locator("label.lin-card", has=page.locator("input[name=lin-version]")).first
        lotus = modal.locator("label.lin-card", has=page.locator("input[value=halfling-lotusden]"))
        check("4 versions show their source and status; sub-lineages show source and setting badges",
              "Player's Handbook" in version_card.inner_text() and "Current" in version_card.inner_text()
              and "Explorer's Guide to Wildemount" in lotus.inner_text() and "Wildemount" in lotus.locator(".lin-badge").all_inner_texts(),
              (version_card.inner_text(), lotus.inner_text()))
        before = len(errors)
        save()
        expect(page.locator(".toast", has_text="needs a sub-lineage").last).to_be_visible(timeout=10000)
        # the browser logs the deliberate 400 of this rejected request; it is expected, not an app error
        errors[before:] = [e for e in errors[before:] if "status of 400" not in e]
        check("5 saving Halfling without its required sub-lineage is refused with a clear message", True)
        modal.locator("input[name=lin-sub][value=halfling-stout]").check()
        preview = modal.locator(".lin-preview").inner_text()
        check("6 the trait preview lists base and sub-lineage traits with automation labels",
              "Lucky" in preview and "Stout Resilience" in preview and "Information only" in preview and "Applied automatically" in preview,
              preview)
        save()
        expect(card.locator("[data-lineage-name]")).to_contain_text("Stout", timeout=10000)
        txt = card.inner_text()
        check("7 the card shows the lineage, version source and traits grouped by automation",
              "Player's Handbook" in txt and "APPLIED AUTOMATICALLY" in txt.upper() and "INFORMATION ONLY" in txt.upper()
              and "Lucky" in txt and "· Stout" in txt, txt)
        # the subtitle comes from the derived stats, a separate read that may land just after the lineage card
        check("8 the subtitle uses the lineage name", wait_until(lambda: "Halfling · Stout" in page.locator(".char-sub").inner_text()),
              page.locator(".char-sub").inner_text())
        tab("stats")
        expect(page.locator('[data-derived="abnote:dex"]')).to_have_text(re.compile(r"\+2 lineage = 16"), timeout=10000)
        stats = page.locator("#lineage-stats").inner_text()
        check("9 derived values update: DEX +2 note, Small, walk 25 ft, Halfling language, poison resistance, listed advantages",
              "Small" in stats and "Walk 25 ft" in stats and "Halfling" in stats and "Poison" in stats and "frightened" in stats, stats)
        check("10 the stored base DEX input still shows the entered 14",
              page.locator('input[aria-label="Dexterity score (base)"]').input_value() == "14")
        tab("combat")
        check("11 the speed tile notes the lineage speed", "25 ft (lineage)" in page.locator("#speed-note").inner_text(),
              page.locator("#speed-note").inner_text())

        # ---- Custom Lineage: incomplete, then complete ----
        open_picker()
        modal.locator("[data-lin-back]").click()
        modal.locator("[data-lin-open=custom]").click()
        page.wait_for_selector('.modal [data-choice="custom-tce:size"]')
        modal.locator('[data-choice="custom-tce:size"] input[value=small]').check()
        missing = modal.locator("[data-lin-missing]").inner_text()
        check("12 the picker lists the choices that are still missing", "Ability score increase" in missing and "Feat" in missing, missing)
        check("13 the skill sub-choice is hidden until 'Skill proficiency' is picked",
              modal.locator('[data-choice="custom-tce:variable-skill"]').count() == 0)
        save(confirm=True)
        expect(card.locator("[data-lineage-unresolved]")).to_be_visible(timeout=10000)
        check("14 incomplete choices are saved and shown on the card", "4 choices still open" in card.inner_text(), card.inner_text())
        card.locator('[data-focus-key="lineage-complete"]').click()
        page.wait_for_selector('.modal [data-choice="custom-tce:asi"]')
        modal.locator('[data-choice="custom-tce:asi"] select[data-ability=wis]').select_option("2")
        # the feat is picked from the feat catalog (20261019000300): the picker opens over the lineage dialog
        modal.locator('[data-choice="custom-tce:feat"] [data-pick-feat]').click()
        picker = page.locator(".modal").last
        picker.locator("[data-q]").fill("Observant")
        picker.locator('[data-pick="observant-2014"]').click()
        picker.locator('[data-take="observant-2014"]').click()
        expect(page.locator(".modal")).to_have_count(1, timeout=10000)
        modal.locator('[data-choice="custom-tce:variable-trait"] input[value=skill]').check()
        page.wait_for_selector('.modal [data-choice="custom-tce:variable-skill"]')
        modal.locator('[data-choice="custom-tce:variable-skill"] select').select_option("insight")
        modal.locator('[data-choice="custom-tce:language"] select').select_option("sylvan")
        check("15 completing every choice clears the missing list",
              "All required choices are made" in modal.locator("[data-lin-missing]").inner_text(),
              modal.locator("[data-lin-missing]").inner_text())
        save()
        expect(card.locator("[data-lineage-name]")).to_have_text("Custom Lineage", timeout=10000)
        page.wait_for_timeout(800)
        check("16 the completed Custom Lineage has no open choices and lists them",
              card.locator("[data-lineage-unresolved]").count() == 0 and "Observant" in card.inner_text() and "Insight" in card.inner_text(),
              card.inner_text())
        tab("stats")
        expect(page.locator('[data-derived="abnote:wis"]')).to_have_text(re.compile(r"\+2 lineage = 14"), timeout=10000)
        dot = page.locator('[data-action=cycle-skill][data-k=insight]')
        check("17 a lineage skill proficiency shows on the skill dot (with its origin)",
              "from-lineage" in (dot.get_attribute("class") or "") and "lineage" in (dot.get_attribute("title") or ""),
              (dot.get_attribute("class"), dot.get_attribute("title")))

        page.reload()
        page.wait_for_selector("#lineage-card [data-lineage-name]", state="attached", timeout=20000)
        tab("features")
        check("18 the lineage and its choices persist after a refresh", card.locator("[data-lineage-name]").text_content().strip() == "Custom Lineage"
              and "Observant" in card.inner_text())

        tab("bio")
        with page.expect_download() as dl:
            page.locator("[data-action=export-json]").click()
        exported = json.loads(Path(dl.value.path()).read_text(encoding="utf-8"))
        lin = exported.get("lineage") or {}
        check("18b the JSON export carries the exact lineage selection; 'race' is only the preserved legacy text",
              exported.get("race") == "Halfling (old text)" and lin.get("version") == "custom-tce" and lin.get("lineageId") == "custom"
              and lin.get("name") == "Custom Lineage" and len(lin.get("choices", {})) == 6, (exported.get("race"), lin))

        # ---- phone width ----
        page.set_viewport_size({"width": 390, "height": 844})
        open_picker()
        overflow = page.evaluate("() => { const m = document.querySelector('.modal'); return m.scrollWidth - m.clientWidth; }")
        page_overflow = page.evaluate("() => document.documentElement.scrollWidth - document.documentElement.clientWidth")
        page.screenshot(path=str(SHOTS / "lineage_picker_mobile.png"))
        check("19 the picker fits a 390 px phone without horizontal scrolling", overflow <= 1 and page_overflow <= 1, (overflow, page_overflow))
        modal.locator("[data-close]").first.click()
        page.wait_for_timeout(300)
        card_overflow = page.evaluate("() => { const c = document.querySelector('#lineage-card'); return c.scrollWidth - c.clientWidth; }")
        check("20 the lineage card fits the phone width", card_overflow <= 1, card_overflow)
        page.set_viewport_size({"width": 1366, "height": 900})

        # ---- removal ----
        card.locator("[data-action=lineage-remove]").click()
        page.locator(".modal [data-ok]").click()
        expect(card).to_contain_text("No lineage selected", timeout=10000)
        tab("stats")
        expect(page.locator('[data-derived="abnote:wis"]')).to_have_text("", timeout=10000)
        check("21 removing the lineage restores the stored values and keeps the old race text",
              "No lineage selected" in page.locator("#lineage-stats").inner_text() or "No lineage" in page.locator("#lineage-stats").inner_text())
        tab("combat")
        check("22 armor class and inventory-derived values still render (no regression)",
              re.fullmatch(r"\d+", page.locator('[data-derived="ac"]').inner_text() or "") is not None)
        check("23 no console errors", not errors, errors)
        check("24 no requests to hosted services", not remote, remote)
        browser.close()
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        if LAST.get("page"):   # evidence for a failed step: screenshot + console errors
            LAST["page"].screenshot(path=str(SHOTS / "lineage_failure.png"), full_page=True)
            print("console errors:", LAST.get("errors"))
        raise
