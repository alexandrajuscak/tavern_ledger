"""The Realtime gap of an opening sheet (js/store.js subscribeCharacterFluent onLive, js/sheet.js catchUpSoon). LOCAL ONLY.

supabase-js reports 'SUBSCRIBED' before Realtime delivers postgres changes; Realtime confirms that later with a system message
"Subscribed to PostgreSQL" (seconds later on a cold Realtime). A change committed in between is never delivered.
G1: emulated deterministically with route_web_socket: the player's sheet channel gets no change frames until its "Subscribed to
    PostgreSQL" frame, which is held while the DM gives the character an item. Once released, the sheet must show the item.
G2: the open does exactly ONE catch-up revision read (review m1: open, live and reconnect share one debounce).
G3: a reconnect (the page-side socket is closed; supabase-js reconnects and Realtime sends the system message again) does
    exactly ONE catch-up revision read.
Usage: APP_URL=... python realtime_gap_ui_test.py   (run_browser_local.sh sets the environment)
"""
import re
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import RUN, Sheet, User, check, report

q = iso.psql
GIFT = f"Gap Lantern {RUN}"


def run():
    dm, pb = User("gapdm"), User("gappb")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'Gap Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pb.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    chb = pb.character(f"Gap Beta {RUN}", [("fighter-phb", 1)], strength=16)
    q(f"update public.characters set campaign_id = '{camp}' where id = '{chb}';"
      f"insert into public.character_governance (character_id, setup_complete) values ('{chb}', true);")

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        B = Sheet(br, pb, tab="inventory")
        bp = B.page
        gap = {"hold": True, "held": None, "ws": None, "dropped": 0, "joins": 0}
        reads = []   # bodies of the sheet's revision catch-up reads (get_character_reads with characters + revisions)
        bp.on("request", lambda r: reads.append(r.post_data or "") if "/rpc/get_character_reads" in r.url
              and '"revisions"' in (r.post_data or "") and '"characters"' in (r.post_data or "") else None)

        def ws_route(ws):
            server = ws.connect_to_server()
            gap["ws"] = ws
            gap["joins"] += 1

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
        bp.route_web_socket(re.compile(r".*/realtime/v1/websocket.*"), ws_route)
        bp.reload()                                   # the app opened its one Realtime socket at sign-in: open it again, routed
        bp.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)
        B.open(chb)
        B.wait(lambda: gap["held"] is not None and bp.locator("#panel-inventory").count() == 1, 20000)
        st, it = dm.rpc("create_homebrew_item", p_request_id=str(uuid.uuid4()), p_definition={
            "name": GIFT, "kind_id": "gear", "campaign_id": camp, "description": "A small lantern"}, p_stats={})
        gst, _ = dm.rpc("dm_give_item", p_item=it["id"], p_characters=[chb], p_quantity=1, p_identified=True)
        bp.wait_for_timeout(1500)                     # the change frame (if any) arrives inside the gap and is not delivered
        reads_before = len(reads)
        gap["hold"] = False
        gap["ws"].send(gap["held"])                   # Realtime: changes are live now
        live = B.wait(lambda: GIFT in bp.locator("#panel-inventory").inner_text(), 15000)
        check("G1 Realtime gap: an item given after the sheet opened but before Realtime delivers changes still shows (catch-up once live)",
              st == 200 and gst == 200 and live, (gap["dropped"], gst, bp.locator("#panel-inventory").inner_text()[:300]))
        bp.wait_for_timeout(4000)                     # any second read would come within the shared 1.5 s debounce + fallback
        open_reads = len(reads) - reads_before
        check("G2 the open does exactly ONE catch-up revision read once live (one shared debounce)", open_reads == 1 and reads_before == 0,
              (reads_before, open_reads))

        # ---- G3 reconnect: close the page-side socket; supabase-js reconnects (new routed socket), rejoins the channel
        n0, joins0 = len(reads), gap["joins"]
        gap["ws"].close()
        rejoined = B.wait(lambda: gap["joins"] > joins0, 30000)
        bp.wait_for_timeout(9000)                     # SUBSCRIBED + "Subscribed to PostgreSQL" + debounce + the 6 s fallback
        rec_reads = len(reads) - n0
        check("G3 a reconnect does exactly ONE catch-up revision read (resync and live share the debounce; the read comes after live)",
              rejoined and rec_reads == 1, (rejoined, rec_reads, gap["joins"]))
        print(f"   measure: catch-up reads open={open_reads} reconnect={rec_reads}")
        B.close()
        br.close()
    report()


if __name__ == "__main__":
    run()
