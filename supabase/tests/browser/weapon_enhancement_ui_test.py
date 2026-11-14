"""Weapon enhancement (20261114001000, docs/CRAFTING_V1.md "Weapon enhancement"), ONE browser flow. LOCAL ONLY, synthetic users
inside isolation.

WE-01  the DM authors an enhancement in DM Space -> Crafting -> Enhancements (Attack +1, Damage +2)
WE-02  the DM writes and publishes an enhancement recipe: base Longsword (exact item, marked as the base), 2 Rune Dust, Smith's
       tools DC 10
WE-03  the player (a longsword in hand, the dust, the tools) sees the recipe in Inventory -> Crafting: "enhances the base item",
       the base line marked, Craft enabled; the dialog offers the longsword for the base line
WE-04  the player types the roll; the DM confirms the suggested Success
WE-05  the SAME longsword row (same id, still in the hand) carries the enhancement: its inventory card shows the badge with the
       enhancement's name; 2 dust used, the tools kept
WE-06  its weapon card (Play -> combat) lists the enhancement and To hit / Damage include +1 / +2 (the derived stats agree)
Z1/Z2  no console errors; no request left this machine
Usage: APP_URL=... python weapon_enhancement_ui_test.py   (run_browser_local.sh sets the environment)
"""
import json
import re
import uuid
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import ANON, API, APP, PW, RUN, User, call, check, report

q = iso.psql
DUST = f"Rune Dust {RUN}"
RUNE = f"Flame Rune {RUN}"
RECIPE = f"Flame Forging {RUN}"


class WSheet:
    """A signed-in page (the shipped config: CRAFTING = 'on')."""

    def __init__(self, browser, user, tab="inventory"):
        self.ctx = browser.new_context(viewport={"width": 1366, "height": 900})
        self.ctx.add_init_script(f"localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({{url: {json.dumps(API)}, key: {json.dumps(ANON)}}}));"
                                 f"localStorage.setItem('tavern-ledger:tab', {json.dumps(tab)});")
        self.errors, self.remote = [], []
        self.ctx.on("request", lambda r: self.remote.append(r.url) if urlparse(r.url).hostname not in ("127.0.0.1", "localhost") else None)
        self.page = self.ctx.new_page()
        self.page.on("console", lambda m: self.errors.append(m.text) if m.type == "error" else None)
        self.page.on("pageerror", lambda e: self.errors.append(f"pageerror: {e}"))
        p = self.page
        p.goto(APP)
        p.fill("input[name=email]", user.email)
        p.fill("input[name=password]", PW)
        p.click("button[value=signin]")
        p.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)

    def open(self, cid):
        self.page.goto(f"{APP}#/c/{cid}")
        self.wait(lambda: self.page.locator(".tab").count() > 0)
        self.page.wait_for_timeout(800)

    def tab(self, name):
        self.page.locator(f'.tab[data-tab="{name}"]').click()
        self.page.wait_for_timeout(400)

    def wait(self, fn, timeout=15000):
        import time
        t0 = time.time()
        while time.time() - t0 < timeout / 1000:
            try:
                if fn():
                    return True
            except Exception:
                pass
            self.page.wait_for_timeout(200)
        return False

    def close(self):
        self.ctx.close()


def weapon(d, row):
    return next((w for w in (d or {}).get("equipped_weapon_attacks", []) if w.get("inventory_item_id") == row), None)


def run(t):
    dm, pa = User("wedm"), User("wepa")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'WE Forge {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pa.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    cha = pa.character(f"WE Smith {RUN}", [("fighter-phb", 1)])
    q(f"update public.characters set campaign_id = '{camp}', strength = 16 where id = '{cha}';"
      f"insert into public.character_governance (character_id, setup_complete) values ('{cha}', true);")
    assert dm.rpc("set_campaign_governance", p_campaign=camp, p_settings={"overrides": {"inventory.craft": "player_managed"}})[0] == 200
    st, r = dm.rpc("create_homebrew_item", p_request_id=str(uuid.uuid4()), p_definition={"campaign_id": camp, "name": DUST, "kind_id": "gear", "stackable": True}, p_stats={})
    assert st == 200, (st, r)
    dust = r["id"]
    for item, qty in (("longsword", 1), (dust, 3), ("smiths-tools", 1)):
        assert dm.rpc("dm_give_item", p_item=item, p_characters=[cha], p_quantity=qty, p_identified=True)[0] == 200
    ia = q(f"select id from public.inventories where character_id = '{cha}' and kind = 'character'").strip()
    sword = q(f"select id from public.inventory_items where inventory_id = '{ia}' and item_id = 'longsword'").strip()
    assert pa.rpc("equip_item", p_item=sword, p_slot="main_hand", p_replace=True)[0] == 200
    st, d0 = pa.rpc("get_character_derived_stats", p_character=cha)
    w0 = weapon(d0, sword)
    t.note(character=cha, camp=camp, sword=sword)

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        # ---- WE-01: the DM authors the enhancement ---------------------------------------------------------------------------
        D = WSheet(br, dm)
        dp = D.page
        dp.goto(APP + "#/dm/crafting")
        D.wait(lambda: dp.locator('[data-crd="mod-new"]').count() == 1, 20000)
        dp.locator('[data-crd="mod-new"]').click()
        dp.wait_for_selector(".modal [data-m=name]")
        m = dp.locator(".modal")
        m.locator("[data-m=name]").fill(RUNE)
        m.locator("[data-m=description]").fill("The blade glows with runes.")
        m.locator("[data-fx]").nth(1).locator("[data-fx-value]").fill("2")
        m.locator("[data-m-save]").click()
        ok = D.wait(lambda: RUNE in dp.locator("[data-craft-mods]").inner_text())
        mod = q(f"select id from public.item_modifiers where campaign_id = '{camp}' and name = '{RUNE}'").strip()
        fx = q(f"select string_agg(effect_type || ':' || value::int, ',' order by seq) from public.item_modifier_effects where modifier_id = '{mod}'").strip()
        check("WE-01 the DM authors an enhancement (DM Space -> Crafting -> Enhancements): a campaign modifier cm-… with Attack +1, Damage +2",
              ok and re.fullmatch(r"cm-[0-9a-f]{10}", mod or "") is not None and fx == "attack_bonus:1,damage_bonus:2", (mod, fx, D.errors[:3]))

        # ---- WE-02: the enhancement recipe -----------------------------------------------------------------------------------
        dp.locator('[data-crd="new"]').click()
        dp.wait_for_selector(".modal [data-r=name]")
        m = dp.locator(".modal")
        m.locator("[data-r=name]").fill(RECIPE)
        m.locator("[data-r=kind]").select_option("enhancement")
        m.locator("[data-r=enhance_modifier_id]").select_option(mod)
        row1 = m.locator("[data-ing]").nth(0)
        row1.locator("[data-pick-q]").fill("Longsword")
        D.wait(lambda: row1.locator('[data-pick-sel] option[value="longsword"]').count() == 1)
        row1.locator("[data-pick-sel]").select_option("longsword")
        row1.locator("[data-ing-base]").check()
        m.locator("[data-ing-add]").click()
        row2 = m.locator("[data-ing]").nth(1)
        row2.locator("[data-pick-q]").fill(DUST)
        D.wait(lambda: row2.locator(f'[data-pick-sel] option[value="{dust}"]').count() == 1)
        row2.locator("[data-pick-sel]").select_option(dust)
        row2.locator("[data-ing-qty]").fill("2")
        m.locator("[data-r=check_key]").select_option("smiths-tools")
        m.locator("[data-r=check_dc]").fill("10")
        m.locator("[data-r-save][data-publish]").click()
        ok = D.wait(lambda: RECIPE in dp.locator("[data-craft-recipes]").inner_text() and "published" in dp.locator("[data-craft-recipes]").inner_text())
        rid = q(f"select id from public.crafting_recipes where campaign_id = '{camp}' and name = '{RECIPE}'").strip()
        shape = q(f"select r.kind || '|' || coalesce(r.output_item_id, '-') || '|' || r.enhance_modifier_id || '|' || r.status || '|' || "
                  f"(select string_agg(coalesce(g.item_id, g.ingredient_tag) || ':' || g.quantity || ':' || g.consumed || ':' || g.is_base, ',' order by g.seq) "
                  f"from public.crafting_recipe_ingredients g where g.recipe_id = r.id) from public.crafting_recipes r where r.id = '{rid}'").strip() if rid else ""
        check("WE-02 the DM writes and publishes an enhancement recipe: base Longsword (kept, quantity 1), 2 Rune Dust, Smith's tools DC 10",
              ok and shape == f"enhancement|-|{mod}|published|longsword:1:false:true,{dust}:2:true:false",
              (shape, dp.locator("[data-craft-recipes]").inner_text()[:300]))

        # ---- WE-03/04: the player crafts, the DM confirms -------------------------------------------------------------------
        P = WSheet(br, pa)
        pp = P.page
        P.open(cha)
        P.wait(lambda: DUST in pp.locator("#panel-inventory").inner_text(), 15000)
        pp.locator('[data-inv="tab"][data-tab="crafting"]').click()
        ok = P.wait(lambda: pp.locator(f'[data-crafting] [data-recipe="{rid}"]').count() == 1, 20000)
        card = pp.locator(f'[data-recipe="{rid}"]').inner_text() if ok else ""
        craft_btn = pp.locator(f'[data-recipe="{rid}"] [data-cr="craft"]')
        check("WE-03 the player's recipe card: 'enhances the base item' with the enhancement and its effects, the base line marked, Craft enabled",
              ok and "enhances the base item" in card and RUNE in card and "Attack +1" in card and "Damage +2" in card
              and "base item" in card and pp.locator(f'[data-recipe="{rid}"] [data-craft-base]').count() == 1 and craft_btn.is_enabled(),
              card[:300] or P.errors[:3])
        craft_btn.click()
        pp.wait_for_selector(".modal [data-cr-roll]")
        base_opts = pp.locator('.modal [data-cr-ing="1"] option').evaluate_all("os => os.map(o => o.value)")
        pp.locator(".modal [data-cr-roll]").fill("15")
        pp.locator(".modal [data-cr-go]").click()
        ok = P.wait(lambda: q(f"select status from public.crafting_attempts where character_id = '{cha}'").strip() == "pending", 15000)
        dp.goto(APP + "#/dm/overview")
        D.wait(lambda: dp.locator('[data-dm-section="crafting"]').count() == 1)
        dp.locator('[data-dm-section="crafting"]').click()
        D.wait(lambda: dp.locator("[data-craft-queue] [data-attempt]").count() == 1)
        att = dp.locator("[data-craft-queue] [data-attempt]").first
        at = att.inner_text() if att.count() else ""
        att.locator('[data-crd="approve"]').click()
        ok2 = D.wait(lambda: q(f"select status || '|' || outcome from public.crafting_attempts where character_id = '{cha}'").strip() == "applied|success")
        check("WE-04 the dialog offers the longsword for the base line; the roll 15 waits for the DM, who confirms the suggested Success",
              ok and base_opts == [sword] and "Suggested: Success" in at and ok2, (base_opts, at[:200]))

        # ---- WE-05: the same row is enhanced, the inventory card shows it -----------------------------------------------------
        ok = P.wait(lambda: pp.locator(f'[data-modifier="{mod}"]').count() >= 1, 20000)
        if not ok:   # the Crafting tab may be shown: go back to the items
            pp.locator('[data-inv="tab"][data-tab="items"]').click()
            ok = P.wait(lambda: pp.locator(f'[data-modifier="{mod}"]').count() >= 1, 15000)
        badge = pp.locator(f'[data-modifier="{mod}"]').first.inner_text() if ok else ""
        same = q(f"select count(*) from public.inventory_items where inventory_id = '{ia}' and item_id = 'longsword'").strip() == "1" \
            and q(f"select ii.quantity || '|' || coalesce(ce.slot_id, '-') from public.inventory_items ii left join public.character_equipment ce on ce.inventory_item_id = ii.id where ii.id = '{sword}'").strip() == "1|main_hand" \
            and q(f"select count(*) from public.inventory_item_modifiers where inventory_item_id = '{sword}' and modifier_id = '{mod}'").strip() == "1"
        check("WE-05 the SAME longsword row (id, quantity 1, still in the main hand) carries the enhancement; its inventory card shows the badge; 2 dust used, the tools kept",
              ok and badge == RUNE and same
              and q(f"select sum(quantity) from public.inventory_items where inventory_id = '{ia}' and item_id = '{dust}'").strip() == "1"
              and q(f"select count(*) from public.inventory_items where inventory_id = '{ia}' and item_id = 'smiths-tools'").strip() == "1",
              (badge, same, P.errors[:3]))

        # ---- WE-06: the weapon card and the numbers ---------------------------------------------------------------------------
        st, d1 = pa.rpc("get_character_derived_stats", p_character=cha)
        w1 = weapon(d1, sword)
        P.tab("combat")
        wc = pp.locator(".derived-weapon", has_text="Longsword")
        P.wait(lambda: wc.count() == 1 and RUNE in wc.inner_text(), 15000)
        wt = wc.inner_text() if wc.count() else ""
        hit = wc.locator("[data-attack-bonus]").first.inner_text() if wc.count() and wc.locator("[data-attack-bonus]").count() else ""
        check("WE-06 its weapon card lists the enhancement and the numbers include it: To hit +1 and Damage +2 over the plain sword (derived stats agree)",
              w0 and w1 and w1["attack_bonus"] == w0["attack_bonus"] + 1 and "+ 5" in w1["damage"].replace("+5", "+ 5")
              and RUNE in wt and str(w1["attack_bonus"]) in hit,
              (w0 and w0.get("attack_bonus"), w0 and w0.get("damage"), w1 and w1.get("attack_bonus"), w1 and w1.get("damage"), hit, wt[:300]))

        errs = [e for e in D.errors + P.errors if "Failed to load resource" not in e]
        check("Z1 no console errors", not errs, errs[:5])
        check("Z2 no request left this machine", not D.remote and not P.remote)
        D.close(); P.close(); br.close()


if __name__ == "__main__":
    with iso.Isolated("WEAPON-ENHANCEMENT-UI") as t:
        run(t)
    report()
