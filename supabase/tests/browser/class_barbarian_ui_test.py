"""Browser test of the Barbarian (Path of the Berserker) and the active-state engine: Rage on the class page and the Combat
tab (Start spends a use, End stops it, uses shown), Rage benefits in the derived values (greataxe Rage Damage, resistances,
Mindless Rage immunities), Unarmored Defense AC, a rest ends Rage, keyboard, mobile layout, local-only network, no console
errors.
"""
from playwright.sync_api import sync_playwright

from class_ui_common import SHOTS, Sheet, User, call, check, report


def equip(u, cid, item, slot):
    _, inv = call("GET", f"/rest/v1/inventories?character_id=eq.{cid}&kind=eq.character&select=id", token=u.jwt)
    st, ii = u.rpc("add_inventory_item", p_inventory=inv[0]["id"], p_item=item, p_quantity=1)
    assert st == 200, (st, ii)
    st, r = u.rpc("equip_item", p_item=ii, p_slot=slot)
    assert st == 200, (st, r)


def main():
    u = User("barbarian")
    bb = u.character("Barbarian UI Tester", [("barbarian-phb", 6, "barbarian-berserker-phb")], strength=16, dexterity=14, constitution=16)
    equip(u, bb, "greataxe", "main_hand")
    SHOTS.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, u, tab="features")
        page = s.page
        s.open(bb)
        s.tab("combat")
        card = page.locator('[data-cf-glance] [data-cf-state="rage"]')
        check("BU1 At a glance shows Rage: not active, 4 / 4 left, with Start Rage",
              s.wait(lambda: card.count() == 1 and "Not active" in card.inner_text() and "4 / 4 left" in card.inner_text()
                     and card.locator("[data-cf-action=state-start]").count() == 1), card.inner_text() if card.count() else "")
        card.locator("[data-cf-action=state-start]").click()
        check("BU2 Start Rage: Active, 3 / 4 left, the button becomes End Rage",
              s.wait(lambda: "Active" in page.locator('[data-cf-glance] [data-cf-state="rage"]').inner_text()
                     and "3 / 4 left" in page.locator('[data-cf-glance] [data-cf-state="rage"]').inner_text()
                     and page.locator('[data-cf-glance] [data-cf-state="rage"] [data-cf-action=state-end]').count() == 1))
        s.tab("combat")
        combat = page.locator('#combat-states [data-cf-state="rage"]')
        check("BU3 the Combat tab shows the active Rage with End Rage", s.wait(lambda: combat.count() == 1 and "Active" in combat.inner_text()))
        panel = page.locator('[data-panel="combat"]')
        check("BU4 raging: the greataxe deals 1d12 + 5 (Rage Damage +2)", s.wait(lambda: "1d12 + 5" in panel.inner_text()), panel.inner_text()[:600])
        s.tab("stats")
        stats = page.locator("#lineage-stats")
        check("BU5 raging: resistances to bludgeoning, piercing and slashing; immune to charmed and frightened (Mindless Rage)",
              s.wait(lambda: all(x in stats.inner_text() for x in ("Bludgeoning", "Piercing", "Slashing", "Charmed", "Frightened"))),
              stats.inner_text()[:400] if stats.count() else "")
        s.tab("combat")
        page.locator('#combat-states [data-cf-action=state-end]').focus()
        page.keyboard.press("Enter")
        check("BU6 End Rage with the keyboard: not active, greataxe back to 1d12 + 3, the use stays spent (3 / 4)",
              s.wait(lambda: "Not active" in page.locator('#combat-states [data-cf-state="rage"]').inner_text()
                     and "3 / 4 left" in page.locator('#combat-states [data-cf-state="rage"]').inner_text()
                     and "1d12 + 3" in panel.inner_text()))
        s.tab("stats")
        check("BU7 not raging: no slashing resistance; Unarmored Defense AC 15 (10 + DEX 2 + CON 3)",
              s.wait(lambda: "Slashing" not in stats.inner_text()) and page.locator('[data-derived="ac"]').first.inner_text().strip() == "15",
              page.locator('[data-derived="ac"]').first.inner_text())
        u.rpc("start_character_state", p_character=bb, p_state="rage", p_spend=True)
        st, r = u.rpc("short_rest_character", p_character=bb)
        check("BU8 a short rest ends Rage (states_ended)", st == 200 and r.get("states_ended") == ["rage"], (st, r))
        s.open(bb)
        s.tab("features")
        check("BU9 after the rest the page shows Rage not active with 2 / 4 left",
              s.wait(lambda: "Not active" in page.locator('[data-cf-glance] [data-cf-state="rage"]').inner_text()
                     and "2 / 4 left" in page.locator('[data-cf-glance] [data-cf-state="rage"]').inner_text()))
        check("BU10 no console errors and only local network traffic", not s.errors and not s.remote, (s.errors[:3], s.remote[:3]))
        page.screenshot(path=str(SHOTS / "class-barbarian.png"), full_page=True)
        s.close()

        m = Sheet(browser, u, width=390, height=844, tab="combat")
        m.open(bb)
        m.tab("combat")
        m.page.wait_for_timeout(800)
        check("BU11 mobile 390 px: the Combat tab with Rage has no horizontal overflow", m.overflow() <= 0, m.overflow())
        m.page.screenshot(path=str(SHOTS / "class-barbarian-mobile.png"), full_page=True)
        m.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
