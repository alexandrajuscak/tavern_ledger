"""Party-wide identification (20261114000300; docs/HIDDEN_DM_DATA.md "Identification is shared with the party"). LOCAL ONLY,
synthetic users. The party-share checks RA0-RA3 of the former combined R-A test (metric and weapon cards:
metric_weapon_cards_ui_test.py).

0. A share that found B busy waits in party_share_pending; B's sheet applies it on open (sync_party_knowledge), counts only.
1. A and B hold the same disguised herb. B's sheet is open (Inventory) and records every REST body, websocket frame, DOM text and
   browser storage value. A identifies the herb (examine, auto reveal): B's open sheet shows the true name live, no reload.
   REQUIRED leak check: a second secret item that nobody knows never reaches B in any form; the herb's truth did not reach B
   before A identified it.
Usage: APP_URL=... python party_knowledge_ui_test.py   (run_browser_local.sh sets the environment)
"""
import re
import time
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import RUN, Sheet, User, call, check, report

q = iso.psql
HERB, HERB_DESC = f"Sunwort {RUN}", f"Hums at dawn {RUN}"
GHOST, GHOST_DESC = f"Ghost Lily {RUN}", f"Whispers secrets {RUN}"
MOSS = f"Moonmoss {RUN}"
BARK = f"Silverbark {RUN}"
GIFT = f"Gift Lantern {RUN}"


def storage(page):
    return page.evaluate("""() => { const out = [];
        for (const s of [localStorage, sessionStorage]) for (let i = 0; i < s.length; i++) { const k = s.key(i); out.push(k + '=' + s.getItem(k)); }
        return out; }""")


def leaks(texts, secrets):
    return [t[:160] for t in texts if any(s in t for s in secrets)]


def homebrew(dm, camp, name, kind, desc, extra=None, stats=None):
    d = {"name": name, "kind_id": kind, "campaign_id": camp, "description": desc}
    d.update(extra or {})
    st, it = dm.rpc("create_homebrew_item", p_request_id=str(uuid.uuid4()), p_definition=d, p_stats=stats or {})
    assert st == 200, (st, it)
    return it["id"]


def inv(user, cid):
    _, rows = call("GET", f"/rest/v1/inventories?character_id=eq.{cid}&kind=eq.character&select=id", token=user.jwt)
    return rows[0]["id"]


def run():
    dm, pa, pb = User("pkdm"), User("pkpa"), User("pkpb")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'PK Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pa.id}', 'player'), ('{camp}', '{pb.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    cha = pa.character(f"PK Alpha {RUN}", [("wizard-phb", 1)], dexterity=16)
    chb = pb.character(f"PK Beta {RUN}", [("fighter-phb", 1)], strength=16)
    q(f"update public.characters set campaign_id = '{camp}' where id in ('{cha}', '{chb}');"
      f"insert into public.character_governance (character_id, setup_complete) values ('{cha}', true), ('{chb}', true);")
    # disguised herb (auto reveal on DC 10) for A and B; a secret lily for B that nobody ever learns
    herb = homebrew(dm, camp, HERB, "herbs_plants", HERB_DESC, {"category_id": "plant-flower", "stackable": True})
    assert dm.rpc("set_item_identify_options", p_item=herb, p_options={"unidentified_name": "Dry stalk", "identify_dc": 10, "identify_auto": True})[0] == 200
    ghost = homebrew(dm, camp, GHOST, "herbs_plants", GHOST_DESC, {"category_id": "plant-flower", "stackable": True})
    assert dm.rpc("set_item_identify_options", p_item=ghost, p_options={"unidentified_name": "Pale flower", "identify_dc": 30})[0] == 200
    assert dm.rpc("dm_give_item", p_item=herb, p_characters=[cha, chb], p_quantity=1, p_identified=False)[0] == 200
    assert dm.rpc("dm_give_item", p_item=ghost, p_characters=[chb], p_quantity=1, p_identified=False)[0] == 200
    # a share that found B busy (round 2, B1): A learned the moss while sharing was off; B only has a pending row, which B's own
    # sheet applies when it opens (sync_party_knowledge)
    moss = homebrew(dm, camp, MOSS, "herbs_plants", "Glows faintly", {"category_id": "plant-flower", "stackable": True})
    assert dm.rpc("set_item_identify_options", p_item=moss, p_options={"unidentified_name": "Damp moss"})[0] == 200
    assert dm.rpc("dm_give_item", p_item=moss, p_characters=[cha, chb], p_quantity=1, p_identified=False)[0] == 200
    assert dm.rpc("set_campaign_identification_sharing", p_campaign=camp, p_on=False)[0] == 200
    assert dm.rpc("dm_set_item_knowledge", p_item=moss, p_characters=[cha], p_reveal=["all"], p_mode="raise", p_campaign=camp)[0] == 200
    q(f"insert into public.campaign_item_rules (campaign_id, share_identification) values ('{camp}', true) on conflict (campaign_id) do update set share_identification = true;"
      f"insert into public.party_share_pending (campaign_id, target_character_id, item_id, state, revealed, source_character_id)"
      f" values ('{camp}', '{chb}', '{moss}', 'identified', '{{}}', '{cha}');")
    ia = inv(pa, cha)
    # RA2b: a second herb A identifies while B's inventory read is held in flight (deterministic race)
    bark = homebrew(dm, camp, BARK, "herbs_plants", "Shines", {"category_id": "plant-flower", "stackable": True})
    assert dm.rpc("set_item_identify_options", p_item=bark, p_options={"unidentified_name": "Dull bark", "identify_dc": 10, "identify_auto": True})[0] == 200
    assert dm.rpc("dm_give_item", p_item=bark, p_characters=[cha, chb], p_quantity=1, p_identified=False)[0] == 200

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        # ---- 1. party share, seen by B ----------------------------------------------------------------------------------------
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
        B.wait(lambda: "Dry stalk" in bp.locator("#panel-inventory").inner_text())
        B.wait(lambda: MOSS in bp.locator("#panel-inventory").inner_text(), timeout=20000)
        syncs = [b for b in seen["bodies"] if '"applied"' in b and '"pending"' in b]
        left = q(f"select count(*) from public.party_share_pending where target_character_id = '{chb}'").strip()
        check("RA0 sheet open calls sync_party_knowledge: B's pending share is applied (the moss shows its true name), the answer is counts only",
              MOSS in bp.locator("#panel-inventory").inner_text() and syncs and all(MOSS not in b for b in syncs) and left == "0",
              (syncs[:2], left))
        before = seen["bodies"] + seen["frames"] + [bp.locator("body").inner_text()] + storage(bp)
        check("RA1 before: B sees the herb's decoy only; its truth reached B nowhere", "Dry stalk" in bp.locator("#panel-inventory").inner_text()
              and not leaks(before, (HERB, HERB_DESC)), leaks(before, (HERB, HERB_DESC)))
        _, rows = call("GET", f"/rest/v1/inventory_items?inventory_id=eq.{ia}&item_id=eq.{herb}&select=id", token=pa.jwt)
        st, ex = pa.rpc("examine_inventory_item", p_inventory_item=rows[0]["id"], p_check="nature", p_roll=15, p_request=str(uuid.uuid4()))
        live = B.wait(lambda: HERB in bp.locator("#panel-inventory").inner_text(), timeout=20000)
        check("RA2 A identifies the herb (examine, auto) -> B's open sheet shows the true name live (party share, no reload)",
              st == 200 and ex.get("status") == "succeeded" and live, (st, ex, bp.locator("#panel-inventory").inner_text()[:300]))
        st, cat = call("GET", f"/rest/v1/items?id=eq.{ghost}&select=id,name", token=pb.jwt)
        st2, kn = pb.rpc("get_character_item_knowledge", p_character=chb)
        everything = seen["bodies"] + seen["frames"] + [bp.locator("body").inner_text(), bp.content(), str(cat), str(kn)] + storage(bp)
        check("RA3 REQUIRED the never-identified lily: no REST body, websocket frame, DOM, page source, storage or REST / RPC answer of B carries its truth",
              not leaks(everything, (GHOST, GHOST_DESC)) and cat == [] and "Pale flower" in bp.locator("#panel-inventory").inner_text(),
              leaks(everything, (GHOST, GHOST_DESC)))
        # ---- RA2b deterministic race: B's next inventory read is answered with data from BEFORE A's identify; the identify
        # commits (and its revision event reaches B) while that read is still in flight. The sheet must read again.
        armed = {"on": True, "held": 0}

        def hold_read(route):
            body = route.request.post_data or ""
            if not (armed["on"] and "inventory_bundle" in body):
                route.continue_()
                return
            armed["on"] = False
            resp = route.fetch()                       # executed now: the server answers with the pre-identify state
            _, rows2 = call("GET", f"/rest/v1/inventory_items?inventory_id=eq.{ia}&item_id=eq.{bark}&select=id", token=pa.jwt)
            armed["ex"] = pa.rpc("examine_inventory_item", p_inventory_item=rows2[0]["id"], p_check="nature", p_roll=15,
                                 p_request=str(uuid.uuid4()))
            time.sleep(1.5)                            # the revision event arrives while this read is still in flight
            armed["held"] += 1
            route.fulfill(response=resp)
        bp.route("**/rest/v1/rpc/get_character_reads", hold_read)
        q(f"insert into public.character_revisions (character_id, source_table) values ('{chb}', 'inventory_items');")   # starts a read
        live2 = B.wait(lambda: BARK in bp.locator("#panel-inventory").inner_text(), timeout=15000)
        bp.unroute("**/rest/v1/rpc/get_character_reads")
        check("RA2b deterministic race: an identify that commits while B's inventory read is in flight still shows on B's sheet (read again)",
              armed["held"] == 1 and armed.get("ex", (0,))[0] == 200 and live2,
              (armed, bp.locator("#panel-inventory").inner_text()[:300]))
        B.close()

        # ---- RA2c the Realtime gap (root cause of the intermittent RA2): 'SUBSCRIBED' comes before Realtime delivers postgres
        # changes ("Subscribed to PostgreSQL", seconds later when Realtime is cold). A change committed in that gap is never
        # delivered. Emulated deterministically: B's sheet channel gets no change frames until its "Subscribed to PostgreSQL"
        # frame, which is held while the DM gives B an item. The sheet must catch up once changes are live.
        B2 = Sheet(br, pb, tab="inventory")
        b2 = B2.page
        gap = {"hold": True, "held": None, "ws": None, "dropped": 0}

        def ws_route(ws):
            server = ws.connect_to_server()
            gap["ws"] = ws

            def from_server(msg):
                m = msg if isinstance(msg, str) else str(msg)
                if gap["hold"] and "realtime:sheet-" in m and "Subscribed to PostgreSQL" in m:
                    gap["held"] = msg
                    return
                if gap["hold"] and "realtime:sheet-" in m and '"postgres_changes"' in m and '"data"' in m:
                    gap["dropped"] += 1   # not live yet: Realtime would not have delivered it
                    return
                ws.send(msg)
            server.on_message(from_server)
            ws.on_message(lambda msg: server.send(msg))
        b2.route_web_socket(re.compile(r".*/realtime/v1/websocket.*"), ws_route)
        b2.reload()                                   # the app opened its one Realtime socket at sign-in: open it again, routed
        b2.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)
        B2.open(chb)
        B2.wait(lambda: gap["held"] is not None and "Pale flower" in b2.locator("#panel-inventory").inner_text(), timeout=20000)
        gift = homebrew(dm, camp, GIFT, "herbs_plants", "A small lantern", {"category_id": "plant-flower", "stackable": True})
        gst, gres = dm.rpc("dm_give_item", p_item=gift, p_characters=[chb], p_quantity=1, p_identified=True)
        b2.wait_for_timeout(1500)   # the change frame (if any) arrives inside the gap and is not delivered
        gap["hold"] = False
        gap["ws"].send(gap["held"])  # Realtime: changes are live now
        live3 = B2.wait(lambda: GIFT in b2.locator("#panel-inventory").inner_text(), timeout=15000)
        check("RA2c Realtime gap: a change committed after the sheet opened but before Realtime delivers changes still shows (catch-up once live)",
              gap["held"] is not None and gst == 200 and live3, (gap["dropped"], gst, b2.locator("#panel-inventory").inner_text()[:300]))
        B2.close()
        br.close()
    report()


if __name__ == "__main__":
    run()
