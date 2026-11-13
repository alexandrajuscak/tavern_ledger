"""Crafting v1 (20261113000100, docs/CRAFTING_V1.md), browser suite. LOCAL ONLY, synthetic users inside isolation.

CF-01..03  shipped config (js/config.js CRAFTING = 'off'): DM Space has no Crafting tab and Campaign rules no Crafting row; the
           player's Inventory has no Crafting panel; js/crafting.js and no crafting RPC is ever requested.
CF-04..12  CRAFTING = 'on' (js/config.js served with the flag switched for these contexts only, as in auth_reset_ui_test.py), the
           campaign rule turned on: the DM creates and publishes a recipe with a DC and a DM note in DM Space -> Crafting; the player
           sees it in Inventory -> Crafting with what they have, crafts with a typed roll (pending); the DM sees the DC and the
           roll, approves with an edited roll, a reply and a private note; the player's open Inventory changes live (ingredient
           used, result added, status Done, the DM's reply).
CF-13..16  REQUIRED leak check on the player's page: no REST / RPC body, no websocket frame, no DOM text and no local /
           sessionStorage value carries the DC, the DM's recipe note, the DM's private note or the true name of a secret
           ingredient (a second recipe names it exactly; the player holds a disguised copy). The player's token cannot read
           the crafting tables (REST).
Usage: APP_URL=... python crafting_ui_test.py   (run_browser_local.sh sets the environment)
"""
import json
import re
import uuid
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import ANON, API, APP, PW, RUN, Sheet, User, call, check, report

q = iso.psql
ROOT = Path(__file__).resolve().parents[3]
CONFIG = (ROOT / "js" / "config.js").read_text(encoding="utf-8")
FLAG_OFF = "export const CRAFTING = 'off';"
assert FLAG_OFF in CONFIG, "flag line not found in js/config.js"
CONFIG_ON = CONFIG.replace(FLAG_OFF, "export const CRAFTING = 'on';")
SECRET = f"Starmoss {RUN}"
DMNOTE = f"SENTINEL-DMNOTE-{RUN}"
PRIVATE = f"SENTINEL-PRIVATE-{RUN}"
REPLY = f"Nicely brewed {RUN}"
LEAF = f"Moonleaf {RUN}"
DRAUGHT = f"Healing Draught {RUN}"
RECIPE = f"Star Tea {RUN}"
DC_RE = re.compile(r'"(check_)?dc"\s*:|DC 37')


class CSheet(Sheet):
    """A Sheet whose context serves js/config.js with CRAFTING = 'on' (installed before the first page load)."""

    def __init__(self, browser, user, tab="inventory", flag_on=True):
        self.ctx = browser.new_context(viewport={"width": 1366, "height": 900})
        if flag_on:
            self.ctx.route(re.compile(r".*/js/config\.js(\?.*)?$"), lambda r: r.fulfill(status=200, content_type="text/javascript", body=CONFIG_ON))
        self.ctx.add_init_script(f"localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({{url: {json.dumps(API)}, key: {json.dumps(ANON)}}}));"
                                 f"localStorage.setItem('tavern-ledger:tab', {json.dumps(tab)});")
        self.errors, self.remote, self.urls = [], [], []
        self.ctx.on("request", lambda r: (self.urls.append(r.url), self.remote.append(r.url) if urlparse(r.url).hostname not in ("127.0.0.1", "localhost") else None))
        self.page = self.ctx.new_page()
        self.page.on("console", lambda m: self.errors.append(m.text) if m.type == "error" else None)
        self.page.on("pageerror", lambda e: self.errors.append(f"pageerror: {e}"))
        p = self.page
        p.goto(APP)
        p.fill("input[name=email]", user.email)
        p.fill("input[name=password]", PW)
        p.click("button[value=signin]")
        p.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)


def storage(page):
    return page.evaluate("""() => { const out = [];
        for (const s of [localStorage, sessionStorage]) for (let i = 0; i < s.length; i++) { const k = s.key(i); out.push(k + '=' + s.getItem(k)); }
        return out; }""")


def leaks(texts):
    bad = []
    for t in texts:
        if any(s in t for s in (SECRET, DMNOTE, PRIVATE)) or DC_RE.search(t):
            bad.append(t[:200])
    return bad


def inv_text(s):
    return s.page.locator("#panel-inventory").inner_text()


def crafting_requests(urls):
    return [u for u in urls if "crafting.js" in u or re.search(r"/rpc/[a-z_]*(craft|recipe)", u)]


def run(t):
    dm, pa = User("cfdm"), User("cfpa")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'CF Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pa.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    cha = pa.character(f"CF Alchemist {RUN}", [("fighter-phb", 1)])
    q(f"update public.characters set campaign_id = '{camp}' where id = '{cha}';"
      f"insert into public.character_governance (character_id, setup_complete) values ('{cha}', true);")

    def hb(defn):
        st, r = dm.rpc("create_homebrew_item", p_request_id=str(uuid.uuid4()), p_definition={"campaign_id": camp, **defn}, p_stats={})
        assert st == 200, (st, r)
        return r["id"]
    leaf = hb({"name": LEAF, "kind_id": "herbs_plants", "category_id": "plant-flower", "stackable": True, "details": {"ingredient_tags": ["silver"]}})
    moss = hb({"name": SECRET, "kind_id": "herbs_plants", "category_id": "plant-flower", "stackable": True, "description": f"{SECRET} truth."})
    draught = hb({"name": DRAUGHT, "kind_id": "gear", "stackable": True})
    assert dm.rpc("set_item_identify_options", p_item=moss, p_options={"unidentified_name": "Grey fluff", "show_kind": True})[0] == 200
    assert dm.rpc("dm_give_item", p_item=leaf, p_characters=[cha], p_quantity=3, p_identified=True)[0] == 200
    assert dm.rpc("dm_give_item", p_item=moss, p_characters=[cha], p_quantity=1, p_identified=False)[0] == 200
    t.note(character=cha, camp=camp)

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        # ---- shipped config ('off'): no UI, no request, even though the server has the feature (and the rule is still off)
        Doff = CSheet(br, dm, flag_on=False)
        Doff.page.goto(APP + "#/dm/overview")
        Doff.wait(lambda: Doff.page.locator('[data-dm-section="rules"]').count() == 1)
        no_tab = Doff.page.locator('[data-dm-section="crafting"]').count() == 0
        Doff.page.locator('[data-dm-section="rules"]').click()
        Doff.wait(lambda: Doff.page.locator("[data-rules]").count() == 1)
        rules_txt = Doff.page.locator("[data-rules]").inner_text()
        check("CF-01 flag off: DM Space has no Crafting tab, Campaign rules has no Crafting row",
              no_tab and Doff.page.locator('[data-action="inventory.craft"]').count() == 0 and "Crafting" not in rules_txt, rules_txt[:200])
        Poff = CSheet(br, pa, flag_on=False)
        Poff.open(cha)
        Poff.wait(lambda: LEAF in inv_text(Poff), 15000)
        Poff.page.wait_for_timeout(1500)
        check("CF-02 flag off: the player's Inventory has no Crafting panel", Poff.page.locator("[data-crafting]").count() == 0 and "Crafting" not in inv_text(Poff))
        check("CF-03 flag off: js/crafting.js and no crafting RPC were requested (DM and player)",
              not crafting_requests(Doff.urls + Poff.urls), crafting_requests(Doff.urls + Poff.urls)[:3])
        Doff.close(); Poff.close()

        # ---- flag 'on', rule still off: the DM prepares, the player sees nothing
        D = CSheet(br, dm)
        dp = D.page
        dp.goto(APP + "#/dm/crafting")
        D.wait(lambda: dp.locator("[data-craft-recipes]").count() == 1)
        check("CF-04 flag on, campaign rule off: DM Space -> Crafting opens with the 'players cannot craft yet' note",
              dp.locator("[data-craft-off]").count() == 1)
        # the DM turns the rule on (the Crafting row of Campaign rules)
        dp.locator('[data-dm-section="rules"]').click()
        D.wait(lambda: dp.locator('[data-action="inventory.craft"]').count() == 1)
        dp.locator("details.dm-rule-cat", has=dp.locator('[data-action="inventory.craft"]')).locator("summary").click()
        dp.select_option('[data-action="inventory.craft"]', "player_managed")
        dp.locator("[data-rules] button[type=submit]").click()
        ok = D.wait(lambda: q(f"select decision from public.campaign_policy_overrides where campaign_id = '{camp}' and action_key = 'inventory.craft'").strip() == "player_managed")
        check("CF-05 Campaign rules: the DM turns Crafting on (an override, the rest unchanged)", ok)

        # ---- DM creates and publishes a recipe in the UI
        dp.locator('[data-dm-section="crafting"]').click()
        D.wait(lambda: dp.locator('[data-crd="new"]').count() == 1)
        dp.locator('[data-crd="new"]').click()
        dp.wait_for_selector(".modal [data-r=name]")
        m = dp.locator(".modal")
        m.locator("[data-r=name]").fill(RECIPE)
        m.locator("[data-r=description]").fill("Steep a silver herb.")
        m.locator('[data-pick="output"] [data-pick-q]').fill(DRAUGHT)
        D.wait(lambda: m.locator(f'[data-pick="output"] [data-pick-sel] option[value="{draught}"]').count() == 1)
        m.locator('[data-pick="output"] [data-pick-sel]').select_option(draught)
        m.locator("[data-ing-kind]").first.select_option("tag")
        m.locator("[data-ing-tag]").first.fill("silver")
        m.locator("[data-r=check_key]").select_option("nature")
        m.locator("[data-r=check_dc]").fill("37")
        m.locator("[data-r=dm_notes]").fill(DMNOTE)
        m.locator("[data-r-save][data-publish]").click()
        ok = D.wait(lambda: dp.locator("[data-craft-recipes]").inner_text().count(RECIPE) == 1 and "published" in dp.locator("[data-craft-recipes]").inner_text())
        rid = q(f"select id from public.crafting_recipes where campaign_id = '{camp}' and name = '{RECIPE}'").strip()
        check("CF-06 the DM creates and publishes a recipe (tag ingredient, Nature DC 37, DM note) in DM Space -> Crafting",
              ok and rid and q(f"select check_dc || '|' || status || '|' || dm_notes from public.crafting_recipes where id = '{rid}'").strip() == f"37|published|{DMNOTE}",
              dp.locator("[data-craft-recipes]").inner_text()[:300])
        # a second recipe naming the SECRET herb exactly (the player holds a disguised copy of it)
        st, _ = dm.rpc("dm_save_recipe", p_campaign=camp, p_recipe={"name": f"Fluff Paste {RUN}", "output_item_id": draught, "dm_notes": DMNOTE,
                       "ingredients": [{"item_id": moss, "quantity": 1, "label": "a grey fluff"}]})
        rid2 = q(f"select id from public.crafting_recipes where campaign_id = '{camp}' and name = 'Fluff Paste {RUN}'").strip()
        st2, _ = dm.rpc("dm_set_recipe_status", p_recipe=rid2, p_status="published")

        # ---- the player: everything the page receives is recorded
        P = CSheet(br, pa)
        pp = P.page
        seen = {"bodies": [], "frames": []}

        def on_response(r):
            if "/rest/v1/" in r.url or "/auth/v1/" in r.url:
                try:
                    seen["bodies"].append(r.text())
                except Exception:
                    pass
        pp.on("response", on_response)
        pp.on("websocket", lambda ws: ws.on("framereceived", lambda f: seen["frames"].append(f if isinstance(f, str) else str(f))))
        P.open(cha)
        ok = P.wait(lambda: pp.locator(f'[data-crafting] [data-recipe="{rid}"]').count() == 1, 20000)
        card = pp.locator(f'[data-recipe="{rid}"]').inner_text() if ok else ""
        check("CF-07 the player's Inventory -> Crafting lists the recipe with the result, the ingredient (have 3) and the roll, no DC",
              ok and DRAUGHT in card and "you have 3" in card and "Nature" in card and "37" not in card
              and pp.locator(f'[data-recipe="{rid2}"]').count() == 1 and "a grey fluff" in pp.locator(f'[data-recipe="{rid2}"]').inner_text(),
              card[:300] or (pp.locator("[data-crafting-slot]").count(), pp.locator("[data-crafting]").count(), P.errors[:3],
                             pp.evaluate("() => document.querySelector('[data-crafting]')?.innerText || ''")[:300]))
        pp.locator(f'[data-recipe="{rid}"] [data-cr="craft"]').click()
        pp.wait_for_selector(".modal [data-cr-roll]")
        pp.locator(".modal [data-cr-roll]").fill("12")
        pp.locator(".modal [data-cr-go]").click()
        ok = P.wait(lambda: pp.locator(f'[data-recipe="{rid}"] [data-craft-status="pending"]').count() == 1, 15000)
        check("CF-08 the player crafts with a typed roll: the attempt waits for the DM, nothing used yet",
              ok and q(f"select status || '|' || roll_total from public.crafting_attempts where character_id = '{cha}'").strip() == "pending|12"
              and q(f"select sum(quantity) from public.inventory_items where item_id = '{leaf}'").strip() == "3")

        # ---- the DM answers
        dp.goto(APP + "#/dm/overview")
        ok_badge = D.wait(lambda: dp.locator('[data-dm-section="crafting"] [data-craft-count]').count() == 1, 10000)
        dp.locator('[data-dm-section="crafting"]').click()
        D.wait(lambda: dp.locator("[data-craft-queue] [data-attempt]").count() == 1)
        att = dp.locator("[data-craft-queue] [data-attempt]").first
        at = att.inner_text()
        check("CF-09 the DM sees the attempt (badge on the tab) with the roll 12 and the DC 37", ok_badge and "12" in at and "DC 37" in at and RECIPE in at, at[:300])
        att.locator('[data-cra="roll"]').fill("38")
        att.locator('[data-cra="reply"]').fill(REPLY)
        att.locator('[data-cra="private"]').fill(PRIVATE)
        att.locator('[data-crd="approve"]').click()
        ok = D.wait(lambda: q(f"select status || '|' || outcome || '|' || dm_roll_total from public.crafting_attempts where character_id = '{cha}'").strip() == "applied|success|38")
        check("CF-10 the DM approves with an edited roll (38 >= 37): applied, success", ok,
              q(f"select status, outcome, dm_roll_total, apply_error from public.crafting_attempts where character_id = '{cha}'"))
        ok = P.wait(lambda: DRAUGHT in inv_text(P) and pp.locator(f'[data-recipe="{rid}"] [data-cr="craft"]').count() == 1, 20000)
        check("CF-11 the player's open Inventory changes live: the draught is there, the recipe can be crafted again",
              ok and q(f"select sum(quantity) from public.inventory_items where item_id = '{leaf}'").strip() == "2", inv_text(P)[:300])
        pp.locator("[data-crafting] details.cr-recent summary").click()
        rec = pp.locator("[data-crafting] details.cr-recent").inner_text()
        check("CF-12 the recent attempts show Done, the DM's reply and what was made / used", "Done" in rec and REPLY in rec and DRAUGHT in rec and LEAF in rec, rec[:300])

        # ---- REQUIRED: the player's page never received the DC, the DM notes or the secret name
        pp.wait_for_timeout(1500)
        check("CF-13 REQUIRED REST / RPC: no response body of the player's page carries the DC, a DM note, the private note or the secret name",
              not leaks(seen["bodies"]), leaks(seen["bodies"])[:3])
        check("CF-14 REQUIRED Realtime: no websocket frame of the player's page carries them", not leaks(seen["frames"]), leaks(seen["frames"])[:3])
        check("CF-15 REQUIRED DOM, localStorage and sessionStorage of the player's page hold none of them",
              not leaks([pp.content()]) and not leaks(storage(pp)), (leaks([pp.content()]) + leaks(storage(pp)))[:2])
        tabs = [call("GET", f"/rest/v1/{tb}?select=*", token=pa.jwt, key=ANON) for tb in ("crafting_recipes", "crafting_recipe_ingredients", "crafting_attempts", "character_known_recipes")]
        st3, rd = pa.rpc("get_character_recipes", p_character=cha)
        check("CF-16 REQUIRED the player's token: the four crafting tables are refused (REST), the recipe read carries nothing hidden",
              all(s in (401, 403) for s, _ in tabs) and st3 == 200 and not leaks([json.dumps(rd)]), [s for s, _ in tabs])

        errs = [e for e in D.errors + P.errors if "Failed to load resource" not in e]
        check("Z1 no console errors", not errs, errs[:5])
        check("Z2 no request left this machine", not D.remote and not P.remote)
        D.close(); P.close(); br.close()


if __name__ == "__main__":
    with iso.Isolated("CRAFTING-UI") as t:
        run(t)
    report()
