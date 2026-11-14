"""Item effects (20261114000500, docs/ITEM_EFFECTS.md). LOCAL ONLY, synthetic users.

The DM authors an amulet in DM Space -> Content -> New item (Effects: +2 Initiative and +3 Religion while attuned; Granted
spells: Speak with Dead once per long rest while attuned), publishes it and assigns it (identified) to the player's character.
The player attunes it in the Inventory and sees the bonuses in the stats (Initiative, Religion) and the spell in the Spells
tab with its counter ("1 of 1 left"); Use spends it. Ending the attunement removes the bonuses and the spell.
Usage: APP_URL=... python item_effects_ui_test.py   (run_browser_local.sh sets the environment)
"""
import re
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, SHOTS, Sheet, User, check, report

q = iso.psql
AMULET = f"Amulet of the Grave {RUN}"


def wait_idle(page):
    page.wait_for_timeout(300)
    page.wait_for_function("!document.querySelector('#inventory-app [aria-busy=true]')", timeout=15000)
    page.wait_for_timeout(500)


def num(text):
    m = re.search(r"([+−-])\s*(\d+)", text or "")
    return None if not m else (int(m.group(2)) * (-1 if m.group(1) in "-−" else 1))


def run():
    dm, pl = User("iedm"), User("iepl")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'Effects Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    hero = pl.character(f"Grave Seeker {RUN}", [("cleric-phb", 5)], wisdom=16)
    q(f"update public.characters set campaign_id = '{camp}' where id = '{hero}';"
      f"insert into public.character_governance (character_id, setup_complete) values ('{hero}', true);")

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        # ---- 1. the DM authors the amulet in DM Space ----------------------------------------------------------------------------
        D = Sheet(br, dm, tab="combat")
        d = D.page
        d.goto(APP + "#/dm/content")
        D.wait(lambda: d.locator('[data-dm="new-content"][data-type="item"]').count() > 0, 20000)
        d.locator('[data-dm="new-content"][data-type="item"]').click()
        d.wait_for_selector(".modal [data-ce-form]")
        m = d.locator(".modal").last
        m.locator("[name=name]").fill(AMULET)
        m.locator('[name="definition.item.kind_id"]').select_option("magic_item")
        m.locator('[name="definition.item.category_id"]').fill("wondrous-item")
        m.locator('[name="definition.item.rarity_id"]').select_option("uncommon")
        m.locator('[name="definition.item.is_magic"]').check()
        m.locator('[name="definition.item.requires_attunement"]').check()
        fx = m.locator('[data-rows="definition.item.effects"]')
        fx.locator("[data-add-row]").click()
        fx.locator("[data-add-row]").click()
        m.locator('[name="definition.item.effects.0.type"]').select_option("initiative_bonus")
        m.locator('[name="definition.item.effects.0.value"]').fill("2")
        m.locator('[name="definition.item.effects.0.activation"]').select_option("attuned")
        m.locator('[name="definition.item.effects.1.type"]').select_option("skill_bonus")
        m.locator('[name="definition.item.effects.1.target"]').select_option("religion")
        m.locator('[name="definition.item.effects.1.value"]').fill("3")
        sp = m.locator('[data-rows="definition.item.spells"]')
        sp.locator("[data-add-row]").click()
        m.locator('[name="definition.item.spells.0.spell"]').fill("speak-with-dead-phb")
        m.locator('[name="definition.item.spells.0.casting"]').select_option("per_rest")
        m.locator('[name="definition.item.spells.0.uses"]').fill("1")
        m.locator('[name="definition.item.spells.0.recharge"]').select_option("long_rest")
        m.locator('[name="definition.item.spells.0.activation"]').select_option("attuned")
        m.locator('[name="definition.item.spells.0.ability"]').select_option("wis")
        d.locator('.modal [data-ce-act="validate"]').click()
        ok_val = D.wait(lambda: "Ready to publish" in d.locator(".modal .ce-status").first.inner_text(), 15000)
        d.locator('.modal [data-ce-act="publish"]').click()
        d.locator(".modal [data-ok]").last.click()
        ok_pub = D.wait(lambda: "Published" in d.locator(".modal .ce-status").first.inner_text(), 15000)
        ref = q(f"select v.catalog_ref from public.dm_content c join public.dm_content_versions v on v.id = c.published_version_id where c.name = '{AMULET}'").strip()
        rows = q(f"select (select count(*) from public.item_effects where item_id = '{ref}') || ':' || "
                 f"(select string_agg(spell_version_id || '/' || casting || '/' || uses || '/' || recharge || '/' || activation, ',') from public.item_spell_grants where item_id = '{ref}')").strip()
        check("IU1 DM Space: the DM authors an amulet (2 effects, Speak with Dead 1/long rest while attuned), validates and publishes it",
              ok_val and ok_pub and rows == "2:speak-with-dead-phb/per_rest/1/long_rest/attuned", (ok_val, ok_pub, ref, rows))
        d.keyboard.press("Escape")
        # ---- 2. the DM assigns it (identified) through DM Space -> Assign --------------------------------------------------------
        cid = q(f"select id from public.dm_content where name = '{AMULET}'").strip()
        d.locator('[data-dm-section="assign"]').click()
        D.wait(lambda: d.locator("[data-as-content]").count() > 0)
        d.select_option("[data-as-content]", cid)
        d.locator(f'[data-as-char][value="{hero}"]').check()
        d.locator("[data-as-go]").click()
        ok_as = D.wait(lambda: "done" in d.locator("[data-as-result]").inner_text(), 15000)
        check("IU2 the DM gives it to the player's character", ok_as and q(f"select count(*) from public.inventory_items where item_id = '{ref}'").strip() == "1")

        # ---- 3. the player: carried (no bonus), attuned (bonus + spell with counter) --------------------------------------------
        P = Sheet(br, pl, tab="stats")
        pp = P.page
        P.open(hero)
        P.wait(lambda: pp.locator('[data-derive="skill:religion"]').count() > 0 and pp.locator('[data-derive="skill:religion"]').first.inner_text().strip() != "")
        init0 = num(pp.locator('[data-derive="init"]').first.inner_text())
        rel0 = num(pp.locator('[data-derive="skill:religion"]').first.inner_text())
        P.tab("inventory")
        P.wait(lambda: pp.locator(".inv-item", has_text=AMULET).count() > 0, 15000)
        pp.locator(".inv-item", has_text=AMULET).first.locator(".inv-item-main").click()
        pp.locator(".modal [data-x=attune]").click()
        wait_idle(pp)
        P.tab("stats")
        ok_b = P.wait(lambda: num(pp.locator('[data-derive="skill:religion"]').first.inner_text()) == rel0 + 3, 15000)
        init1 = num(pp.locator('[data-derive="init"]').first.inner_text())
        title = pp.locator('[data-derive="skill:religion"]').first.get_attribute("title") or ""
        check("IU3 attuned: +3 Religion and +2 Initiative on the sheet, the Religion tooltip names the amulet",
              ok_b and init1 == init0 + 2 and AMULET in title, (rel0, init0, init1, title))
        P.tab("spells")
        card = pp.locator('.sp-card[data-spell="speak-with-dead-phb"]')
        ok_sp = P.wait(lambda: card.count() == 1 and "1 of 1 left" in card.first.inner_text(), 15000)
        check("IU4 the Spells tab shows Speak with Dead from the amulet with its counter (1 of 1 left per long rest)",
              ok_sp and AMULET in card.first.inner_text() and "long rest" in card.first.inner_text(), card.first.inner_text()[:300] if card.count() else "")
        card.first.locator('[data-action="item-spell-use"]').click()
        ok_use = P.wait(lambda: "0 of 1 left" in pp.locator('.sp-card[data-spell="speak-with-dead-phb"]').first.inner_text(), 15000)
        check("IU5 Use spends the free cast (0 of 1 left)", ok_use)
        pp.screenshot(path=str(SHOTS / "item_effects_spells.png"), full_page=False)

        # ---- 4. ending the attunement removes them -------------------------------------------------------------------------------
        P.tab("inventory")
        pp.locator(".inv-item", has_text=AMULET).first.locator(".inv-item-main").click()
        pp.locator(".modal [data-x=unattune]").click()
        wait_idle(pp)
        P.tab("stats")
        ok_off = P.wait(lambda: num(pp.locator('[data-derive="skill:religion"]').first.inner_text()) == rel0, 15000)
        init2 = num(pp.locator('[data-derive="init"]').first.inner_text())
        title2 = pp.locator('[data-derive="skill:religion"]').first.get_attribute("title") or ""
        P.tab("spells")
        gone = P.wait(lambda: pp.locator('.sp-card[data-spell="speak-with-dead-phb"]').count() == 0, 15000)
        check("IU6 attunement ended: the bonuses are gone (listed as not counted) and so is the spell",
              ok_off and init2 == init0 and "not attuned" in title2 and gone, (init2, title2, gone))
        errs = [e for e in P.errors + D.errors if "favicon" not in e]
        check("IU7 no console errors (DM and player)", not errs, errs[:5])
        br.close()
    report()


if __name__ == "__main__":
    run()
