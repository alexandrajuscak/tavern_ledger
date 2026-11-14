"""Weapon blocks (20261114000600, docs/ITEM_EFFECTS.md "Weapon blocks"). LOCAL ONLY, synthetic users.

The DM authors a weapon in DM Space -> Content -> New item (Weapon actions: Lacerate, 1 per short rest, CON save; Special;
Condition: Bleeding), publishes it and assigns it (identified) to the player's character. The player equips it in the
Inventory and sees the three blocks on the weapon card in Play; Use spends the one use without a reload (1 / 1 -> 0 / 1),
Restore gives it back. An unidentified copy of the same weapon equipped by another character of the player shows none of it.
Usage: APP_URL=... python weapon_blocks_ui_test.py   (run_browser_local.sh sets the environment)
"""
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, SHOTS, Sheet, User, check, report

q = iso.psql
BLADE = f"Gravecutter {RUN}"
DISGUISE = f"Notched blade {RUN}"


def wait_idle(page):
    page.wait_for_timeout(300)
    page.wait_for_function("!document.querySelector('#inventory-app [aria-busy=true]')", timeout=15000)
    page.wait_for_timeout(500)


def run():
    dm, pl = User("wbdm"), User("wbpl")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'Blades Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    hero = pl.character(f"Blade Bearer {RUN}", [("fighter-phb", 5)], strength=16)
    other = pl.character(f"Blade Finder {RUN}", [("fighter-phb", 3)], strength=14)
    for c in (hero, other):
        q(f"update public.characters set campaign_id = '{camp}' where id = '{c}';"
          f"insert into public.character_governance (character_id, setup_complete) values ('{c}', true);")

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        # ---- 1. the DM authors the weapon ----------------------------------------------------------------------------------------
        D = Sheet(br, dm, tab="combat")
        d = D.page
        d.goto(APP + "#/dm/content")
        D.wait(lambda: d.locator('[data-dm="new-content"][data-type="item"]').count() > 0, 20000)
        d.locator('[data-dm="new-content"][data-type="item"]').click()
        d.wait_for_selector(".modal [data-ce-form]")
        m = d.locator(".modal").last
        m.locator("[name=name]").fill(BLADE)
        m.locator('[name="definition.item.kind_id"]').select_option("weapon")
        m.locator('[name="definition.item.category_id"]').fill("martial-melee")
        m.locator('[name="definition.item.rarity_id"]').select_option("rare")
        m.locator('[name="definition.item.is_magic"]').check()
        m.locator('[name="definition.stats.weapon.weapon_group"]').select_option("martial")
        m.locator('[name="definition.stats.weapon.damage_dice"]').fill("1d8")
        m.locator('[name="definition.stats.weapon.damage_type_id"]').select_option("slashing")
        sections_shown = m.locator('[data-ce-section="weapon_actions"]').is_visible()
        m.locator('[data-rows="definition.item.weapon_actions"] [data-add-row]').click()
        m.locator('[name="definition.item.weapon_actions.0.name"]').fill("Lacerate")
        m.locator('[name="definition.item.weapon_actions.0.description"]').fill("A deep cut that makes the target bleed.")
        m.locator('[name="definition.item.weapon_actions.0.cost"]').select_option("action")
        m.locator('[name="definition.item.weapon_actions.0.roll"]').select_option("save")
        m.locator('[name="definition.item.weapon_actions.0.save_ability"]').select_option("con")
        m.locator('[name="definition.item.weapon_actions.0.damage"]').fill("1d6")
        m.locator('[name="definition.item.weapon_actions.0.damage_type"]').select_option("slashing")
        m.locator('[name="definition.item.weapon_actions.0.uses"]').fill("1")
        m.locator('[name="definition.item.weapon_actions.0.recharge"]').select_option("short_rest")
        m.locator('[data-rows="definition.item.weapon_special"] [data-add-row]').click()
        m.locator('[name="definition.item.weapon_special.0.name"]').fill("Grim Promise")
        m.locator('[name="definition.item.weapon_special.0.text"]').fill("After a miss, your next attack on that target has advantage.")
        m.locator('[data-rows="definition.item.weapon_conditions"] [data-add-row]').click()
        m.locator('[name="definition.item.weapon_conditions.0.condition"]').fill("Bleeding")
        m.locator('[name="definition.item.weapon_conditions.0.applies_on"]').select_option("action")
        m.locator('[name="definition.item.weapon_conditions.0.save_ability"]').select_option("con")
        m.locator('[name="definition.item.weapon_conditions.0.duration"]').fill("2 turns")
        m.locator('[name="definition.hidden.unidentified_name"]').fill(DISGUISE)
        d.locator('.modal [data-ce-act="validate"]').click()
        ok_val = D.wait(lambda: "Ready to publish" in d.locator(".modal .ce-status").first.inner_text(), 15000)
        d.locator('.modal [data-ce-act="publish"]').click()
        d.locator(".modal [data-ok]").last.click()
        ok_pub = D.wait(lambda: "Published" in d.locator(".modal .ce-status").first.inner_text(), 15000)
        ref = q(f"select v.catalog_ref from public.dm_content c join public.dm_content_versions v on v.id = c.published_version_id where c.name = '{BLADE}'").strip()
        rows = q(f"select string_agg(block_type || '/' || name || '/' || coalesce(uses::text, '-') || '/' || coalesce(recharge, '-'), ',' order by block_type) "
                 f"from public.item_weapon_blocks where item_id = '{ref}'").strip()
        check("WU1 DM Space: the weapon sections show for a weapon; the DM authors an action (1/short rest), a Special and a Condition, validates, publishes",
              sections_shown and ok_val and ok_pub and rows == "action/Lacerate/1/short_rest,condition/Bleeding/-/-,special/Grim Promise/-/-", (sections_shown, ok_val, ok_pub, rows))
        d.keyboard.press("Escape")
        cid = q(f"select id from public.dm_content where name = '{BLADE}'").strip()
        d.locator('[data-dm-section="assign"]').click()
        D.wait(lambda: d.locator("[data-as-content]").count() > 0)
        d.select_option("[data-as-content]", cid)
        d.locator(f'[data-as-char][value="{hero}"]').check()
        d.locator("[data-as-go]").click()
        ok_as = D.wait(lambda: "done" in d.locator("[data-as-result]").inner_text(), 15000)
        check("WU2 the DM gives it (identified) to the player's character", ok_as)
        # an UNIDENTIFIED copy for the player's other character (DM call), equipped in the main hand (player call)
        q(f"begin; select set_config('request.jwt.claim.sub', '{dm.id}', true), set_config('role', 'authenticated', true);"
          f"select public.dm_give_item('{ref}', array['{other}']::uuid[], 1, false); commit;")
        urow = q(f"select ii.id from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id where i.character_id = '{other}' and ii.item_id = '{ref}'").strip()
        q(f"begin; select set_config('request.jwt.claim.sub', '{pl.id}', true), set_config('role', 'authenticated', true);"
          f"select public.equip_item('{urow}', 'main_hand', true); commit;")

        # ---- 2. the player equips it and sees the blocks ---------------------------------------------------------------------------
        P = Sheet(br, pl, tab="inventory")
        pp = P.page
        P.open(hero)
        P.tab("inventory")
        P.wait(lambda: pp.locator(".inv-item", has_text=BLADE).count() > 0, 15000)
        pp.locator(".inv-item", has_text=BLADE).first.locator(".inv-item-main").click()
        pp.locator(".modal [data-x=equip]").click()
        if pp.locator(".modal [data-slot=main_hand]").count():
            pp.locator(".modal [data-slot=main_hand]").click()
        wait_idle(pp)
        P.tab("combat")
        card = pp.locator(".wpn-card", has_text=BLADE)
        ok_card = P.wait(lambda: card.count() == 1 and card.locator("[data-wpn-uses]").count() == 1, 20000)
        txt = card.first.inner_text() if card.count() else ""
        check("WU3 Play: the weapon card shows Weapon actions (Lacerate, DC 14 CON save, 1d6 slashing, 1 / 1), Special and Condition (Bleeding, 2 turns)",
              ok_card and "Lacerate" in txt and "DC 14" in txt and "1 / 1" in txt and "Grim Promise" in txt and "Bleeding" in txt and "2 turns" in txt, txt[:500])
        pp.screenshot(path=str(SHOTS / "weapon_blocks_card.png"), full_page=False)
        nav = pp.evaluate("performance.getEntriesByType('navigation').length + ':' + location.href")
        card.first.locator('[data-wpn-uses] [data-cf-action="res-use"]').click()
        ok_use = P.wait(lambda: "0 / 1" in pp.locator(".wpn-card", has_text=BLADE).first.locator("[data-wpn-uses]").inner_text(), 15000)
        used = q(f"select expended from public.character_resources where character_id = '{hero}' and resource_key like 'itemw-%'").strip()
        same_page = pp.evaluate("performance.getEntriesByType('navigation').length + ':' + location.href") == nav
        check("WU4 Use spends the one use once (0 / 1, expended = 1) without a reload", ok_use and used == "1" and same_page, (ok_use, used, same_page))
        pp.locator(".wpn-card", has_text=BLADE).first.locator('[data-wpn-uses] [data-cf-action="res-restore"]').click()
        ok_rest = P.wait(lambda: "1 / 1" in pp.locator(".wpn-card", has_text=BLADE).first.locator("[data-wpn-uses]").inner_text(), 15000)
        check("WU5 Restore gives it back (1 / 1)", ok_rest)

        # ---- 3. the unidentified copy shows nothing --------------------------------------------------------------------------------
        P.open(other)
        P.tab("combat")
        P.wait(lambda: pp.locator("#equipped-weapons .wpn-card").count() > 0, 20000)
        pp.wait_for_timeout(1500)
        body = pp.locator("#equipped-weapons").inner_text()
        # the whole document except the toast area (a toast of the Restore on the other character may still be fading out)
        page_html = pp.evaluate("(() => { const c = document.documentElement.cloneNode(true); c.querySelector('#toasts')?.remove(); return c.outerHTML; })()")
        check("WU6 an unidentified copy: the card has no blocks, and neither 'Lacerate', 'Grim Promise' nor 'Bleeding' is anywhere on the page",
              pp.locator("#equipped-weapons [data-wpn-block]").count() == 0 and "Lacerate" not in page_html and "Grim Promise" not in page_html
              and "Bleeding" not in page_html and BLADE not in page_html,
              [w for w in ("Lacerate", "Grim Promise", "Bleeding", BLADE) if w in page_html] + [body[:200]])
        # legacy read path
        pp.goto(f"{APP}?fluent=0#/c/{hero}")
        P.wait(lambda: pp.locator(".tab").count() > 0)
        P.tab("combat")
        ok_leg = P.wait(lambda: pp.locator(".wpn-card", has_text=BLADE).locator("[data-wpn-block]").count() == 3, 20000)
        check("WU7 ?fluent=0 shows the same three blocks", ok_leg)
        errs = [e for e in P.errors + D.errors if "favicon" not in e]
        check("WU8 no console errors (DM and player)", not errs, errs[:5])
        br.close()
    report()


if __name__ == "__main__":
    run()
