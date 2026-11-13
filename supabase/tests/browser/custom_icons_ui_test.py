"""The DM's own item icons (20261114000200, docs/CUSTOM_ICONS.md). LOCAL ONLY, synthetic users.

One player holds the same campaign herb on two characters: A1 identified, A2 disguised (decoy). The DM uploads an icon in
DM Space -> Content -> Item icons (the browser shrinks it to <= 128 px WebP). Checks: the stored object is a small WebP under
a random name; A1's inventory shows the icon; A2's disguised copy shows the default icon and the icon's path reaches A2's
session nowhere (REST bodies, websocket frames, DOM, storage); removing the icon brings the default back on A1 and keeps the
file. Storage API limits (server side): an oversized PNG, an HTML file and a player's upload are refused. Measurement for
the public-vs-private decision: API requests of an inventory open with an icon, and the cost of one batch URL signing.
Usage: APP_URL=... python custom_icons_ui_test.py   (run_browser_local.sh sets the environment)
"""
import io
import os
import random
import tempfile
import time
import urllib.error
import urllib.request
import uuid

from PIL import Image
from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import ANON, API, APP, RUN, Sheet, User, check, report

q = iso.psql
HERB, HERB_DESC, DECOY = f"Dawnpetal {RUN}", f"Smells of sunrise {RUN}", f"Brown leaf {RUN}"


def png_bytes(w, h, noise=False):
    img = Image.new("RGB", (w, h))
    px = img.load()
    rnd = random.Random(7)
    for x in range(w):
        for y in range(h):
            px[x, y] = (rnd.randrange(256), rnd.randrange(256), rnd.randrange(256)) if noise else (x * 255 // w, y * 255 // h, 120)
    out = io.BytesIO()
    img.save(out, "PNG")
    return out.getvalue()


def storage_upload(user, path, data, ctype):
    req = urllib.request.Request(f"{API}/storage/v1/object/item-icons/{path}", data=data, method="POST",
                                 headers={"apikey": ANON, "Authorization": f"Bearer {user.jwt}", "Content-Type": ctype})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def sign_batch(user, paths):
    import json
    req = urllib.request.Request(f"{API}/storage/v1/object/sign/item-icons", data=json.dumps({"expiresIn": 3600, "paths": paths}).encode(),
                                 method="POST", headers={"apikey": ANON, "Authorization": f"Bearer {user.jwt}", "Content-Type": "application/json"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=30) as r:
        r.read()
        return r.status, (time.perf_counter() - t0) * 1000


def inv_icon(sheet, name):
    """src of the icon of the inventory row whose name contains `name`."""
    row = sheet.page.locator("#panel-inventory .inv-item", has_text=name).first
    return row.locator(".inv-item-icon").get_attribute("src") or ""


def run():
    dm, pa = User("icdm"), User("icpa")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'Icon Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pa.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    a1 = pa.character(f"Icon One {RUN}", [("wizard-phb", 1)])
    a2 = pa.character(f"Icon Two {RUN}", [("fighter-phb", 1)])
    q(f"update public.characters set campaign_id = '{camp}' where id in ('{a1}', '{a2}');"
      f"insert into public.character_governance (character_id, setup_complete) values ('{a1}', true), ('{a2}', true);")
    st, it = dm.rpc("create_homebrew_item", p_request_id=str(uuid.uuid4()), p_definition={
        "name": HERB, "kind_id": "herbs_plants", "category_id": "plant-flower", "campaign_id": camp, "description": HERB_DESC, "stackable": True},
        p_stats={})
    assert st == 200, (st, it)
    herb = it["id"]
    assert dm.rpc("set_item_identify_options", p_item=herb, p_options={"unidentified_name": DECOY, "show_kind": True})[0] == 200
    assert dm.rpc("dm_give_item", p_item=herb, p_characters=[a1], p_quantity=1, p_identified=True)[0] == 200
    assert dm.rpc("dm_give_item", p_item=herb, p_characters=[a2], p_quantity=1, p_identified=False)[0] == 200
    src_png = os.path.join(tempfile.gettempdir(), f"tl-icon-{RUN}.png")
    with open(src_png, "wb") as f:
        f.write(png_bytes(600, 400))     # a "photo" far larger than an icon: the browser must shrink it

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        # ---- 1. the DM uploads in DM Space -> Content -> Item icons ------------------------------------------------------------
        D = Sheet(br, dm, tab="inventory")
        dp = D.page
        dp.goto(APP + "#/dm/content")
        D.wait(lambda: dp.locator('[data-dm="item-icons"]').count() == 1, 20000)
        dp.locator('[data-dm="item-icons"]').click()
        D.wait(lambda: dp.locator(f'.ii-row[data-ii-item="{herb}"]').count() == 1)
        dp.fill("[data-ii-q]", HERB)
        row = dp.locator(f'.ii-row[data-ii-item="{herb}"]')
        with dp.expect_file_chooser() as fc:
            row.locator("[data-ii-up]").click()
        fc.value.set_files(src_png)
        ok_ui = D.wait(lambda: dp.locator(f'.ii-row[data-ii-item="{herb}"] [data-ii-rm]').count() == 1, 20000)
        obj = q(f"select o.name || '|' || (o.metadata ->> 'mimetype') || '|' || (o.metadata ->> 'size') from public.campaign_item_icons x"
                f" join storage.objects o on o.bucket_id = 'item-icons' and o.name = x.object_path where x.campaign_id = '{camp}' and x.item_id = '{herb}'").strip()
        path, mime, size = (obj.split("|") + ["", "", ""])[:3]
        check("CU1 DM Space: the DM uploads an icon; the browser shrank a 600x400 PNG to a small WebP under a random name (no item id or name)",
              ok_ui and mime == "image/webp" and 0 < int(size or 0) <= 16000 and path.startswith(camp + "/") and herb not in path
              and HERB.split()[0].lower() not in path.lower() and not D.errors, (obj, D.errors[:3]))
        img_px = dp.evaluate("""async (u) => { const r = await fetch(u); const b = await createImageBitmap(await r.blob()); return [b.width, b.height]; }""",
                             f"{API}/storage/v1/object/public/item-icons/{path}")
        check("CU2 the stored icon is at most 128 px on its longest side", max(img_px) <= 128 and max(img_px) >= 100, img_px)
        dp.locator(".modal [data-close]").first.click()

        # ---- 2. the player: identified copy shows it, disguised copy does not ----------------------------------------------------
        P = Sheet(br, pa, tab="inventory")
        pp = P.page
        seen = {"bodies": [], "frames": [], "api": [], "imgs": []}

        def on_response(r):
            if "/rest/v1/" in r.url:
                try:
                    seen["bodies"].append(r.text())
                except Exception:
                    pass
        pp.on("response", on_response)
        pp.on("request", lambda r: seen["api"].append(r.url) if ("/rest/v1/" in r.url or "/storage/v1/object/sign" in r.url) else None)
        pp.on("request", lambda r: seen["imgs"].append(r.url) if "/storage/v1/object/public/item-icons/" in r.url else None)
        pp.on("websocket", lambda ws: ws.on("framereceived", lambda f: seen["frames"].append(f if isinstance(f, str) else str(f))))
        P.open(a2)
        P.wait(lambda: DECOY in pp.locator("#panel-inventory").inner_text(), 20000)
        pp.wait_for_timeout(800)
        a2_src = inv_icon(P, DECOY)
        everything = seen["bodies"] + seen["frames"] + [pp.content()] + pp.evaluate(
            "() => { const o = []; for (const s of [localStorage, sessionStorage]) for (let i = 0; i < s.length; i++) o.push(s.getItem(s.key(i))); return o; }")
        leaked = [t[:120] for t in everything if path and path.split("/")[1].split(".")[0] in t]
        check("CU3 REQUIRED the disguised copy (A2) shows the default icon; the icon path reached A2's session nowhere (REST, websocket, DOM, storage)",
              "assets/icons/" in a2_src and "item-icons" not in a2_src and not leaked and not seen["imgs"], (a2_src, leaked, seen["imgs"]))
        api_before = len(seen["api"])
        P.open(a1)
        P.wait(lambda: HERB in pp.locator("#panel-inventory").inner_text(), 20000)
        P.wait(lambda: "item-icons" in inv_icon(P, HERB), 10000)
        pp.wait_for_timeout(1500)
        a1_src = inv_icon(P, HERB)
        loaded = pp.evaluate("""() => [...document.querySelectorAll('#panel-inventory img.tl-icon-custom')].map((i) => i.complete && i.naturalWidth > 0)""")
        open_api = [u.split("?")[0].split("/v1/")[-1] for u in seen["api"][api_before:]]
        check("CU4 the identified copy (A1) shows the DM's icon (loaded); no signing request and no extra API request for it",
              path in a1_src and loaded and all(loaded) and not any("sign" in u for u in open_api), (a1_src, loaded, open_api))
        print(f"   measure: A1 open -> {len(open_api)} API requests ({', '.join(sorted(set(open_api)))}), "
              f"{len(set(seen['imgs']))} icon image request(s)")
        # the legacy read path (?fluent=0) gets the same per-copy reference from v_inventory_detail
        pp.goto(f"{APP}?fluent=0#/c/{a1}")
        P.wait(lambda: pp.locator(".tab").count() > 0, 20000)
        pp.locator('.tab[data-tab="inventory"]').click()
        legacy_a1 = P.wait(lambda: path in inv_icon(P, HERB), 20000)
        pp.goto(f"{APP}?fluent=0#/c/{a2}")
        P.wait(lambda: pp.locator(".tab").count() > 0, 20000)
        pp.locator('.tab[data-tab="inventory"]').click()
        P.wait(lambda: DECOY in pp.locator("#panel-inventory").inner_text(), 20000)
        legacy_a2 = inv_icon(P, DECOY)
        check("CU4b ?fluent=0: A1 shows the icon, A2's disguised copy the default (same per-copy rule)",
              legacy_a1 and "assets/icons/" in legacy_a2 and pp.evaluate("() => document.querySelector('[data-read-path]')?.dataset.readPath") == "legacy",
              (legacy_a1, legacy_a2))
        pp.goto(f"{APP}?fluent=default")   # back to the default read path (the override is remembered)
        pp.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)

        # ---- 3. remove: default back, file kept -----------------------------------------------------------------------------------
        dp.goto(APP + "#/dm/content")
        D.wait(lambda: dp.locator('[data-dm="item-icons"]').count() == 1, 20000)
        dp.locator('[data-dm="item-icons"]').click()
        D.wait(lambda: dp.locator(f'.ii-row[data-ii-item="{herb}"] [data-ii-rm]').count() == 1)
        dp.locator(f'.ii-row[data-ii-item="{herb}"] [data-ii-rm]').click()
        dp.locator(".modal .btn-gold, .modal [data-ok]").last.click()
        removed = D.wait(lambda: dp.locator(f'.ii-row[data-ii-item="{herb}"] [data-ii-rm]').count() == 0, 15000)
        P.open(a2)
        P.open(a1)
        P.wait(lambda: HERB in pp.locator("#panel-inventory").inner_text(), 20000)
        back = P.wait(lambda: "assets/icons/" in inv_icon(P, HERB), 10000)
        kept = q(f"select count(*) from storage.objects where bucket_id = 'item-icons' and name = '{path}'").strip()
        check("CU5 removing the icon brings the default back on A1; the uploaded file is kept (never deleted)",
              removed and back and kept == "1", (removed, inv_icon(P, HERB), kept))

        # ---- 4. Storage API limits (server side, without the browser's shrink) ----------------------------------------------------
        big = png_bytes(200, 200, noise=True)
        s_big, b_big = storage_upload(dm, f"{camp}/{uuid.uuid4()}.png", big, "image/png")
        s_html, b_html = storage_upload(dm, f"{camp}/{uuid.uuid4()}.webp", b"<html><script>alert(1)</script></html>", "text/html")
        s_pl, b_pl = storage_upload(pa, f"{camp}/{uuid.uuid4()}.png", png_bytes(32, 32), "image/png")
        s_ok, _ = storage_upload(dm, f"{camp}/{uuid.uuid4()}.png", png_bytes(32, 32), "image/png")
        check("CU6 Storage refuses an oversized PNG (> 64 KB), an HTML file and a player's upload; a small DM PNG is accepted",
              len(big) > 65536 and s_big >= 400 and s_html >= 400 and s_pl >= 400 and s_ok == 200,
              (len(big), s_big, b_big[:120], s_html, b_html[:120], s_pl, b_pl[:120], s_ok))
        # measurement for the trade-off (private bucket would need this once per sheet open)
        times = [sign_batch(dm, [path] * 3)[1] for _ in range(5)]
        print(f"   measure: one batch signing request (3 paths) took {', '.join(f'{t:.0f}' for t in times)} ms locally")
        check("CU7 no console errors in the DM's or the player's session", not D.errors and not P.errors, (D.errors[:3], P.errors[:3]))
        br.close()
    report()


if __name__ == "__main__":
    run()
