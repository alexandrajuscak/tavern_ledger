"""Simple crafting (?v=42, 20261115000100, docs/CRAFTING_V1.md "Simple crafting"), ONE browser smoke. LOCAL ONLY, synthetic users
inside isolation.

CS-01  the DM starts a recipe from the template "Plant extract": the editor is prefilled (tool Herbalism kit, 2 x ingredient with a
       hint), nothing is written before Save; the DM picks the herb and the extract item and publishes (instant, known)
CS-02  the DM starts "Potion of Healing from an extract" (result = the official Potion of Healing), picks the extract, publishes
CS-03  the DM duplicates the extract recipe: a new DRAFT "Copy of ..." with the same tool / ingredients / result, no recipe items
CS-04  the player: Inventory -> Crafting -> 1. tool (Herbalism kit) -> 2. recipe (can make 2) -> quantity 2 -> Craft: 4 herbs used,
       2 extracts made, ONE attempt with batches 2
CS-05  the chain: the potion recipe (can make 2) -> Craft: 1 extract used, 1 Potion of Healing made
CS-06  the DM opens the character's Inventory -> Crafting: the same recipes with have / missing, read-only (no Craft button),
       a link to the recipe editor
CS-07  the player's page never received the DM's recipe note (REST bodies, DOM)
Z1/Z2  no console errors; no request left this machine. Screens: SCREENSHOT_DIR (docs/night/T8_screens).
Usage: APP_URL=... python crafting_simple_ui_test.py   (run_browser_local.sh sets the environment)
"""
import json
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, SHOTS, Sheet, User, check, report

q = iso.psql
HERB = f"Silverleaf {RUN}"
EXTRACT = f"Silverleaf Extract {RUN}"
DMNOTE = f"SENTINEL-T8-{RUN}"


def inv(s):
    return s.page.locator("#panel-inventory").inner_text()


def pick(page, row, key, text, value):
    """type into an item picker of the editor and select the match"""
    box = row.locator(f'[data-pick="{key}"]') if key else row
    box.locator("[data-pick-q]").fill(text)
    ok = False
    for _ in range(60):
        if box.locator(f'[data-pick-sel] option[value="{value}"]').count() == 1:
            ok = True
            break
        page.wait_for_timeout(200)
    box.locator("[data-pick-sel]").select_option(value)
    return ok


def run(t):
    dm, pa = User("csdm"), User("cspa")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'CS Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pa.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    cha = pa.character(f"CS Herbalist {RUN}", [("fighter-phb", 1)])
    q(f"update public.characters set campaign_id = '{camp}' where id = '{cha}';"
      f"insert into public.character_governance (character_id, setup_complete) values ('{cha}', true);")
    assert dm.rpc("set_campaign_governance", p_campaign=camp, p_settings={"overrides": {"inventory.craft": "player_managed"}})[0] == 200

    def hb(defn):
        st, r = dm.rpc("create_homebrew_item", p_request_id=str(uuid.uuid4()), p_definition={"campaign_id": camp, **defn}, p_stats={})
        assert st == 200, (st, r)
        return r["id"]
    herb = hb({"name": HERB, "kind_id": "herbs_plants", "category_id": "plant-flower", "stackable": True})
    extract = hb({"name": EXTRACT, "kind_id": "gear", "stackable": True})
    assert dm.rpc("dm_give_item", p_item=herb, p_characters=[cha], p_quantity=5, p_identified=True)[0] == 200
    assert dm.rpc("dm_give_item", p_item="herbalism-kit", p_characters=[cha], p_quantity=1, p_identified=True)[0] == 200
    t.note(character=cha, camp=camp)
    SHOTS.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        D = Sheet(br, dm, tab="inventory")
        dp = D.page
        dp.goto(APP + "#/dm/crafting")
        D.wait(lambda: dp.locator('[data-crd="new"]').count() == 1, 20000)

        # ---- CS-01 template "Plant extract"
        dp.locator('[data-crd="new"]').click()
        dp.wait_for_selector(".modal [data-r-template]")
        dp.locator(".modal [data-r-template]").select_option("extract")
        D.wait(lambda: dp.locator(".modal [data-r=name]").input_value() == "Plant extract")
        m = dp.locator(".modal")
        before = q(f"select count(*) from public.crafting_recipes where campaign_id = '{camp}'").strip()
        prefill = (m.locator("[data-r=check_key]").input_value(), m.locator("[data-ing]").count(), m.locator("[data-ing-qty]").first.input_value(),
                   m.locator("[data-ing-hint]").count(), m.locator("[data-r=requires_dm_approval]").is_checked(), m.locator("[data-cr-more]").get_attribute("open"))
        dp.screenshot(path=str(SHOTS / "t8_dm_template.png"), full_page=True)
        m.locator("[data-r=name]").fill(f"Extract {RUN}")
        ok1 = pick(dp, m.locator("[data-ing]").first, None, HERB, herb)
        ok2 = pick(dp, m, "output", EXTRACT, extract)
        m.locator("[data-cr-more] > summary").click()
        m.locator("[data-r=dm_notes]").fill(DMNOTE)
        m.locator("[data-r-save][data-publish]").click()
        ok = D.wait(lambda: q(f"select status from public.crafting_recipes where campaign_id = '{camp}' and name = 'Extract {RUN}'").strip() == "published")
        r1 = q(f"select id || '|' || check_key || '|' || requires_dm_approval || '|' || visibility || '|' || coalesce(check_dc::text, '-') || '|' || output_item_id "
               f"from public.crafting_recipes where campaign_id = '{camp}' and name = 'Extract {RUN}'").strip()
        ing1 = q(f"select string_agg(item_id || 'x' || quantity, ',') from public.crafting_recipe_ingredients g join public.crafting_recipes r on r.id = g.recipe_id "
                 f"where r.campaign_id = '{camp}' and r.name = 'Extract {RUN}'").strip()
        rid1 = r1.split("|")[0] if r1 else ""
        check("CS-01 template 'Plant extract' prefills (Herbalism kit, 2 x with a hint, instant, More options closed) and writes nothing until Save; saved: herbalism-kit, instant, known, no DC",
              before == "0" and prefill[0] == "herbalism-kit" and prefill[1] == 1 and prefill[2] == "2" and prefill[3] == 1 and not prefill[4] and prefill[5] is None
              and ok1 and ok2 and ok and r1.endswith(f"|herbalism-kit|false|known|-|{extract}") and ing1 == f"{herb}x2",
              (before, prefill, r1, ing1))

        # ---- CS-02 template "Potion of Healing from an extract"
        D.wait(lambda: dp.locator('[data-crd="new"]').count() == 1)
        dp.locator('[data-crd="new"]').click()
        dp.wait_for_selector(".modal [data-r-template]")
        dp.locator(".modal [data-r-template]").select_option("healing")
        D.wait(lambda: dp.locator(".modal [data-r=name]").input_value() == "Potion of Healing")
        m = dp.locator(".modal")
        out_pre = m.locator('[data-pick="output"] [data-pick-sel]').input_value()
        m.locator("[data-r=name]").fill(f"Healing {RUN}")
        pick(dp, m.locator("[data-ing]").first, None, EXTRACT, extract)
        m.locator("[data-r-save][data-publish]").click()
        ok = D.wait(lambda: q(f"select status || '|' || output_item_id from public.crafting_recipes where campaign_id = '{camp}' and name = 'Healing {RUN}'").strip()
                    == "published|potion-of-healing-common")
        rid2 = q(f"select id from public.crafting_recipes where campaign_id = '{camp}' and name = 'Healing {RUN}'").strip()
        check("CS-02 template 'Potion of Healing' references the official Potion of Healing; published with the extract as ingredient",
              ok and out_pre == "potion-of-healing-common", out_pre)

        # ---- CS-03 duplicate
        D.wait(lambda: dp.locator(f'[data-recipe="{rid1}"] [data-crd="dup"]').count() == 1)
        dp.locator(f'[data-recipe="{rid1}"] [data-crd="dup"]').click()
        dp.wait_for_selector(".modal [data-r=name]")
        m = dp.locator(".modal")
        dup_name = m.locator("[data-r=name]").input_value()
        dp.screenshot(path=str(SHOTS / "t8_dm_duplicate.png"), full_page=True)
        m.locator("[data-r-save]:not([data-publish])").click()
        ok = D.wait(lambda: q(f"select status from public.crafting_recipes where campaign_id = '{camp}' and name = 'Copy of Extract {RUN}'").strip() == "draft")
        dup = q(f"select r.check_key || '|' || r.output_item_id || '|' || r.requires_dm_approval || '|' || coalesce(r.dm_notes, '') || '|' "
                f"|| (select string_agg(item_id || 'x' || quantity, ',') from public.crafting_recipe_ingredients g where g.recipe_id = r.id) || '|' "
                f"|| (select count(*) from public.crafting_recipe_teachers t where t.recipe_id = r.id) "
                f"from public.crafting_recipes r where r.campaign_id = '{camp}' and r.name = 'Copy of Extract {RUN}'").strip()
        check("CS-03 Duplicate opens 'Copy of ...' and saves a new DRAFT with the same tool, result, ingredients and notes, no recipe items",
              dup_name == f"Copy of Extract {RUN}" and ok and dup == f"herbalism-kit|{extract}|false|{DMNOTE}|{herb}x2|0", (dup_name, dup))
        D.wait(lambda: dp.locator("[data-craft-recipes]").count() == 1)
        dp.screenshot(path=str(SHOTS / "t8_dm_recipes.png"), full_page=True)

        # ---- CS-04 / 05 the player
        P = Sheet(br, pa, tab="inventory")
        pp = P.page
        bodies = []
        pp.on("response", lambda r: bodies.append(r.text()) if "/rest/v1/" in r.url else None)
        P.open(cha)
        P.wait(lambda: HERB in inv(P), 15000)
        pp.locator('[data-inv="tab"][data-tab="crafting"]').click()
        ok = P.wait(lambda: pp.locator('[data-craft-tool-choice="herbalism-kit"]').count() == 1, 20000)
        tools = pp.locator('[data-craft-step="tool"]').inner_text() if ok else ""
        pp.locator(f'[data-recipe="{rid1}"] [data-cr="pick"]').click()
        P.wait(lambda: pp.locator(f'[data-recipe="{rid1}"] [data-cr="craft"]').count() == 1)
        maxn = pp.locator(f'[data-recipe="{rid1}"] [data-craft-max]').get_attribute("data-craft-max")
        pp.locator(f'[data-recipe="{rid1}"] [data-cr="qty"][data-d="1"]').click()
        qty = pp.locator(f'[data-recipe="{rid1}"] [data-craft-qty]').inner_text()
        pp.screenshot(path=str(SHOTS / "t8_player_recipe.png"), full_page=True)
        pp.locator(f'[data-recipe="{rid1}"] [data-cr="craft"]').click()
        ok = P.wait(lambda: q(f"select coalesce(sum(ii.quantity), 0) from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id "
                              f"where i.character_id = '{cha}' and ii.item_id = '{extract}'").strip() == "2", 15000)
        att = q(f"select count(*) || '|' || max(batches) || '|' || max(status) from public.crafting_attempts where character_id = '{cha}'").strip()
        herbs = q(f"select coalesce(sum(ii.quantity), 0) from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id where i.character_id = '{cha}' and ii.item_id = '{herb}'").strip()
        check("CS-04 tool -> recipe (can make 2) -> quantity 2 -> Craft: 4 herbs used, 2 extracts made, ONE attempt with batches 2, applied",
              "Herbalism" in tools and maxn == "2" and qty == "2" and ok and herbs == "1" and att == "1|2|applied", (tools[:120], maxn, qty, att, herbs, P.errors[:3]))
        P.wait(lambda: EXTRACT in inv(P) or pp.locator(f'[data-recipe="{rid2}"]').count() == 1, 8000)
        P.wait(lambda: pp.locator(f'[data-recipe="{rid2}"] [data-craft-max="2"]').count() == 1, 15000)
        pp.locator(f'[data-recipe="{rid2}"] [data-cr="pick"]').click()
        P.wait(lambda: pp.locator(f'[data-recipe="{rid2}"] [data-cr="craft"]').count() == 1)
        pp.locator(f'[data-recipe="{rid2}"] [data-cr="craft"]').click()
        ok = P.wait(lambda: q(f"select coalesce(sum(ii.quantity), 0) from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id "
                              f"where i.character_id = '{cha}' and ii.item_id = 'potion-of-healing-common'").strip() == "1", 15000)
        P.wait(lambda: pp.locator(f'[data-recipe="{rid2}"] [data-craft-max="1"]').count() == 1, 10000)
        pp.screenshot(path=str(SHOTS / "t8_player_after.png"), full_page=True)
        check("CS-05 the chain: the potion recipe uses 1 extract and makes 1 Potion of Healing (the inventory follows)",
              ok and q(f"select coalesce(sum(ii.quantity), 0) from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id "
                       f"where i.character_id = '{cha}' and ii.item_id = '{extract}'").strip() == "1")

        # ---- CS-06 the DM views the character's crafting
        D.open(cha)
        D.wait(lambda: dp.locator('[data-inv="tab"][data-tab="crafting"]').count() == 1, 20000)
        dp.locator('[data-inv="tab"][data-tab="crafting"]').click()
        ok = D.wait(lambda: dp.locator("[data-craft-dmview]").count() == 1 and dp.locator(f'[data-recipe="{rid1}"]').count() == 1, 20000)
        if ok:
            dp.locator(f'[data-recipe="{rid1}"] [data-cr="pick"]').click()
            dp.wait_for_timeout(400)
        dp.screenshot(path=str(SHOTS / "t8_dm_character_view.png"), full_page=True)
        card = dp.locator(f'[data-recipe="{rid1}"]').inner_text() if ok else ""
        check("CS-06 the DM sees the character's Crafting read-only (have / need, no Craft button) with a link to the recipe editor",
              ok and "1 / 2" in card and dp.locator("[data-crafting] [data-cr='craft']").count() == 0
              and dp.locator("[data-craft-editor]").get_attribute("href") == "#/dm/crafting", card[:200])

        pp.wait_for_timeout(800)
        check("CS-07 the player's page never received the DM's recipe note (REST bodies, DOM)",
              not any(DMNOTE in b for b in bodies) and DMNOTE not in pp.content())
        errs = [e for e in D.errors + P.errors if "Failed to load resource" not in e]
        check("Z1 no console errors", not errs, errs[:5])
        check("Z2 no request left this machine", not D.remote and not P.remote, (D.remote + P.remote)[:3])
        D.ctx.close(); P.ctx.close(); br.close()


if __name__ == "__main__":
    with iso.Isolated("CRAFTING-SIMPLE-UI") as t:
        run(t)
    report()
