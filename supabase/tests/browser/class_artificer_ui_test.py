"""Browser test of the Artificer (Alchemist) and the infusion engine: infusions chosen on the class page, the Infused items card,
the Infuse dialog (qualifying items, refusals with reasons), Enhanced Weapon on an equipped weapon in the Combat tab,
Homunculus Servant as a companion, ending an infusion, the infused item limit, mobile layout, local-only network, no console
errors.
"""
from playwright.sync_api import sync_playwright

from class_ui_common import SHOTS, Sheet, User, call, check, report


def main():
    u = User("artificer")
    ar = u.character("Artificer UI Tester", [("artificer-tce", 3, "artificer-alchemist-tce")], intelligence=16, dexterity=14, constitution=14)
    _, rows = call("GET", f"/rest/v1/character_classes?character_id=eq.{ar}&select=id", token=u.jwt)
    row = rows[0]["id"]
    st, r = u.rpc("set_character_feature_choice", p_character=ar, p_character_class=row, p_unlock="artificer-tce-u2-infuse-item",
                  p_choice="artificer-infuse-item-tce-infusions", p_values=["enhanced-weapon", "enhanced-defense", "homunculus-servant", "returning-weapon"],
                  p_manual_status=None)
    assert st == 200, (st, r)
    _, inv = call("GET", f"/rest/v1/inventories?character_id=eq.{ar}&kind=eq.character&select=id", token=u.jwt)
    for item in ("mace", "shortbow", "leather"):
        u.rpc("add_inventory_item", p_inventory=inv[0]["id"], p_item=item, p_quantity=1)
    _, mace = call("GET", f"/rest/v1/inventory_items?inventory_id=eq.{inv[0]['id']}&item_id=eq.mace&select=id", token=u.jwt)
    u.rpc("equip_item", p_item=mace[0]["id"], p_slot="main_hand")
    SHOTS.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, u, tab="features")
        page = s.page
        s.open(ar)
        s.tab("features")
        card = page.locator("[data-infusions]")
        check("AU1 Infused items card: 0 / 2 items, 4 infusions known, Infuse an item",
              s.wait(lambda: card.count() == 1 and "0 / 2 items" in card.text_content() and "4 infusions known" in card.text_content()),
              card.inner_text() if card.count() else "")
        s.tab("combat")
        panel = page.locator('[data-panel="combat"]')
        check("AU2 before infusing, the equipped mace deals 1d6 bludgeoning without a bonus",
              s.wait(lambda: "1d6" in panel.inner_text()) and "1d6 + 1" not in panel.inner_text(), panel.inner_text()[:300])
        s.tab("features")
        card.locator("[data-action=inf-add]").click()
        page.wait_for_selector(".modal [data-inf-form]")
        page.select_option(".modal select[name=infusion]", "returning-weapon")
        tgt = page.locator(".modal [data-inf-target]")
        check("AU3 Returning Weapon: no item qualifies (thrown weapons only); the refusals explain why",
              s.wait(lambda: "No item in your inventory can take this infusion" in tgt.inner_text()) and page.locator(".modal [data-inf-ok]").is_disabled())
        page.select_option(".modal select[name=infusion]", "enhanced-weapon")
        check("AU4 Enhanced Weapon offers the mace and the shortbow, not the leather armor",
              s.wait(lambda: "Mace" in tgt.locator("select[name=target]").inner_text()) and "Leather" not in tgt.locator("select[name=target]").inner_text())
        tgt.locator("select[name=target]").select_option(label="Mace")
        page.click(".modal [data-inf-ok]")
        check("AU5 the mace holds Enhanced Weapon (1 / 2 items)",
              s.wait(lambda: "1 / 2 items" in page.locator("[data-infusions]").text_content() and "in Mace" in page.locator("[data-infusions]").text_content()),
              (s.toasts(), page.locator("[data-infusions]").text_content()[:300]))
        s.tab("combat")
        check("AU6 the Combat tab shows the mace with +1 damage (1d6 + 1)", s.wait(lambda: "1d6 + 1" in panel.inner_text()), panel.inner_text()[:400])
        s.tab("features")
        page.locator("[data-infusions] [data-action=inf-add]").click()
        page.wait_for_selector(".modal [data-inf-form]")
        page.select_option(".modal select[name=infusion]", "homunculus-servant")
        page.click(".modal [data-inf-ok]")
        check("AU7 Homunculus Servant: a companion with 1 + 3 + 3 = 7 HP; the card says 2 / 2 and Infuse is disabled",
              s.wait(lambda: "Homunculus Servant" in page.locator("#companions-body").inner_text() and "7 / 7" in page.locator("#companions-body").inner_text())
              and s.wait(lambda: page.locator("[data-infusions] [data-action=inf-add]").is_disabled()))
        page.locator("[data-infusions] [data-infused]").first.locator("[data-action=inf-remove]").click()
        page.locator(".modal .btn-bad, .modal [data-ok]").last.click()
        check("AU8 ending Enhanced Weapon: 1 / 2 items; the mace is back to 1d6",
              s.wait(lambda: "1 / 2 items" in page.locator("[data-infusions]").text_content()))
        check("AU9 no console errors and only local network traffic", not s.errors and not s.remote, (s.errors[:3], s.remote[:3]))
        page.screenshot(path=str(SHOTS / "class-artificer.png"), full_page=True)
        s.close()

        m = Sheet(browser, u, width=390, height=844, tab="features")
        m.open(ar)
        m.tab("features")
        m.page.wait_for_timeout(800)
        check("AU10 mobile 390 px: the Artificer page with infusions has no horizontal overflow", m.overflow() <= 0, m.overflow())
        m.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
