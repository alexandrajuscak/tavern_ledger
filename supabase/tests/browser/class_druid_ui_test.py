"""Browser test of the Druid (Circle of the Moon) and the transformation / companion engines: Wild Shape panel, form picker
(allowed forms, reasons for the others, search, cost), the current form with its hit points (damage, heal, carry-over),
returning to normal form, the Companions card (add from the catalog, damage, remove), keyboard, mobile layout, local-only
network, no console errors.
"""
from playwright.sync_api import sync_playwright

from class_ui_common import SHOTS, Sheet, User, call, check, report


def main():
    u = User("druid")
    dr = u.character("Druid UI Tester", [("druid-phb", 6, "druid-moon-phb")], wisdom=16, dexterity=14, constitution=14)
    SHOTS.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, u, tab="features")
        page = s.page
        s.open(dr)
        s.tab("features")
        panel = page.locator('#class-transform [data-transform="idle"]')
        check("DU1 the class page shows Wild Shape: 2 / 2 uses, beast forms up to CR 2 (Circle Forms), Choose a form",
              s.wait(lambda: panel.count() == 1 and "Wild Shape" in panel.text_content() and "2 / 2" in panel.text_content() and "CR 2" in panel.text_content()),
              panel.inner_text() if panel.count() else page.locator("#class-transform").inner_html()[:300])
        panel.locator("[data-action=tf-pick]").click()
        page.wait_for_selector(".modal [data-ws-picker]")
        lst = page.locator(".modal [data-ws-results]")
        check("DU2 the picker lists usable forms only by default (Brown Bear yes, Giant Eagle no)",
              s.wait(lambda: lst.locator('[data-ws-form="brown-bear"]').count() == 1) and lst.locator('[data-ws-form="giant-eagle"]').count() == 0)
        page.locator('.modal [data-f="status"]').select_option("all")
        page.fill('.modal [data-f="q"]', "eagle")
        check("DU3 showing all forms: Giant Eagle is listed as locked (flying speed)",
              s.wait(lambda: "Giant Eagle" in lst.inner_text() and "fly" in lst.inner_text().lower()), lst.inner_text()[:300])
        page.fill('.modal [data-f="q"]', "brown bear")
        bear = lst.locator('[data-ws-form="brown-bear"]')
        check("DU4 the brown bear card shows its statistics (AC 11, HP 34, Bite / Claws)",
              s.wait(lambda: "HP 34" in bear.inner_text() and "AC 11" in bear.inner_text() and "Multiattack" in bear.inner_text()))
        bear.locator("[data-ws-take]").click()
        page.wait_for_selector(".modal [data-ws-confirm]")
        page.click(".modal [data-ws-confirm]")
        s.tab("combat")
        active = page.locator('#combat-transform [data-transform="active"]')
        check("DU5 Brown Bear is the current form: 34 / 34 form HP, 1 / 2 uses left",
              s.wait(lambda: active.count() == 1 and "34" in active.locator("[data-ws-form-hp]").inner_text() and "1 / 2 left" in active.text_content()))
        active.locator("[data-tf-amount]").fill("10")
        active.locator("[data-action=tf-damage]").click()
        check("DU6 10 damage: 24 / 34", s.wait(lambda: "24" in page.locator('#combat-transform [data-ws-form-hp]').inner_text()))
        page.locator('#combat-transform [data-tf-amount]').fill("30")
        page.locator('#combat-transform [data-action=tf-damage]').click()
        page.wait_for_selector(".modal [data-ok]")
        page.locator(".modal").last.locator("[data-ok]").click()
        check("DU7 30 damage (confirmed) ends the form and 6 damage carries over (toast)",
              s.wait(lambda: "6 damage carries over" in s.toasts()) and s.wait(lambda: page.locator('#combat-transform [data-transform="idle"]').count() == 1),
              s.toasts())
        _, rows = call("GET", f"/rest/v1/characters?id=eq.{dr}&select=hp_current", token=u.jwt)
        check("DU8 the character lost the 6 carried-over hit points (40 -> 34)", rows and rows[0]["hp_current"] == 34, rows)
        s.tab("features")
        check("DU9 the class page shows the Wild Shape panel too", s.wait(lambda: page.locator('#class-transform [data-transform]').count() == 1))
        s.tab("combat")
        page.click("[data-action=comp-add]")
        page.wait_for_selector(".modal [data-comp-form]")
        page.fill(".modal [data-comp-q]", "owl")
        page.locator('.modal [data-comp-option="owl"]').click()
        page.fill(".modal input[name=name]", "Pip")
        page.fill(".modal input[name=source]", "Find Familiar")
        page.click(".modal [data-comp-ok]")
        comp = page.locator("#companions-body [data-companion]")
        check("DU10 the owl Pip is a companion with 1 / 1 HP and its talons attack",
              s.wait(lambda: comp.count() == 1 and "Pip" in comp.inner_text() and "1 / 1" in comp.inner_text() and "Talons" in comp.inner_text()),
              comp.inner_text() if comp.count() else "")
        comp.locator("[data-action=comp-hp][data-sign='-1']").click()
        check("DU11 damaging Pip: 0 / 1", s.wait(lambda: "0 / 1" in page.locator("#companions-body [data-companion]").inner_text()))
        page.locator("#companions-body [data-action=comp-remove]").click()
        page.locator(".modal .btn-bad, .modal [data-ok]").last.click()
        check("DU12 removing Pip empties the Companions card", s.wait(lambda: page.locator("#companions-body [data-companion]").count() == 0))
        check("DU13 no console errors and only local network traffic", not s.errors and not s.remote, (s.errors[:3], s.remote[:3]))
        page.screenshot(path=str(SHOTS / "class-druid.png"), full_page=True)
        s.close()

        m = Sheet(browser, u, width=390, height=844, tab="features")
        m.open(dr)
        m.tab("features")
        m.page.click("#class-transform [data-action=tf-pick]")
        m.page.wait_for_selector(".modal [data-ws-picker]")
        check("DU14 mobile 390 px: the form picker has no horizontal overflow", m.overflow() <= 0, m.overflow())
        m.page.keyboard.press("Escape")
        m.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
