"""Per-character reveal of a hidden item (20261112000400, docs/HIDDEN_DM_DATA.md "Revealing items to characters"). LOCAL ONLY,
synthetic users inside isolation.

Covers: two players A and B both hold the same disguised campaign herb. The DM uses DM Space -> Hidden -> Who knows what to
reveal it to A only ("Set" Everything): A's open sheet shows the true name live, B's open sheet keeps the decoy. REQUIRED
leak check for B: no REST response, no Realtime frame (also an unfiltered devtools-style postgres_changes subscription on
inventory_items), no DOM text and no localStorage / sessionStorage value of B's session ever carries the true name or
description; REST / RPC with B's token afterwards are clean. Then: undo for A (Set Nothing) -> A's sheet is back to the decoy
live; partial reveal "Name only" to B -> B sees the name, not the description; the history lists the changes; the Hidden tab
shows the number of pending examine requests; ?fluent=0 for B shows only what B knows.
Usage: APP_URL=... python item_reveal_ui_test.py   (run_browser_local.sh sets the environment)
"""
import json
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import ANON, APP, RUN, Sheet, User, call, check, report

q = iso.psql
TRUE = f"Moonpetal {RUN}"
TRUE_DESC = f"Sings at midnight {RUN}"
DECOY = "Grey petal"
DECOY_DESC = "A dull grey petal."
SECRETS = (TRUE, TRUE_DESC)


def leaks(texts, secrets=SECRETS):
    return [t[:160] for t in texts if any(s in t for s in secrets)]


def storage(page):
    return page.evaluate("""() => { const out = [];
        for (const s of [localStorage, sessionStorage]) for (let i = 0; i < s.length; i++) { const k = s.key(i); out.push(k + '=' + s.getItem(k)); }
        return out; }""")


def inv_text(sheet):
    return sheet.page.locator("#panel-inventory").inner_text()


def run(t):
    dm, pa, pb = User("irdm"), User("irpa"), User("irpb")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'IR Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pa.id}', 'player'), ('{camp}', '{pb.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    cha = pa.character(f"IR Alpha {RUN}", [("fighter-phb", 1)])
    chb = pb.character(f"IR Beta {RUN}", [("fighter-phb", 1)])
    q(f"update public.characters set campaign_id = '{camp}' where id in ('{cha}', '{chb}');"
      f"insert into public.character_governance (character_id, setup_complete) values ('{cha}', true), ('{chb}', true);")
    st, hb = dm.rpc("create_homebrew_item", p_request_id=str(uuid.uuid4()), p_definition={
        "name": TRUE, "kind_id": "herbs_plants", "category_id": "plant-flower", "campaign_id": camp, "stackable": True,
        "description": TRUE_DESC}, p_stats={})
    assert st == 200, (st, hb)
    herb = hb["id"]
    st, _ = dm.rpc("set_item_identify_options", p_item=herb, p_options={
        "unidentified_name": DECOY, "unidentified_description": DECOY_DESC, "show_kind": True, "identify_dc": 12})
    assert st == 200
    st, _ = dm.rpc("dm_give_item", p_item=herb, p_characters=[cha, chb], p_quantity=1, p_identified=False)
    assert st == 200
    t.note(a=cha, b=chb, herb=herb)

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        # ---- player B: everything B's session receives is recorded
        B = Sheet(br, pb, tab="inventory")
        bp = B.page
        seen = {"bodies": [], "frames": []}

        def on_response(r):
            if "/rest/v1/" in r.url:
                try:
                    seen["bodies"].append(r.text())
                except Exception:
                    pass
        bp.on("response", on_response)
        bp.on("websocket", lambda ws: ws.on("framereceived", lambda f: seen["frames"].append(f if isinstance(f, str) else str(f))))
        B.open(chb)
        B.wait(lambda: DECOY in inv_text(B), 15000)
        bp.evaluate("""async () => {
            window.__leak = []; window.__leakStatus = '';
            const m = await import('./js/supabase.js?v=26');
            m.supabase.channel('leak-probe-all').on('postgres_changes', { event: '*', schema: 'public', table: 'inventory_items' },
              (x) => window.__leak.push(JSON.stringify(x))).subscribe((s) => { window.__leakStatus = s; });
        }""")
        B.wait(lambda: bp.evaluate("window.__leakStatus") == "SUBSCRIBED", 10000)
        # ---- player A
        A = Sheet(br, pa, tab="inventory")
        ap = A.page
        A.open(cha)
        check("R1 before: both players' open sheets show only the decoy", A.wait(lambda: DECOY in inv_text(A)) and DECOY in inv_text(B)
              and TRUE not in inv_text(A) and TRUE not in inv_text(B))

        # ---- DM: Who knows what -> Set A to Everything
        D = Sheet(br, dm, tab="inventory")
        dp = D.page
        dp.goto(APP + "#/dm/hidden")
        D.wait(lambda: dp.locator("[data-rv-item]").count() == 1)
        dp.select_option("[data-rv-item]", herb)
        D.wait(lambda: dp.locator(f'[data-rv-char="{cha}"]').count() == 1)
        mt = dp.locator("[data-reveal]").inner_text()
        check("R2 DM matrix: both characters, holding one each, knowing nothing; the decoy is shown",
              dp.locator("[data-rv-char]").count() == 2 and mt.count("Nothing (hidden)") >= 2 and DECOY in mt, mt[:400])
        row_a = dp.locator(f'[data-rv-char="{cha}"]')
        row_a.locator("[data-rv-level]").select_option("all")
        row_a.locator('[data-rv="set"]').click()
        D.wait(lambda: "Everything" in dp.locator(f'[data-rv-char="{cha}"] [data-rv-now]').inner_text())
        ok = A.wait(lambda: TRUE in inv_text(A), 15000)
        check("R3 A's open sheet shows the true name live (no reload)", ok, inv_text(A)[:300])
        bp.wait_for_timeout(2500)
        check("R4 B's open sheet still shows only the decoy", DECOY in inv_text(B) and TRUE not in inv_text(B), inv_text(B)[:300])
        rt = bp.evaluate("window.__leak")
        check("R5 REQUIRED Realtime: no frame on B's socket and no event of an unfiltered inventory_items subscription carries the truth",
              not leaks(seen["frames"] + rt), leaks(seen["frames"] + rt)[:3])
        check("R6 REQUIRED REST: no response B's page received carries the truth", not leaks(seen["bodies"]), leaks(seen["bodies"])[:3])
        st1, rows = call("GET", f"/rest/v1/v_inventory_detail?character_id=eq.{chb}&select=*", token=pb.jwt, key=ANON)
        st2, raw = call("GET", f"/rest/v1/items?id=eq.{herb}&select=*", token=pb.jwt, key=ANON)
        st3, kn = pb.rpc("get_character_item_knowledge", p_character=chb)
        st4, rd = pb.rpc("get_character_reads", p_character=chb, p_reads=["inventory_bundle"])
        st5, au = pb.rpc("get_campaign_audit", p_campaign=camp)
        blob = json.dumps([rows, raw, kn, rd, au])
        check("R7 REQUIRED B's token: view row (decoy, no item id), catalog row closed, knowledge read, bundle and audit carry no truth",
              st1 == 200 and any(r["name"] == DECOY and r["item_id"] is None for r in rows) and st2 == 200 and raw == []
              and st3 == 200 and st4 == 200 and st5 == 200 and not leaks([blob]), leaks([blob])[:2])
        check("R8 REQUIRED B's DOM, localStorage and sessionStorage hold no truth",
              not any(s in bp.content() for s in SECRETS) and not leaks(storage(bp)), leaks(storage(bp))[:2])
        st6, rows_a = call("GET", f"/rest/v1/v_inventory_detail?character_id=eq.{cha}&select=*", token=pa.jwt, key=ANON)
        check("R9 A's token: the row shows the true name and the item id", st6 == 200 and any(r["name"] == TRUE and r["item_id"] == herb for r in rows_a), rows_a[:1])

        # ---- undo for A
        row_a = dp.locator(f'[data-rv-char="{cha}"]')
        row_a.locator("[data-rv-level]").select_option("none")
        row_a.locator('[data-rv="set"]').click()
        ok = A.wait(lambda: DECOY in inv_text(A) and TRUE not in inv_text(A), 15000)
        check("R10 undo: A's open sheet is back to the decoy live; the matrix says Nothing (hidden)",
              ok and D.wait(lambda: "Nothing (hidden)" in dp.locator(f'[data-rv-char="{cha}"] [data-rv-now]').inner_text()), inv_text(A)[:200])

        # ---- partial: name only for B (bulk: select B, Reveal to selected)
        dp.locator(f'[data-rv-sel][value="{chb}"]').check()
        dp.select_option("[data-rv-bulk]", "name")
        dp.locator('[data-rv="reveal-selected"]').click()
        ok = B.wait(lambda: TRUE in inv_text(B), 15000)
        bp.locator("#panel-inventory .inv-item-main", has_text=TRUE).first.click()
        bp.wait_for_selector(".modal")
        mtb = bp.locator(".modal").inner_text()
        check("R11 'Name only' for B: B's sheet shows the true name live, the dialog keeps the decoy description",
              ok and DECOY_DESC in mtb and TRUE_DESC not in mtb and "Partly identified" in mtb, mtb[:300])
        bp.keyboard.press("Escape")
        check("R12 B's session never received the true description", not leaks(seen["frames"] + seen["bodies"] + bp.evaluate("window.__leak") + storage(bp), (TRUE_DESC,)))
        check("R13 A is not affected by B's reveal", TRUE not in inv_text(A))
        D.wait(lambda: dp.locator("[data-reveal] details").count() == 1)
        dp.locator("[data-reveal] details summary").click()
        hist = dp.locator("[data-reveal] details").inner_text()
        check("R14 the history lists the reveal, the undo and the partial reveal with the DM as actor",
              hist.count("→") >= 3 and "Name only" in hist, hist[:400])

        # ---- the examine badge
        st, ex = pa.rpc("examine_inventory_item", p_inventory_item=[r for r in rows_a if r["item_id"] == herb][0]["id"], p_check="nature", p_roll=9,
                        p_request=str(uuid.uuid4()))
        dp.goto(APP + "#/dm/overview")
        ok = D.wait(lambda: dp.locator('[data-dm-section="hidden"] [data-examine-count]').count() == 1, 10000)
        check("R15 the Hidden tab shows the number of pending examine requests",
              st == 200 and ok and dp.locator('[data-dm-section="hidden"] [data-examine-count]').inner_text().strip() == "1", (st, ex))

        # ---- legacy path for B
        bp.goto(f"{APP}?fluent=0#/c/{chb}")
        B.wait(lambda: bp.locator(".tab").count() > 0)
        if TRUE not in inv_text(B):
            bp.locator('.tab[data-tab="inventory"]').click()
        ok = B.wait(lambda: TRUE in inv_text(B), 15000)
        check("R16 ?fluent=0: B sees the name it learned and never the description", ok and TRUE_DESC not in bp.content())

        errs = [e for e in A.errors + B.errors + D.errors if "Failed to load resource" not in e]
        check("Z1 no console errors", not errs, errs[:5])
        check("Z2 no request left this machine", not A.remote and not B.remote and not D.remote)
        A.ctx.close(); B.ctx.close(); D.ctx.close(); br.close()


if __name__ == "__main__":
    with iso.Isolated("ITEM-REVEAL-UI") as t:
        run(t)
    report()
