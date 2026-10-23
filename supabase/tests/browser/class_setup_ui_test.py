"""Browser test of the guided class setup: choosing the first class (live preview of features and proficiencies, nothing
stored before confirming), the starting equipment review (one option per group, concrete weapons for "two martial weapons",
added to the inventory once), the multiclass Add Class flow (prerequisites of every class with the scores, the DM override,
multiclass proficiencies, no starting equipment), mobile layout, local-only network, no console errors.
"""
from playwright.sync_api import sync_playwright

from class_ui_common import SHOTS, Sheet, User, call, check, report


def main():
    u = User("setup")
    ch = u.character("Setup UI Tester", [], strength=16, charisma=14, intelligence=10, wisdom=10, dexterity=12)
    SHOTS.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, u, tab="features")
        page = s.page
        s.open(ch)
        s.tab("features")
        page.click("[data-action=class-add]")
        page.wait_for_selector(".modal [data-add-class]")
        page.select_option(".modal select[name=class]", "paladin")
        summary = page.locator(".modal [data-add-summary]")
        check("SE1 choosing the first class: the preview lists Divine Sense and Lay on Hands, the saving throws and the starting equipment note",
              s.wait(lambda: "Divine Sense" in summary.inner_text() and "Lay on Hands" in summary.inner_text()
                     and "starting equipment" in summary.inner_text().lower()), summary.inner_text()[:400] if summary.count() else "")
        _, rows = call("GET", f"/rest/v1/character_classes?character_id=eq.{ch}&select=id", token=u.jwt)
        check("SE2 nothing is stored while previewing", rows == [], rows)
        page.click(".modal [data-class-save]")
        page.wait_for_selector(".modal [data-start-eq]", timeout=15000)
        form = page.locator(".modal [data-start-eq]")
        ok = page.locator(".modal [data-eq-ok]")
        check("SE3 after adding, the starting equipment review opens with 4 groups; Add is disabled until everything is chosen",
              form.locator("[data-eq-group]").count() == 4 and ok.is_disabled())
        form.locator("input[name=g1][value=b]").check()
        picks = form.locator('select[data-pick="1:b:0"]')
        check("SE4 'Two martial weapons' gives two pickers with official martial weapons (Longsword yes, Dagger no)",
              picks.count() == 2 and picks.first.locator("option[value=longsword]").count() == 1 and picks.first.locator("option[value=dagger]").count() == 0)
        picks.nth(0).select_option("longsword")
        picks.nth(1).select_option("warhammer")
        form.locator("input[name=g2][value=a]").check()
        form.locator("input[name=g3][value=b]").check()
        form.locator('select[data-pick="4:a:1"]').select_option("emblem")
        check("SE5 everything chosen: 'Ready to add'", s.wait(lambda: not ok.is_disabled()) and "Ready" in form.locator("[data-eq-status]").inner_text())
        ok.click()
        check("SE6 ten items are added to the inventory (toast)", s.wait(lambda: "Added 10 items" in s.toasts()), s.toasts())
        s.tab("inventory")
        inv = page.locator("#inventory-app")
        check("SE7 the inventory shows Longsword, Warhammer, Javelin, Chain Mail",
              s.wait(lambda: all(x in inv.inner_text() for x in ("Longsword", "Warhammer", "Javelin", "Chain Mail"))), inv.inner_text()[:300])
        s.tab("features")
        check("SE8 the class card no longer offers 'Starting equipment…'", s.wait(lambda: page.locator("[data-action=class-start-eq]").count() == 0))

        # ---- multiclass ---------------------------------------------------------------------------------------------------
        page.click("[data-action=class-add]")
        page.wait_for_selector(".modal [data-add-class]")
        page.select_option(".modal select[name=class]", "wizard")
        prereq = page.locator(".modal [data-add-prereq]")
        save = page.locator(".modal [data-class-save]")
        check("SE9 Wizard: its prerequisite (INT 13, you have 10) is not met, the Paladin's is; Add is disabled",
              s.wait(lambda: prereq.count() == 1 and "INT 13" in prereq.inner_text() and "INT 10" in prereq.inner_text())
              and page.locator('.modal [data-prereq="wizard"].is-unmet').count() == 1 and page.locator('.modal [data-prereq="paladin"].is-met').count() == 1
              and save.is_disabled(), prereq.inner_text() if prereq.count() else "")
        page.locator(".modal input[name=dm_ok]").check()
        check("SE10 'My DM allows this' enables Add", s.wait(lambda: not save.is_disabled()))
        page.select_option(".modal select[name=class]", "fighter")
        summary = page.locator(".modal [data-add-summary]")
        check("SE11 Fighter: prerequisites met, multiclass proficiencies listed, no starting equipment",
              s.wait(lambda: page.locator('.modal [data-prereq="fighter"].is-met').count() == 1 and "martial weapons" in summary.inner_text()
                     and "no starting equipment" in summary.inner_text() and not save.is_disabled()), summary.inner_text()[:400] if summary.count() else "")
        page.click(".modal [data-class-save]")
        page.wait_for_selector(".modal [data-add-class]", state="detached")
        check("SE12 Fighter is added (Level 2 total) and no equipment review opens",
              s.wait(lambda: "Level 2" in page.locator("[data-class-total]").inner_text()) and page.locator(".modal [data-start-eq]").count() == 0)
        page.click("[data-action=class-add]")
        page.wait_for_selector(".modal [data-add-class]")
        page.locator(".modal select[name=class]").focus()
        page.keyboard.press("Escape")
        check("SE13 the Add Class dialog closes with Escape", s.wait(lambda: page.locator(".modal [data-add-class]").count() == 0))
        check("SE14 no console errors and only local network traffic", not s.errors and not s.remote, (s.errors[:3], s.remote[:3]))
        page.screenshot(path=str(SHOTS / "class-setup.png"), full_page=True)
        s.close()

        m = Sheet(browser, u, width=390, height=844, tab="features")
        m.open(ch)
        m.tab("features")
        m.page.click("[data-action=class-add]")
        m.page.wait_for_selector(".modal [data-add-summary]", timeout=15000)
        check("SE15 mobile 390 px: the Add Class dialog has no horizontal overflow", m.overflow() <= 0, m.overflow())
        m.page.screenshot(path=str(SHOTS / "class-setup-mobile.png"), full_page=True)
        m.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
