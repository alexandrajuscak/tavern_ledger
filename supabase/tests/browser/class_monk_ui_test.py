"""Browser test of the Monk (Way of the Open Hand): Unarmored Defense AC, the Martial Arts unarmed strike on the Combat tab,
Ki points spent by an amount, the Ki save DC in At a glance, Unarmored Movement speed, Wholeness of Body use, a short rest
restoring Ki, mobile layout, local-only network, no console errors.
"""
from playwright.sync_api import sync_playwright

from class_ui_common import SHOTS, Sheet, User, check, report


def main():
    u = User("monk")
    mk = u.character("Monk UI Tester", [("monk-phb", 6, "monk-open-hand-phb")], dexterity=16, wisdom=16, constitution=12)
    SHOTS.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, u, tab="features")
        page = s.page
        s.open(mk)
        s.tab("combat")
        glance = page.locator("[data-cf-glance]")
        check("MU1 Play: Ki save DC 14 (8 + 3 + WIS 3) ready to use, and 2 attacks with the attacks",
              s.wait(lambda: glance.count() == 1 and "Ki save DC 14" in glance.inner_text() and "2 attacks" in page.locator("#feature-attacks").inner_text()),
              glance.inner_text()[:400] if glance.count() else "")
        ki = glance.locator('[data-cf-quick$="monk-ki-phb-points"]')
        check("MU2 Ki 6 / 6 with an amount field (points)", ki.count() == 1 and "6 / 6" in ki.inner_text() and ki.locator("[data-cf-amount]").count() == 1)
        ki.locator("[data-cf-amount]").fill("3")
        ki.locator("[data-cf-action=res-use]").click()
        check("MU3 spending 3 ki leaves 3 / 6", s.wait(lambda: "3 / 6" in glance.locator('[data-cf-quick$="monk-ki-phb-points"]').inner_text()))
        whole = glance.locator('[data-cf-quick$="monk-open-hand-wholeness-of-body-phb-uses"]')
        whole.locator("[data-cf-action=res-use]").click()
        check("MU4 Wholeness of Body is used (0 / 1)", s.wait(lambda: "0 / 1" in glance.locator('[data-cf-quick$="monk-open-hand-wholeness-of-body-phb-uses"]').inner_text()))
        s.tab("combat")
        panel = page.locator('[data-panel="combat"]')
        check("MU5 Combat tab: Unarmed Strike (Martial Arts) +6 to hit, 1d6 + 3",
              s.wait(lambda: "Unarmed Strike (Martial Arts)" in panel.inner_text() and "1d6 + 3" in panel.inner_text()), panel.inner_text()[:500])
        s.tab("stats")
        check("MU6 Unarmored Defense AC 16 and speed 45 (Unarmored Movement +15)",
              s.wait(lambda: page.locator('[data-derived="ac"]').first.inner_text().strip() == "16")
              and "45" in page.locator('[data-derive="speed"]').first.text_content(),
              (page.locator('[data-derived="ac"]').first.inner_text(), page.locator('[data-derive="speed"]').first.text_content()))
        st, r = u.rpc("short_rest_character", p_character=mk)
        s.open(mk)
        s.tab("features")
        check("MU7 after a short rest Ki is 6 / 6 again, Wholeness of Body stays used",
              s.wait(lambda: "6 / 6" in page.locator('[data-cf-glance] [data-cf-quick$="monk-ki-phb-points"]').inner_text()
                     and "0 / 1" in page.locator('[data-cf-glance] [data-cf-quick$="monk-open-hand-wholeness-of-body-phb-uses"]').inner_text()))
        check("MU8 no console errors and only local network traffic", not s.errors and not s.remote, (s.errors[:3], s.remote[:3]))
        page.screenshot(path=str(SHOTS / "class-monk.png"), full_page=True)
        s.close()

        m = Sheet(browser, u, width=390, height=844, tab="features")
        m.open(mk)
        m.tab("features")
        m.page.wait_for_timeout(800)
        check("MU9 mobile 390 px: the Monk class page has no horizontal overflow", m.overflow() <= 0, m.overflow())
        m.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
