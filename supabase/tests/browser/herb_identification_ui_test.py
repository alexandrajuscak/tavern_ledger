"""Herbs & Plants identification (20261112000300, docs/HIDDEN_DM_DATA.md "Identifying items: Examine"). LOCAL ONLY,
synthetic users inside isolation.

Covers: the DM sets the decoy and the Examine check of a campaign herb in DM Space (Identification settings) and gives it
unidentified to a player; the player's open sheet shows the decoy name, the decoy description and the Herbs & Plants filter,
examines it with the total of a physical roll (Nature 15); the DM confirms in DM Space; the player's open sheet shows the
true name live (no reload); a second player's character still sees only the decoy. LEAK checks: before the reveal no REST
response, Realtime frame or a devtools-style postgres_changes subscription on inventory_items (INSERT of the assignment)
carries the true name, the true description, the DC or the hint; REST / RPC / get_character_reads (miss + hit) with the second
player's token stay clean after the reveal of the first.
Usage: APP_URL=... python herb_identification_ui_test.py   (run_browser_local.sh sets the environment)
"""
import json
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import ANON, APP, RUN, SHOTS, Sheet, User, call, check, report

SHOTS.mkdir(parents=True, exist_ok=True)
q = iso.psql
TRUE = f"Nightshade Bloom {RUN}"
TRUE_DESC = f"Deadly purple flower {RUN}"
DECOY = "Purple wildflower"
DECOY_DESC = "A pretty purple flower."
HINT = f"It smells like lavender {RUN}"
SECRETS = (TRUE, TRUE_DESC, HINT, "Paralysis poison in the sap")


def leaks(texts):
    return [t[:160] for t in texts if any(s in t for s in SECRETS) or '"identify_dc"' in t or '"dc":13' in t or '"dc": 13' in t]


def run(t):
    dm, pl, pl2 = User("hidm"), User("hipl"), User("hipl2")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'HI Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player'), ('{camp}', '{pl2.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    # this test covers the PER-CHARACTER model ("second player still disguised"): party sharing (20261114000300, on by default)
    # is switched off for its campaign; party sharing itself: party_knowledge_ui_test.py
    q(f"insert into public.campaign_item_rules (campaign_id, share_identification) values ('{camp}', false);")
    ch = pl.character(f"HI Herbalist {RUN}", [("fighter-phb", 1)])
    ch2 = pl2.character(f"HI Other {RUN}", [("fighter-phb", 1)])
    q(f"update public.characters set campaign_id = '{camp}' where id in ('{ch}', '{ch2}');"
      f"insert into public.character_governance (character_id, setup_complete) values ('{ch}', true), ('{ch2}', true);")
    st, hb = dm.rpc("create_homebrew_item", p_request_id=str(uuid.uuid4()), p_definition={
        "name": TRUE, "kind_id": "herbs_plants", "category_id": "plant-flower", "campaign_id": camp, "stackable": True, "is_consumable": True,
        "description": TRUE_DESC, "details": {"harvesting": "Paralysis poison in the sap", "properties": ["poisonous"]}}, p_stats={})
    assert st == 200, (st, hb)
    herb = hb["id"]
    t.note(character=ch, herb=herb)

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        P = Sheet(br, pl, tab="inventory")
        pp = P.page
        seen = {"bodies": [], "frames": []}

        def on_response(r):
            if "/rest/v1/" in r.url:
                try:
                    seen["bodies"].append(r.text())
                except Exception:
                    pass
        pp.on("response", on_response)
        pp.on("websocket", lambda ws: ws.on("framereceived", lambda f: seen["frames"].append(f if isinstance(f, str) else str(f))))
        P.open(ch)
        P.wait(lambda: pp.locator("#panel-inventory .inv-chip").count() > 0)
        # a devtools-style subscription: what ANY player could receive about inventory_items of this character
        pp.evaluate("""async (cid) => {
            window.__leak = []; window.__leakStatus = '';
            const m = await import('./js/supabase.js?v=35');
            m.supabase.channel('leak-probe').on('postgres_changes', { event: '*', schema: 'public', table: 'inventory_items', filter: 'character_id=eq.' + cid },
              (x) => window.__leak.push(JSON.stringify(x))).subscribe((s) => { window.__leakStatus = s; });
        }""", ch)
        P.wait(lambda: pp.evaluate("window.__leakStatus") == "SUBSCRIBED", 10000)
        pp.wait_for_timeout(1500)

        # ---- DM: Identification settings and Give (DM Space -> Hidden)
        D = Sheet(br, dm, tab="inventory")
        dp = D.page
        dp.goto(APP + "#/dm/hidden")
        D.wait(lambda: dp.locator("[data-h-char]").count() == 1)
        dp.select_option("[data-h-char]", ch)
        D.wait(lambda: dp.locator("[data-give-item]").count() == 1)
        dp.select_option("[data-give-item]", herb)
        dp.locator('[data-h="give-opts"]').click()
        dp.wait_for_selector(".modal [data-o-save]")
        dp.fill('.modal [data-o="unidentified_name"]', DECOY)
        dp.fill('.modal [data-o="unidentified_description"]', DECOY_DESC)
        dp.check('.modal [data-o="show_kind"]')
        dp.fill('.modal [data-o="identify_dc"]', "13")
        dp.check('.modal [data-o-check][value="nature"]')
        dp.check('.modal [data-o-check][value="herbalism-kit"]')
        dp.fill('.modal [data-o="fail_hint"]', HINT)
        dp.locator(".modal [data-o-save]").click()
        D.wait(lambda: dp.locator(".modal [data-o-save]").count() == 0)
        sec = q(f"select identify_dc || '|' || face_kind_id || '|' || array_to_string(identify_checks, ',') || '|' || unidentified_name from public.item_secrets where item_id = '{herb}'")
        check("H1 DM Space: the DM sets decoy, type shown, DC 13, Nature / Herbalism kit and a hint", sec.startswith("13|herbs_plants|") and "nature" in sec and DECOY in sec, sec)
        D.wait(lambda: dp.locator("[data-give-item]").count() == 1)
        dp.select_option("[data-give-item]", herb)
        dp.fill("[data-give-qty]", "2")
        dp.locator('[data-h="give"]').click()
        D.wait(lambda: q(f"select count(*) from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id where i.character_id = '{ch}' and ii.item_id = '{herb}'") == "1")
        dm.rpc("dm_give_item", p_item=herb, p_characters=[ch2], p_quantity=1, p_identified=False)

        # ---- player: decoy, filter, examine
        ok = P.wait(lambda: DECOY in pp.locator("#panel-inventory").inner_text(), 15000)
        check("H2 the player's open sheet shows the decoy live (no reload)", ok, pp.locator("#panel-inventory").inner_text()[:300])
        pp.locator('#panel-inventory [data-filter="herbs"]').click()
        P.wait(lambda: DECOY in pp.locator("#panel-inventory .inv-list, #panel-inventory").inner_text())
        check("H3 the herb is under Herbs & Plants (face type) and is not an old-sheet item",
              pp.locator('#panel-inventory [data-filter="herbs"] .count').inner_text().strip() == "1" and "Old sheet item" not in pp.locator("#panel-inventory").inner_text())
        pp.locator("#panel-inventory .inv-item-main", has_text=DECOY).first.click()
        pp.wait_for_selector(".modal .inv-knowledge")
        mt = pp.locator(".modal").inner_text()
        check("H4 the item dialog shows the decoy description, 'Unidentified' and the Examine form with the allowed checks only",
              DECOY_DESC in mt and "Unidentified" in mt and pp.locator('.modal [data-form="examine"] select[name=check] option').count() == 2, mt[:400])
        pp.screenshot(path=str(SHOTS / "herb_identify_player.png"))
        pp.select_option('.modal [data-form="examine"] select[name=check]', "nature")
        pp.fill('.modal [data-form="examine"] input[name=roll]', "15")
        pp.locator('.modal [data-form="examine"] button[type=submit]').click()
        ok = P.wait(lambda: q(f"select status from public.item_identify_attempts where character_id = '{ch}' order by created_at desc limit 1") == "pending")
        check("H5 Examine (Nature 15) creates a pending attempt; the row shows 'waiting for the DM'",
              ok and P.wait(lambda: "waiting for the DM" in pp.locator("#panel-inventory").inner_text()))
        pp.wait_for_timeout(2500)
        leak_rt = pp.evaluate("window.__leak")
        check("LK1 Realtime subscription on inventory_items (assignment INSERT, examine): only the decoy, never the truth",
              any(DECOY in x for x in leak_rt) and not leaks(leak_rt), leak_rt[:2])
        check("LK2 no REST response / Realtime frame before the reveal carried the true name, description, hint or DC",
              not leaks(seen["bodies"] + seen["frames"]), leaks(seen["bodies"] + seen["frames"])[:3])
        check("LK3 the player's DOM never held the truth", not any(s in pp.content() for s in SECRETS))

        # ---- DM confirms in DM Space
        for _ in range(3):   # the Hidden section reads the queue when it opens
            dp.goto(APP + "#/dm/overview")
            dp.goto(APP + "#/dm/hidden")
            if D.wait(lambda: dp.locator("[data-identify-queue] [data-attempt]").count() == 1, 8000):
                break
        qt = dp.locator("[data-identify-queue]").inner_text()
        check("H6 DM Space lists the request with the true name, the decoy, the roll and the DC", TRUE in qt and DECOY in qt and "15" in qt and "DC 13" in qt, qt[:300])
        dp.screenshot(path=str(SHOTS / "herb_identify_dm.png"))
        dp.locator('[data-identify-queue] [data-h="id-resolve"][data-ok="1"]').click()
        D.wait(lambda: dp.locator("[data-identify-queue] [data-attempt]").count() == 0)
        ok = P.wait(lambda: TRUE in pp.locator("#panel-inventory").inner_text(), 15000)
        check("H7 confirmed: the player's open sheet shows the true name live (no reload)", ok, pp.locator("#panel-inventory").inner_text()[:300])
        pp.locator("#panel-inventory .inv-item-main", has_text=TRUE).first.click()
        pp.wait_for_selector(".modal")
        mt = pp.locator(".modal").inner_text()
        check("H8 the identified herb shows its true description and details; no Examine form", TRUE_DESC in mt and "Paralysis" in mt
              and pp.locator('.modal [data-form="examine"]').count() == 0, mt[:300])
        pp.keyboard.press("Escape")

        # ---- the second player's character: still the decoy (REST, RPC, get_character_reads miss + hit)
        st1, rows = call("GET", f"/rest/v1/v_inventory_detail?character_id=eq.{ch2}&select=*", token=pl2.jwt, key=ANON)
        st2, raw = call("GET", f"/rest/v1/items?id=eq.{herb}&select=*", token=pl2.jwt, key=ANON)
        st3, kn = pl2.rpc("get_character_item_knowledge", p_character=ch2)
        reads = [pl2.rpc("get_character_reads", p_character=ch2, p_reads=["inventory_bundle", "get_character_derived_stats"]) for _ in range(2)]
        blob = json.dumps([rows, raw, kn, [r[1] for r in reads]])
        check("H9 per character: the second player's character still sees only the decoy (REST view, catalog, knowledge, reads x2)",
              st1 == 200 and any(r["name"] == DECOY and r["item_id"] is None for r in rows) and st2 == 200 and raw == [] and st3 == 200
              and all(s == 200 for s, _ in reads) and not leaks([blob]), leaks([blob])[:2])

        # ---- legacy path still works for the player
        pp.goto(f"{APP}?fluent=0#/c/{ch}")
        ok = P.wait(lambda: TRUE in pp.locator("#panel-inventory").inner_text(), 15000) if pp.locator(".tab").count() else False
        if not ok:
            pp.locator('.tab[data-tab="inventory"]').click()
            ok = P.wait(lambda: TRUE in pp.locator("#panel-inventory").inner_text(), 15000)
        check("H10 ?fluent=0: the identified herb shows on the legacy read path", ok)

        # ---- the second player on ?fluent=0: an UNidentified row shows the decoy, never the truth
        P2 = Sheet(br, pl2, tab="inventory")
        p2 = P2.page
        p2.goto(f"{APP}?fluent=0#/c/{ch2}")
        P2.wait(lambda: p2.locator(".tab").count() > 0)
        if DECOY not in p2.locator("#panel-inventory").inner_text():
            p2.locator('.tab[data-tab="inventory"]').click()
        ok = P2.wait(lambda: DECOY in p2.locator("#panel-inventory").inner_text(), 15000)
        check("H11 ?fluent=0: the second player's unidentified herb shows the decoy, and the page never holds the truth",
              ok and not any(s in p2.content() for s in SECRETS), p2.locator("#panel-inventory").inner_text()[:300])
        P2.ctx.close()

        # ---- DM Content: one source of truth (the Content editor); the DM Space button opens it; a republish keeps the options
        st, cc = dm.rpc("create_dm_content", p_type="item", p_campaign=camp, p_request_id=str(uuid.uuid4()), p_fields={
            "name": f"Ghostcap {RUN}", "summary": "A pale mushroom.", "definition": {
                "item": {"kind_id": "herbs_plants", "category_id": "plant-fungus", "stackable": True},
                "hidden": {"unidentified_name": "Pale mushroom", "identify_dc": 12, "identify_checks": ["nature", "herbalism-kit"],
                           "identify_reveal": ["name", "description"], "identify_auto": True, "identify_retry": "per_long_rest",
                           "fail_hint": "Probably edible.", "show_kind": False}}})
        assert st == 200, (st, cc)
        st, pub = dm.rpc("publish_dm_content", p_content=cc["id"])
        assert st == 200, (st, pub)
        ref1 = q(f"select v.catalog_ref from public.dm_content c join public.dm_content_versions v on v.id = c.published_version_id where c.id = '{cc['id']}'")
        cols = ("concat_ws('|', identify_dc, identify_checks::text, identify_reveal::text, identify_auto, identify_retry, fail_hint, "
                "coalesce(face_kind_id, '-'), unidentified_name)")
        before = q(f"select {cols} from public.item_secrets where item_id = '{ref1}'")
        st, direct = dm.rpc("set_item_identify_options", p_item=ref1, p_options={"identify_dc": 5})
        dp.goto(APP + "#/dm/overview")
        dp.goto(APP + "#/dm/hidden")
        D.wait(lambda: dp.locator("[data-give-item]").count() == 1)
        dp.select_option("[data-give-item]", ref1)
        dp.locator('[data-h="give-opts"]').click()
        ok = D.wait(lambda: dp.locator('.modal [data-ce-section="identify"]').count() == 1 and dp.locator(".modal [data-ce-focus-hint]").count() == 1)
        check("H12 DM Content: the direct option RPC is refused; DM Space opens the Content editor at Identification (with the New version hint)",
              st >= 400 and ok and dp.locator(".modal [data-o-save]").count() == 0, (st, direct))
        dp.locator('.modal [data-ce-act="newversion"]').click()
        D.wait(lambda: dp.locator('.modal [data-ce-act="publish"]').count() == 1)
        dp.locator('.modal [data-ce-act="publish"]').click()
        dp.locator(".modal [data-ok]").last.click()
        D.wait(lambda: q(f"select count(*) from public.dm_content_versions where content_id = '{cc['id']}' and status = 'published'") == "1"
               and q(f"select v.catalog_ref from public.dm_content c join public.dm_content_versions v on v.id = c.published_version_id where c.id = '{cc['id']}'") != ref1)
        ref2 = q(f"select v.catalog_ref from public.dm_content c join public.dm_content_versions v on v.id = c.published_version_id where c.id = '{cc['id']}'")
        after2 = q(f"select {cols} from public.item_secrets where item_id = '{ref2}'")
        after1 = q(f"select {cols} from public.item_secrets where item_id = '{ref1}'")
        check("H13 the editor round trip: New version + Publish without touching the form keeps every identification option (and the decoy)",
              ref2 != ref1 and after2 == before and after1 == before, (before, after2, after1))
        dp.keyboard.press("Escape")

        errs = [e for e in P.errors + D.errors if "Failed to load resource" not in e]
        check("Z1 no console errors", not errs, errs[:5])
        check("Z2 no request left this machine", not P.remote and not D.remote, (P.remote + D.remote)[:3])
        P.ctx.close(); D.ctx.close(); br.close()


if __name__ == "__main__":
    with iso.Isolated("HERB-IDENTIFY-UI") as t:
        run(t)
    report()
