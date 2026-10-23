"""Browser test of the half-caster / Pact Magic phase (Paladin + Devotion, Ranger + Hunter, Warlock + Fiend): slot riders
(Divine Smite spends a standard slot, Eldritch Smite a Pact slot; the dice follow the slot level), Lay on Hands spent by an
amount, Aura of Protection in the saving throws, condition immunities, Tasha's optional replacement switched on the class
page (Favored Foe rider), Eldritch Master (regain all Pact slots), mobile layout, local-only network, no console errors.
"""
from playwright.sync_api import sync_playwright

from class_ui_common import SHOTS, Sheet, User, call, check, report


def class_row(u, cid, class_id):
    _, rows = call("GET", f"/rest/v1/character_classes?character_id=eq.{cid}&class_id=eq.{class_id}&select=id", token=u.jwt)
    return rows[0]["id"]


def choose(u, cid, row, unlock, choice, values):
    st, r = u.rpc("set_character_feature_choice", p_character=cid, p_character_class=row, p_unlock=unlock, p_choice=choice,
                  p_values=values, p_manual_status=None)
    assert st == 200, (st, r)


def main():
    u = User("hybrid")
    pal = u.character("Paladin UI Tester", [("paladin-phb", 6, "paladin-devotion-phb")], strength=16, charisma=16, constitution=14)
    rng = u.character("Ranger UI Tester", [("ranger-phb", 3, "ranger-hunter-phb")], dexterity=16, wisdom=14)
    wl = u.character("Warlock UI Tester", [("warlock-phb", 20, "warlock-fiend-phb")], charisma=18, dexterity=14)
    row = class_row(u, wl, "warlock")
    choose(u, wl, row, "warlock-phb-u3-pact-boon", "warlock-pact-boon-phb-pact", ["pact-of-the-blade"])
    choose(u, wl, row, "warlock-phb-u2-eldritch-invocations", "warlock-eldritch-invocations-phb-invocations",
           ["eldritch-smite", "devils-sight", "armor-of-shadows", "thirsting-blade", "mire-the-mind", "beguiling-influence",
            "misty-visions", "mask-of-many-faces"])
    SHOTS.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, u, tab="features")
        page = s.page

        # ---- Paladin ------------------------------------------------------------------------------------------------------
        s.open(pal)
        s.tab("features")
        s.tab("combat")
        glance = page.locator("[data-cf-glance]")
        smite = page.locator('#feature-attacks [data-attack-rider="Divine Smite"]')
        check("HY1 Play → Attacks: Divine Smite 2d8–5d8 with a 'Spend a slot' button",
              s.wait(lambda: smite.count() == 1 and "2d8–5d8" in smite.inner_text()
                     and smite.locator("[data-action=rider-slot]").count() == 1), glance.inner_text()[:400] if glance.count() else "")
        smite.locator("[data-action=rider-slot]").click()
        page.wait_for_selector(".modal [data-rider-form]")
        body = page.locator(".modal [data-rider-form]").inner_text()
        check("HY2 the smite dialog lists the slots with their dice (1st: 2d8, 2nd: 3d8) and radiant damage",
              "2d8" in body and "3d8" in body and "radiant" in body, body)
        page.locator(".modal input[name=rslot][data-level='2']").check()
        page.click(".modal [data-rider-ok]")
        page.wait_for_selector(".modal [data-rider-form]", state="detached")
        check("HY3 spending a 2nd-level slot says to roll 3d8 and the tracker shows 1 / 2 2nd-level slots",
              s.wait(lambda: "3d8" in s.toasts()) and s.wait(lambda: page.evaluate(
                  "() => (document.querySelector('[data-slot-count=\"2\"]')?.textContent || '').includes('1 / 2')")), s.toasts())
        loh = glance.locator('[data-cf-quick$="paladin-lay-on-hands-phb-pool"]')
        check("HY4 Lay on Hands (pool 30) has an amount field and a Spend button",
              loh.count() == 1 and loh.locator("[data-cf-amount]").count() == 1 and "30 / 30" in loh.inner_text(), loh.inner_text() if loh.count() else "")
        loh.locator("[data-cf-amount]").fill("7")
        loh.locator("[data-cf-action=res-use]").click()
        check("HY5 spending 7 leaves 23 / 30", s.wait(lambda: "23 / 30" in glance.locator('[data-cf-quick$="paladin-lay-on-hands-phb-pool"]').inner_text()),
              glance.locator('[data-cf-quick$="paladin-lay-on-hands-phb-pool"]').inner_text())
        s.tab("stats")
        save = page.locator('[data-derive="save:str"]').first
        check("HY6 Aura of Protection: the STR save is +6 (STR +3, CHA +3, not proficient) and explains the aura",
              s.wait(lambda: save.inner_text().strip() == "+6") and "Aura of Protection" in (save.get_attribute("title") or ""),
              (save.inner_text(), save.get_attribute("title")))
        s.tab("combat")
        card = page.locator('[data-attack-rider="Divine Smite"]')
        check("HY7 Combat tab: the Divine Smite card says it spends a spell slot and offers the same action",
              s.wait(lambda: card.count() == 1 and "spend a spell slot" in card.inner_text()
                     and card.locator("[data-action=rider-slot]").count() == 1), card.inner_text() if card.count() else "")
        page.screenshot(path=str(SHOTS / "class-hybrid-paladin.png"), full_page=True)

        # ---- Ranger: optional replacement -------------------------------------------------------------------------------
        s.open(rng)
        s.tab("features")
        opt = s.panel.locator('[data-cf-action=optional][data-unlock="ranger-phb-u1-favored-foe"]').first
        check("HY8 the Ranger page offers Favored Foe as an optional replacement", s.wait(lambda: opt.count() == 1))
        opt.click()
        check("HY9 switched on, Favored Foe 1d4 appears with the attacks and Favored Enemy is marked replaced",
              s.wait(lambda: page.locator('[data-attack-rider="Favored Foe"]').count() == 1
                     and "1d4" in page.locator('[data-attack-rider="Favored Foe"]').text_content())
              and s.wait(lambda: "eplaced" in s.panel.text_content()),
              (page.locator("[data-cf-glance]").inner_text()[:300] if page.locator("[data-cf-glance]").count() else "no glance", s.toasts()))

        # ---- Warlock: Pact riders and Eldritch Master --------------------------------------------------------------------
        s.open(wl)
        s.tab("spells")
        em = page.locator("[data-slot-actions] [data-action=slot-recover]")
        check("HY10 Eldritch Master: 'Regain Pact slots' is disabled while no Pact slot is spent",
              s.wait(lambda: em.count() == 1 and em.is_disabled()) and "no expended Pact slot" in page.locator("[data-slot-actions]").inner_text())
        page.click("[data-action=pact-use]")
        s.wait(lambda: "3 / 4 remaining" in page.locator("[data-pact-count]").inner_text())
        page.click("[data-action=pact-use]")
        check("HY11 after spending 2 Pact slots the button is enabled",
              s.wait(lambda: "2 / 4 remaining" in page.locator("[data-pact-count]").inner_text()) and s.wait(lambda: not em.is_disabled()))
        em.click()
        page.wait_for_selector(".modal [data-recover-ok]")
        txt = page.locator(".modal").inner_text()
        page.click(".modal [data-recover-ok]")
        check("HY12 the dialog says 2 slots come back; the Pact panel is 4 / 4 again and the feature is used",
              "2" in txt and s.wait(lambda: "4 / 4 remaining" in page.locator("[data-pact-count]").inner_text())
              and s.wait(lambda: "already used" in page.locator("[data-slot-actions]").inner_text()), txt)
        s.tab("combat")
        es = page.locator('[data-attack-rider="Eldritch Smite"]')
        check("HY13 Combat tab: Eldritch Smite spends a Pact Magic slot", s.wait(lambda: es.count() == 1 and "Pact Magic" in es.inner_text()),
              es.inner_text() if es.count() else "")
        es.locator("[data-action=rider-slot]").click()
        page.wait_for_selector(".modal [data-rider-form]")
        body = page.locator(".modal [data-rider-form]").inner_text()
        check("HY14 the dialog offers the Pact slot (5th level) with 6d8", "Pact Magic slot" in body and "6d8" in body, body)
        page.locator(".modal input[name=rslot]").first.check()
        page.click(".modal [data-rider-ok]")
        page.wait_for_selector(".modal [data-rider-form]", state="detached")
        s.tab("spells")
        check("HY15 the Pact slot is spent (3 / 4)", s.wait(lambda: "3 / 4 remaining" in page.locator("[data-pact-count]").inner_text()))
        check("HY16 no console errors and only local network traffic", not s.errors and not s.remote, (s.errors[:3], s.remote[:3]))
        s.close()

        m = Sheet(browser, u, width=390, height=844, tab="features")
        m.open(pal)
        m.tab("features")
        m.page.wait_for_timeout(800)
        check("HY17 mobile 390 px: the Paladin class page has no horizontal overflow", m.overflow() <= 0, m.overflow())
        m.page.screenshot(path=str(SHOTS / "class-hybrid-mobile.png"), full_page=True)
        m.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
