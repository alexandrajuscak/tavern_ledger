"""Crafting v1 + v2 (20261113000100, 20261114000900, docs/CRAFTING_V1.md), browser suite. LOCAL ONLY, synthetic users inside isolation.

CF-01..03  CRAFTING = 'off' (js/config.js served with the flag switched off for these contexts): DM Space has no Crafting tab and
           Campaign rules no Crafting row; the player's Inventory has no Crafting tab; js/crafting.js and no crafting RPC is requested.
CF-04..12  CRAFTING = 'on' (served with the flag on, whatever the shipped value), the campaign rule turned on by the DM: the DM writes
           a SECRET recipe in DM Space -> Crafting (tag ingredient, Herbalism kit check DC 15, a DM note) taught by a recipe book
           (a manual item, kept when read); the player opens Inventory -> Crafting (a sub-tab: tools carried, recipe books), reads
           the book (Learn recipe), sees the recipe with have / need, the tool and the DC, types the d20 total (pending); the DM
           sees the suggested outcome, confirms it with a reply and a private note; the items swap (ingredient used, result
           added) and the player's open tab follows live.
CF-07b     an unidentified ingredient never counts (a second recipe names a secret herb the player holds disguised: "Missing
           ingredients") and a direct start with it gets the one fixed refusal.
CF-13..16  REQUIRED leak check on the player's page: no REST / RPC body, no websocket frame, no DOM text and no local /
           sessionStorage value carries the DM's recipe note, the DM's private note, the DM view's check_dc key or the true name
           of the secret ingredient. (Since v2 the DC itself is shown to the player: owner decision 2026-11-13.) The player's
           token cannot read the crafting tables (REST).
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
FLAG_RE = re.compile(r"export const CRAFTING = '(off|dm|on)';")
assert FLAG_RE.search(CONFIG), "flag line not found in js/config.js"
CONFIG_ON = FLAG_RE.sub("export const CRAFTING = 'on';", CONFIG)
CONFIG_OFF = FLAG_RE.sub("export const CRAFTING = 'off';", CONFIG)
SECRET = f"Starmoss {RUN}"
DMNOTE = f"SENTINEL-DMNOTE-{RUN}"
PRIVATE = f"SENTINEL-PRIVATE-{RUN}"
REPLY = f"Nicely brewed {RUN}"
LEAF = f"Moonleaf {RUN}"
DRAUGHT = f"Healing Draught {RUN}"
RECIPE = f"Star Tea {RUN}"
MANUAL = f"Herbal Primer {RUN}"
DC_RE = re.compile(r'"check_dc"\s*:')


class CSheet(Sheet):
    """A Sheet whose context serves js/config.js with CRAFTING = 'on' / 'off' (installed before the first page load)."""

    def __init__(self, browser, user, tab="inventory", flag_on=True):
        self.ctx = browser.new_context(viewport={"width": 1366, "height": 900})
        body = CONFIG_ON if flag_on else CONFIG_OFF
        self.ctx.route(re.compile(r".*/js/config\.js(\?.*)?$"), lambda r: r.fulfill(status=200, content_type="text/javascript", body=body))
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
    manual = hb({"name": MANUAL, "kind_id": "gear"})
    assert dm.rpc("set_item_identify_options", p_item=moss, p_options={"unidentified_name": "Grey fluff", "show_kind": True})[0] == 200
    assert dm.rpc("dm_give_item", p_item=leaf, p_characters=[cha], p_quantity=3, p_identified=True)[0] == 200
    assert dm.rpc("dm_give_item", p_item=moss, p_characters=[cha], p_quantity=1, p_identified=False)[0] == 200
    assert dm.rpc("dm_give_item", p_item=manual, p_characters=[cha], p_quantity=1, p_identified=True)[0] == 200
    assert dm.rpc("dm_give_item", p_item="herbalism-kit", p_characters=[cha], p_quantity=1, p_identified=True)[0] == 200
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
        check("CF-02 flag off: the player's Inventory has no Crafting tab", Poff.page.locator('[data-inv="tab"]').count() == 0
              and Poff.page.locator("[data-crafting]").count() == 0 and "Crafting" not in inv_text(Poff))
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
        m.locator("[data-r=check_key]").select_option("herbalism-kit")
        m.locator("[data-r=check_dc]").fill("15")
        m.locator("[data-r=visibility]").select_option("secret")
        m.locator("[data-r=dm_notes]").fill(DMNOTE)
        m.locator("[data-teach-add]").click()
        m.locator('[data-pick="teach"] [data-pick-q]').fill(MANUAL)
        D.wait(lambda: m.locator(f'[data-pick="teach"] [data-pick-sel] option[value="{manual}"]').count() == 1)
        m.locator('[data-pick="teach"] [data-pick-sel]').select_option(manual)
        m.locator("[data-r-save][data-publish]").click()
        ok = D.wait(lambda: dp.locator("[data-craft-recipes]").inner_text().count(RECIPE) == 1 and "published" in dp.locator("[data-craft-recipes]").inner_text())
        rid = q(f"select id from public.crafting_recipes where campaign_id = '{camp}' and name = '{RECIPE}'").strip()
        check("CF-06 the DM writes and publishes a secret recipe (tag ingredient, Herbalism kit DC 15, DM note) taught by a recipe book (kept when read)",
              ok and rid and q(f"select check_dc || '|' || status || '|' || visibility || '|' || dm_notes from public.crafting_recipes where id = '{rid}'").strip() == f"15|published|secret|{DMNOTE}"
              and q(f"select item_id || '|' || consume_on_learn from public.crafting_recipe_teachers where recipe_id = '{rid}'").strip() == f"{manual}|false",
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
        P.wait(lambda: LEAF in inv_text(P), 15000)
        no_read_yet = not any("get_character_recipes" in u for u in P.urls)
        pp.locator('[data-inv="tab"][data-tab="crafting"]').click()
        ok = P.wait(lambda: pp.locator("[data-crafting] [data-craft-manuals]").count() == 1, 20000)
        tools = pp.locator("[data-craft-tools]").inner_text() if ok else ""
        hidden_before = pp.locator(f'[data-recipe="{rid}"]').count() == 0
        check("CF-06b Inventory -> Crafting is a sub-tab read only when opened: tools carried (Herbalism kit), the recipe book with Learn, the secret recipe not shown yet",
              ok and no_read_yet and "Herbalism" in tools and hidden_before and MANUAL in pp.locator("[data-craft-manuals]").inner_text(),
              (no_read_yet, tools[:200], hidden_before, P.errors[:3]))
        pp.locator(f'[data-craft-manuals] [data-cr="learn"]').click()
        ok = P.wait(lambda: pp.locator(f'[data-crafting] [data-recipe="{rid}"]').count() == 1, 20000)
        card = pp.locator(f'[data-recipe="{rid}"]').inner_text() if ok else ""
        check("CF-07 after reading the book the recipe is listed (learned for good, source manual, the book kept) with have / need 1 / 1, the tool present and DC 15",
              ok and DRAUGHT in card and "1 / 1" in card and "Herbalism" in card and "you have it" in card and "DC 15" in card
              and q(f"select source from public.character_known_recipes where character_id = '{cha}' and recipe_id = '{rid}'").strip() == "manual"
              and q(f"select count(*) from public.inventory_items where item_id = '{manual}'").strip() == "1"
              and pp.locator(f'[data-recipe="{rid}"] [data-cr="craft"]').is_enabled(),
              card[:300] or (P.errors[:3], pp.evaluate("() => document.querySelector('[data-crafting]')?.innerText || ''")[:300]))
        card2 = pp.locator(f'[data-recipe="{rid2}"]').inner_text() if pp.locator(f'[data-recipe="{rid2}"]').count() else ""
        moss_row = q(f"select ii.id from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id where i.character_id = '{cha}' and ii.item_id = '{moss}'").strip()
        st_m, r_m = pa.rpc("start_craft_attempt", p_character=cha, p_recipe=rid2, p_selected=[{"seq": 1, "inventory_item_id": moss_row, "quantity": 1}],
                           p_roll_total=None, p_request_id=str(uuid.uuid4()))
        check("CF-07b an unidentified ingredient never counts: the second recipe shows 0 / 1 and 'Missing ingredients'; a direct start with the disguised herb is refused with the fixed message",
              "a grey fluff" in card2 and "0 / 1" in card2 and "Missing ingredients" in card2 and st_m == 400 and "know what this ingredient is" in json.dumps(r_m),
              (card2[:200], st_m, str(r_m)[:200]))
        pp.locator(f'[data-recipe="{rid}"] [data-cr="craft"]').click()
        pp.wait_for_selector(".modal [data-cr-roll]")
        dialog_dc = "DC 15" in pp.locator(".modal").inner_text()
        pp.locator(".modal [data-cr-roll]").fill("16")
        pp.locator(".modal [data-cr-go]").click()
        ok = P.wait(lambda: pp.locator(f'[data-recipe="{rid}"] [data-craft-status="pending"]').count() == 1, 15000)
        check("CF-08 the player types the d20 total (the dialog shows the DC): the attempt waits for the DM, nothing used yet",
              ok and dialog_dc and q(f"select status || '|' || roll_total from public.crafting_attempts where character_id = '{cha}'").strip() == "pending|16"
              and q(f"select sum(quantity) from public.inventory_items where item_id = '{leaf}'").strip() == "3")

        # ---- the DM answers
        dp.goto(APP + "#/dm/overview")
        ok_badge = D.wait(lambda: dp.locator('[data-dm-section="crafting"] [data-craft-count]').count() == 1, 10000)
        dp.locator('[data-dm-section="crafting"]').click()
        D.wait(lambda: dp.locator("[data-craft-queue] [data-attempt]").count() == 1)
        att = dp.locator("[data-craft-queue] [data-attempt]").first
        at = att.inner_text()
        check("CF-09 the DM sees the attempt (badge on the tab) with the roll 16, the DC 15 and the suggested outcome Success (preselected)",
              ok_badge and "16" in at and "DC 15" in at and RECIPE in at and "Suggested: Success" in at
              and att.locator('[data-cra="outcome"]').input_value() == "success", at[:300])
        att.locator('[data-cra="reply"]').fill(REPLY)
        att.locator('[data-cra="private"]').fill(PRIVATE)
        att.locator('[data-crd="approve"]').click()
        ok = D.wait(lambda: q(f"select status || '|' || outcome from public.crafting_attempts where character_id = '{cha}'").strip() == "applied|success")
        check("CF-10 the DM confirms the suggested outcome: applied, success (the items swap in one transaction)", ok,
              q(f"select status, outcome, dm_roll_total, apply_error from public.crafting_attempts where character_id = '{cha}'"))
        ok = P.wait(lambda: DRAUGHT in inv_text(P) and pp.locator(f'[data-recipe="{rid}"] [data-cr="craft"]').count() == 1, 20000)
        check("CF-11 the items swapped and the open Crafting tab follows live: 1 leaf used (3 -> 2), the draught made, the kit kept, the recipe can be crafted again",
              ok and q(f"select sum(quantity) from public.inventory_items where item_id = '{leaf}'").strip() == "2"
              and q(f"select count(*) from public.inventory_items where item_id = 'herbalism-kit' and character_id is not distinct from character_id and inventory_id in (select id from public.inventories where character_id = '{cha}')").strip() == "1",
              inv_text(P)[:300])
        pp.locator("[data-crafting] details.cr-recent summary").click()
        rec = pp.locator("[data-crafting] details.cr-recent").inner_text()
        check("CF-12 the recent attempts show Done, the DM's reply and what was made / used", "Done" in rec and REPLY in rec and DRAUGHT in rec and LEAF in rec, rec[:300])

        # ---- REQUIRED: the player's page never received the DC, the DM notes or the secret name
        pp.wait_for_timeout(1500)
        check("CF-13 REQUIRED REST / RPC: no response body of the player's page carries check_dc, a DM note, the private note or the secret name",
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
