"""Rarity badge on every item with a known rarity (night 2026-11-11, T1) against the LOCAL Supabase stack.

RB-01..04  a non-magic custom item with a rarity shows a named rarity badge (inventory row, item detail, catalog picker);
           a magic item shows one rarity badge (no extra "Magic" chip); a mundane weapon with a +1 modifier shows the
           modifier's rarity.
RB-05..07  an unidentified instance shows no rarity, even when the player can read the catalog row through an identified
           copy of the same item; after the DM reveals only the rarity (partially identified) the badge shows exactly it.
RB-08      the legacy read path (?fluent=0) shows the same badge.
RB-09..10  DM Space: the content list and the player preview show the rarity name, not the raw id.
Synthetic users only (ui-rarity-*@example.test); the campaign fixture is created with docker exec. Refuses non-local URLs.
"""
import subprocess
import uuid

from playwright.sync_api import sync_playwright

from class_ui_common import ANON, APP, RUN, User, Sheet, check, report, call

DB = "supabase_db_tavern_ledger"


def sql(q):
    r = subprocess.run(["docker", "exec", "-i", DB, "psql", "-U", "postgres", "-qAt", "-v", "ON_ERROR_STOP=1"], input=q.encode(), capture_output=True)
    if r.returncode:
        raise SystemExit(r.stderr.decode())
    return r.stdout.decode().strip()


def ok(st):
    return 200 <= st < 300


CAMP_NAME = "UI Rarity Campaign"
sql("delete from public.characters where owner_id in (select id from auth.users where email like 'ui-rarity-%@example.test');"
    f"delete from public.campaigns where name = '{CAMP_NAME}'")
dm, player = User("rarity-dm"), User("rarity-pl")
camp = str(uuid.uuid4())
sql(f"""insert into public.campaigns (id, name, created_by) values ('{camp}', '{CAMP_NAME}', '{dm.id}');
insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{player.id}', 'player');
insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'standard');""")
hero = player.character(f"Rarity Hero {RUN}", classes=[("fighter-phb", 3)], strength=15)
twin = player.character(f"Rarity Twin {RUN}", classes=[("fighter-phb", 1)])
sql(f"update public.characters set campaign_id = '{camp}' where id in ('{hero}', '{twin}');"
    f"insert into public.character_governance (character_id, setup_complete) values ('{hero}', true), ('{twin}', true);")


def content(fields):
    st, c = dm.rpc("create_dm_content", p_type="item", p_campaign=camp, p_fields=fields, p_request_id=str(uuid.uuid4()))
    assert ok(st), c
    st, c = dm.rpc("publish_dm_content", p_content=c["id"])
    assert ok(st), c
    return c


def give(c, char, identified=True):
    st, r = dm.rpc("dm_assign_content", p_content=c["id"], p_characters=[char], p_mode="inventory", p_options={"identified": identified})
    assert ok(st), r


CHARM, RING, STONE = f"Moonpetal Charm {RUN}", f"Ring of Embers {RUN}", f"Stone of Kings {RUN}"
charm = content({"name": CHARM, "definition": {"item": {"kind_id": "gear", "is_magic": False, "rarity_id": "very_rare"}}})
ring = content({"name": RING, "definition": {"item": {"kind_id": "gear", "is_magic": True, "rarity_id": "rare"}}})
stone = content({"name": STONE, "definition": {"item": {"kind_id": "gear", "is_magic": False, "rarity_id": "legendary"},
                                               "hidden": {"unidentified_name": "Dull grey stone"}}})
give(charm, hero)
give(ring, hero)
give(stone, twin)                       # an identified copy the player can read ...
give(stone, hero, identified=False)     # ... and the unidentified one on the sheet under test
inv = sql(f"select id from public.inventories where character_id = '{hero}' and kind = 'character'")
sword = sql("select id from public.items where id = 'longsword' and owner_id is null")
mod = sql("select id from public.item_modifiers where id = 'weapon-plus-1'")
if sword and mod:
    st, sid = player.rpc("add_inventory_item", p_inventory=inv, p_item="longsword", p_quantity=1)
    assert ok(st), sid
    sql(f"insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values ('{sid}', 'weapon-plus-1')")
hidden_row = sql(f"select id from public.inventory_items where inventory_id = '{inv}' and name = 'Dull grey stone'")
_, leak = call("GET", f"/rest/v1/v_inventory_detail?id=eq.{hidden_row}&select=rarity_id", token=player.jwt, key=ANON)


def row(page, name):
    return page.locator(".inv-item", has=page.locator(".inv-item-name", has_text=name)).first


def rarity_badges(loc):
    return loc.locator(".inv-item-badges .inv-b-rarity").all_inner_texts()


with sync_playwright() as pw:
    browser = pw.chromium.launch(channel="msedge", headless=True)
    P = Sheet(browser, player, tab="inventory")
    p = P.page
    P.open(hero)
    P.tab("inventory")
    P.wait(lambda: row(p, CHARM).count() == 1 and row(p, "Dull grey stone").count() == 1)
    c = row(p, CHARM)
    check("RB-01 a non-magic custom item shows its rarity name as a neutral rarity badge",
          rarity_badges(c) == ["Very Rare"] and c.locator(".inv-b-rarity.inv-r-very_rare:not(.inv-b-magic)").count() == 1, (rarity_badges(c), c.inner_html()[:400]))
    r = row(p, RING)
    check("RB-02 a magic item shows exactly one rarity badge and no separate Magic chip",
          rarity_badges(r) == ["Rare"] and r.locator(".inv-b-rarity.inv-b-magic.inv-r-rare").count() == 1
          and "Magic" not in r.locator(".inv-item-badges").inner_text(), r.locator(".inv-item-badges").inner_text())
    if sword and mod:
        s = row(p, "Longsword")
        check("RB-03 a mundane longsword with a +1 modifier shows the modifier's rarity", "Uncommon" in rarity_badges(s), rarity_badges(s))
    else:
        check("RB-03 (skipped: no longsword / weapon-plus-1 in the local catalog)", True)
    c.locator(".inv-item-main").click()
    p.wait_for_selector(".modal .inv-props")
    props = p.locator(".modal .inv-props").inner_text()
    check("RB-04 the item detail lists Rarity: Very Rare", "Rarity" in props and "Very Rare" in props, props)
    p.keyboard.press("Escape")
    p.wait_for_timeout(300)

    st_ok = isinstance(leak, list) and leak and leak[0].get("rarity_id") == "legendary"
    check("RB-05 precondition: the hidden instance's row carries the real rarity for the player (identified copy elsewhere)", st_ok, leak)
    h = row(p, "Dull grey stone")
    check("RB-06 the unidentified instance shows no rarity badge and no rarity text",
          not rarity_badges(h) and "Legendary" not in h.inner_text() and STONE not in p.content(), (rarity_badges(h), h.inner_text()))

    st, kr = dm.rpc("set_item_knowledge", p_inventory_item=hidden_row, p_state="partially_identified", p_revealed=["rarity"])
    p.reload()                          # a knowledge change does not reach an open sheet by itself (no character revision)
    P.wait(lambda: p.locator(".tab").count() > 0)
    P.tab("inventory")
    P.wait(lambda: rarity_badges(row(p, "Dull grey stone")) == ["Legendary"])
    h = row(p, "Dull grey stone")
    check("RB-07 rarity revealed (partially identified): the badge shows exactly the revealed rarity, the true name stays hidden",
          ok(st) and rarity_badges(h) == ["Legendary"] and STONE not in p.content(), (st, rarity_badges(h)))

    # catalog picker
    p.locator('[data-inv="add-item"]').click()
    p.wait_for_selector(".modal input[name=search]")
    p.fill(".modal input[name=search]", "Moonpetal")
    res = p.locator(".modal .inv-result", has_text=CHARM)
    P.wait(lambda: res.count() >= 1, 15000)
    pick = res.first.inner_text() if res.count() else p.locator(".modal [data-results]").inner_text()[:300]
    check("RB-04b the catalog picker shows the rarity of a non-magic item", "Very Rare" in pick, pick)
    p.keyboard.press("Escape")

    L = Sheet(browser, player, tab="inventory")
    L.page.goto(f"{APP}?fluent=0#/c/{hero}")
    L.wait(lambda: L.page.locator(".tab").count() > 0)
    L.tab("inventory")
    L.wait(lambda: row(L.page, CHARM).count() == 1)
    check("RB-08 ?fluent=0 shows the same badges", rarity_badges(row(L.page, CHARM)) == ["Very Rare"]
          and rarity_badges(row(L.page, "Dull grey stone")) == ["Legendary"], (rarity_badges(row(L.page, CHARM)), rarity_badges(row(L.page, "Dull grey stone"))))

    D = Sheet(browser, dm)
    d = D.page
    d.goto(APP + "#/dm/overview")
    D.wait(lambda: d.locator("[data-dm-campaign]").count() > 0)
    d.select_option("[data-dm-campaign]", camp)
    D.wait(lambda: CAMP_NAME in d.locator(".dm-title h1").inner_text())
    d.locator('[data-dm-section="content"]').click()
    D.wait(lambda: d.locator(".dm-content-row", has_text=CHARM).count() == 1)
    lr = d.locator(".dm-content-row", has_text=CHARM).first
    check("RB-09 the DM content list shows the rarity name of a published item", "Very Rare" in lr.inner_text() and lr.locator(".inv-b-rarity").count() == 1, lr.inner_text())
    lr.locator('[data-dm="edit-content"]').click()
    d.wait_for_selector('.modal [data-ce-act="preview"]')
    d.locator('.modal [data-ce-act="preview"]').click()
    D.wait(lambda: CHARM in d.locator(".modal [data-ce-preview]").inner_text())
    pv = d.locator(".modal [data-ce-preview]").inner_text()
    check("RB-10 the DM preview shows the rarity name, not the raw id", "Very Rare" in pv and "very_rare" not in pv, pv)

    errs = [e for s_ in (P, L, D) for e in s_.errors if "Failed to load resource" not in e]
    check("RB-99 no console errors", not errs, errs[:5])
    for s_ in (P, L, D):
        s_.close()
    browser.close()

# synthetic data of this run (characters first: a campaign whose custom items are still in an inventory cannot be deleted)
try:
    sql("delete from public.characters where owner_id in (select id from auth.users where email like 'ui-rarity-%@example.test');"
        f"delete from public.campaigns where name = '{CAMP_NAME}';")
    sql("delete from auth.users where email like 'ui-rarity-%@example.test';")
except SystemExit as e:
    print("cleanup incomplete (synthetic ui-rarity-* rows left, removed by the next run):", str(e)[:200])
report()
