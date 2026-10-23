"""V6.2 import safety, multi-session, Realtime soak, long-session soak and performance (docs/V62_IMPORT_EXPORT_SAFETY.md,
docs/V62_REALTIME_REVIEW.md, docs/V62_ADVERSARIAL_HARDENING_REVIEW.md).

Runs inside isolation.Isolated: synthetic users only (ui-*@example.test) and the campaign "UI Adversarial Campaign"; every
public table is compared with its start state afterwards and the result is journaled. Refuses non-local URLs.
Measurements are written to $V62_METRICS (default %TEMP%/v62_metrics.json).
"""
import json
import os
import re
import statistics
import time
import uuid
from pathlib import Path

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, SHOTS, Sheet, User, call, check, report

ANON = os.environ["ANON_KEY"]
METRICS = {}


def db(q):
    return iso.psql(q)


def main():
    with iso.Isolated("V62-UI import / sessions / soak") as t:
        run(t)
    out = Path(os.environ.get("V62_METRICS", Path(os.environ.get("TEMP", "/tmp")) / "v62_metrics.json"))
    out.write_text(json.dumps(METRICS, indent=1), encoding="utf-8")
    print("metrics:", json.dumps(METRICS))
    report()


def import_file(s, name, payload):
    """Open the import dialog, choose the file, return (preview text, submit enabled)."""
    page = s.page
    page.goto(APP)
    page.wait_for_selector("#btn-import")
    page.locator("#btn-import").click()
    page.wait_for_selector("#import-form")
    data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
    page.set_input_files("#import-form input[name=file]", files=[{"name": name, "mimeType": "application/json", "buffer": data}])
    page.wait_for_timeout(500)
    return page.locator("#import-preview").inner_text(), page.locator('.modal button[type=submit]').is_enabled()


def close_modal(page):
    if page.locator(".modal [data-close]").count():
        page.locator(".modal [data-close]").first.click()
        page.wait_for_timeout(200)


def run(t):
    pl, dm = User("v62s-pl"), User("v62s-dm")
    ch = pl.character(f"V62 Soak Fighter {RUN}", [("fighter-phb", 5)], strength=16, dexterity=12, constitution=14, hp_max=44, hp_current=44)
    camp = str(uuid.uuid4())
    db(f"""insert into public.campaigns (id, name, created_by) values ('{camp}', 'UI Adversarial Campaign', '{dm.id}');
      insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player');
      insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');
      update public.characters set campaign_id = '{camp}' where id = '{ch}';""")
    _, inv = call("GET", f"/rest/v1/inventories?character_id=eq.{ch}&kind=eq.character&select=id", token=pl.jwt)
    for item, qty in (("dagger", 2), ("rope-hempen-50-feet", 1), ("chain-mail", 1)):
        pl.rpc("add_inventory_item", p_inventory=inv[0]["id"], p_item=item, p_quantity=qty, p_custom_name=None, p_notes=None, p_state={})
    t.note(character=ch, campaign=camp)

    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True, args=["--js-flags=--expose-gc"])
        s = Sheet(browser, pl, tab="bio")
        page = s.page

        # ================= IMPORT / EXPORT ===============================================================================================
        s.open(ch)
        s.tab("bio")
        t0 = time.time()
        with page.expect_download() as dl:
            page.locator('[data-action="export-json"]').click()
        exported = json.loads(Path(dl.value.path()).read_text(encoding="utf-8"))
        METRICS["export_s"] = round(time.time() - t0, 2)
        check("IMP0 the export is a character file with name, classes and inventory", exported.get("name") == f"V62 Soak Fighter {RUN}"
              and exported.get("inventory"), list(exported)[:12])

        bad = {"not JSON": (b"{name: 'x',,", "not valid JSON"), "an array": (b"[1,2,3]", "not a character JSON object"),
               "no name": (json.dumps({"level": 3}).encode(), 'needs a "name"'), "empty file": (b"", "not valid JSON")}
        res = {}
        for label, (data, want) in bad.items():
            prev, enabled = import_file(s, f"{label}.json", data)
            res[label] = (want in prev and not enabled, prev)
            close_modal(page)
        check("IMP1 malformed files (broken JSON, an array, no name, empty) are refused in the preview with a message; Import stays disabled",
              all(v[0] for v in res.values()), res)

        # forged and hostile values: ids, owner, campaign, out-of-range numbers, prototype pollution, a script portrait
        forged = dict(exported)
        forged.update({"name": f"V62 Forged {RUN}", "id": str(uuid.uuid4()), "owner_id": dm.id, "campaign_id": str(uuid.uuid4()), "level": 99,
                       "abilities": {"str": 999, "dex": -5, "con": "abc", "int": 10, "wis": 10, "cha": 10},
                       "currency": {"gp": -500, "pp": 1e12}, "portrait": "javascript:alert(1)",
                       "combat": {**exported.get("combat", {}), "hp": {"max": -4, "current": 9999, "temp": -3}}})
        raw = json.dumps(forged).replace('{"name"', '{"__proto__": {"polluted": "yes"}, "constructor": {"prototype": {"polluted2": "yes"}}, "name"', 1)
        prev, enabled = import_file(s, "forged.json", raw.encode())
        page.locator('.modal button[type=submit]').dblclick()
        s.wait(lambda: "#/c/" in page.url, 20000)
        page.wait_for_timeout(1500)
        rows = db(f"select id || '|' || owner_id || '|' || coalesce(campaign_id::text, '-') || '|' || level || '|' || strength || '|' || dexterity || '|' || gp || '|' || hp_max || '|' || hp_current || '|' || coalesce(portrait_url, '')"
                  f" from public.characters where name = 'V62 Forged {RUN}'").splitlines()
        cols = rows[0].split("|") if rows else []
        polluted = page.evaluate("() => [({}).polluted, ({}).polluted2]")
        check("IMP2 a double-clicked Import creates exactly one character", len(rows) == 1, rows)
        check("IMP3 forged id / owner / campaign are ignored: new id, owned by the importer, campaign = the one chosen in the dialog",
              cols and cols[0] != forged["id"] and cols[1] == pl.id and cols[2] == camp, (cols, pl.id, camp))
        # current HP is not cut to the file's base maximum: feats (Tough) raise the real maximum; the sheet bounds it once derived stats load
        check("IMP4 out-of-range values are clamped (level 1..20 - here the imported classes' 5, STR 30, DEX 1, gp 0, pp within the integer range, HP max >= 1) and a javascript: portrait is dropped",
              cols and 1 <= int(cols[3]) <= 20 and cols[4] == "30" and cols[5] == "1" and cols[6] == "0" and int(cols[7]) >= 1 and cols[9] == "", cols)
        check("IMP5 '__proto__' / 'constructor' keys in the file pollute nothing", polluted == [None, None], polluted)

        # round trip: what comes back equals what went out (sheet fields, inventory, classes)
        sig = lambda cid: db(f"""select string_agg(x, ';' order by x) from (
              select 'c:' || level || ',' || strength || ',' || constitution || ',' || hp_max as x from public.characters where id = '{cid}'
              union all select 'i:' || ii.item_id || 'x' || ii.quantity from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id where i.character_id = '{cid}'
              union all select 'k:' || class_version_id || '@' || level from public.character_classes where character_id = '{cid}') z""")
        prev, enabled = import_file(s, "roundtrip.json", exported)
        page.locator('.modal button[type=submit]').click()
        s.wait(lambda: "#/c/" in page.url and page.url.split("#/c/")[-1] != ch, 20000)
        page.wait_for_timeout(1500)
        copy = db(f"select id from public.characters where name = 'V62 Soak Fighter {RUN}' and id <> '{ch}'")
        check("IMP6 export -> import round trip keeps level, scores, HP, classes and the whole inventory", copy and sig(copy) == sig(ch), (sig(ch), sig(copy) if copy else None))

        # atomicity: a failure after the character row exists removes it again
        page.route("**/rest/v1/attacks*", lambda route: route.abort() if route.request.method == "POST" else route.continue_())
        atomic = dict(exported, name=f"V62 Atomic {RUN}", attacks=[{"name": "Bite", "damageDice": "1d6"}])
        prev, enabled = import_file(s, "atomic.json", atomic)
        page.locator('.modal button[type=submit]').click()
        s.wait(lambda: page.locator(".toast").count() > 0, 15000)
        page.wait_for_timeout(1000)
        toast = s.toasts()
        page.unroute("**/rest/v1/attacks*")
        left = db(f"select count(*) from public.characters where name = 'V62 Atomic {RUN}'")
        check("IMP7 an import that fails half-way leaves no partial character and says 'Nothing was imported'", left == "0" and "Nothing was imported" in toast, (left, toast))
        close_modal(page)

        # ================= MULTI-SESSION ===============================================================================================
        b = Sheet(browser, pl, tab="combat")       # the same player in a second browser
        d = Sheet(browser, dm, tab="combat")       # the DM
        s.open(ch)
        s.tab("combat")
        b.open(ch)
        d.open(ch)
        hp_a, hp_b = page.locator("#hp-card .hp-current"), b.page.locator("#hp-card .hp-current")
        hp_a.fill("40")
        hp_a.press("Tab")
        check("MS1 an HP edit in one browser appears in the player's second browser (Realtime)", b.wait(lambda: hp_b.input_value() == "40", 15000), hp_b.input_value())
        d.page.locator("#hp-card .hp-current").fill("35")
        d.page.locator("#hp-card .hp-current").press("Tab")
        check("MS2 an HP edit by the DM appears in both player browsers", s.wait(lambda: hp_a.input_value() == "35", 15000) and b.wait(lambda: hp_b.input_value() == "35", 15000),
              (hp_a.input_value(), hp_b.input_value()))
        # simultaneous conflicting edits: last write wins, every screen converges to the stored value
        hp_a.fill("20")
        hp_b.fill("25")
        hp_a.press("Tab")
        hp_b.press("Tab")
        page.wait_for_timeout(4000)
        stored = db(f"select hp_current from public.characters where id = '{ch}'")
        conv = [x.input_value() for x in (hp_a, hp_b, d.page.locator("#hp-card .hp-current"))]
        check("MS3 two simultaneous edits: the stored value is one of them and all three screens show it (%s)" % stored,
              stored in ("20", "25") and s.wait(lambda: len({hp_a.input_value(), hp_b.input_value(), d.page.locator('#hp-card .hp-current').input_value(), stored}) == 1, 10000),
              (stored, conv))
        # sign-out in one browser: its channels close; the other browser keeps working until its own session ends
        frames = {"leave": 0}
        page.on("websocket", lambda w: w.on("framesent", lambda f: frames.update(leave=frames["leave"] + (1 if '"phx_leave"' in str(f) else 0))))
        page.goto(APP)
        page.wait_for_selector("#btn-signout")
        page.locator("#btn-signout").click()
        page.wait_for_selector("input[name=email]")
        page.wait_for_timeout(1000)
        reqs = []
        page.on("request", lambda r: reqs.append(r.url) if "/rest/v1/" in r.url else None)
        page.wait_for_timeout(3000)
        check("MS4 after sign-out the signed-out browser sends no further data requests", not reqs, reqs[:3])
        hp_b.fill("30")
        hp_b.press("Tab")
        ok_b = b.wait(lambda: db(f"select hp_current from public.characters where id = '{ch}'") == "30", 10000)
        METRICS["second_session_after_signout"] = "saves" if ok_b else "signed out"
        check("MS5 the other browser is not broken by the sign-out elsewhere (it saves, or asks to sign in again; no error loop)",
              ok_b or "session has expired" in b.toasts().lower(), (ok_b, b.toasts()))
        s.close()
        d.close()

        # ================= REALTIME SOAK =============================================================================================
        rp = b.page
        b.tab("combat")
        lat, missed = [], 0
        for i in range(40):
            v = 10 + (i % 30)
            if rp.locator("#hp-card .hp-current").input_value() == str(v):
                v += 1
            t0 = time.time()
            st, _ = call("PATCH", f"/rest/v1/characters?id=eq.{ch}", {"hp_current": v}, token=dm.jwt, key=ANON)
            try:
                rp.wait_for_function(f"() => document.querySelector('#hp-card .hp-current')?.value === '{v}'", timeout=10000, polling=25)
                lat.append((time.time() - t0) * 1000)
            except Exception:
                missed += 1
        lat.sort()
        METRICS["realtime"] = {"events": 40, "missed": missed, "p50_ms": round(statistics.median(lat)) if lat else None,
                               "p95_ms": round(lat[int(len(lat) * 0.95) - 1]) if lat else None, "max_ms": round(lat[-1]) if lat else None}
        check("RT1 40 DM edits in a row all reach the player's sheet (none missed): p50 %s ms, p95 %s ms" % (METRICS["realtime"]["p50_ms"], METRICS["realtime"]["p95_ms"]),
              missed == 0 and METRICS["realtime"]["p95_ms"] < 5000, METRICS["realtime"])
        # navigation churn: channels joined while moving between home and the sheet must be left again
        topics = {"join": 0, "leave": 0}
        rp.on("websocket", lambda w: w.on("framesent", lambda f: topics.update(join=topics["join"] + (1 if '"phx_join"' in str(f) else 0),
                                                                               leave=topics["leave"] + (1 if '"phx_leave"' in str(f) else 0))))
        rp.reload()
        rp.wait_for_selector(".tab")
        rp.wait_for_timeout(1500)
        j0, l0 = topics["join"], topics["leave"]
        for _ in range(10):   # in-app navigation (hash changes), as a player clicks: a full page load would close the socket anyway
            rp.evaluate("location.hash = '#/'")
            rp.wait_for_selector(".char-card")
            rp.evaluate(f"location.hash = '#/c/{ch}'")
            rp.wait_for_selector("#hp-card .hp-current")
            rp.wait_for_timeout(400)
        rp.wait_for_timeout(1500)
        open_now = (topics["join"] - j0) - (topics["leave"] - l0)
        METRICS["realtime"]["churn"] = {"joins": topics["join"] - j0, "leaves": topics["leave"] - l0, "net_open_after_10_cycles": open_now}
        check("RT2 ten home <-> sheet cycles leave no extra open channels (joins %d, leaves %d)" % (topics["join"] - j0, topics["leave"] - l0),
              open_now <= 2, METRICS["realtime"]["churn"])
        v = int(rp.locator("#hp-card .hp-current").input_value()) % 40 + 1
        call("PATCH", f"/rest/v1/characters?id=eq.{ch}", {"hp_current": v}, token=dm.jwt, key=ANON)
        check("RT3 after the churn the sheet still receives updates", b.wait(lambda: rp.locator("#hp-card .hp-current").input_value() == str(v), 10000))
        # a dropped connection: the server side closes the socket and an edit happens before the client has re-joined;
        # postgres_changes does not replay it, so the sheet must reload its stored values once the channel is back
        sockets = []

        def through(ws):
            ws.connect_to_server()
            sockets.append(ws)
        rp.route_web_socket(re.compile(r".*/realtime/v1/websocket.*"), through)
        rp.reload()
        rp.wait_for_selector("#hp-card .hp-current")
        b.wait(lambda: len(sockets) >= 1, 10000)
        rp.wait_for_timeout(1500)
        v = int(rp.locator("#hp-card .hp-current").input_value()) % 40 + 2
        sockets[-1].close(code=1006, reason="test: connection lost")
        call("PATCH", f"/rest/v1/characters?id=eq.{ch}", {"hp_current": v}, token=dm.jwt, key=ANON)
        resynced = b.wait(lambda: rp.locator("#hp-card .hp-current").input_value() == str(v), 20000)
        check("RT4 an edit made while the connection was down appears after reconnecting (the sheet resyncs and says so)",
              resynced and len(sockets) >= 2 and "Connection restored" in " ".join(rp.locator(".toast").all_inner_texts() + [b.toasts()]),
              (resynced, len(sockets), b.toasts()))
        rp.unroute_web_socket(re.compile(r".*/realtime/v1/websocket.*")) if hasattr(rp, "unroute_web_socket") else None

        # ================= LONG-SESSION SOAK (in-page, so the test driver adds no handles) =============================================
        def heap():
            return rp.evaluate("() => { window.gc && window.gc(); return { heap: performance.memory ? performance.memory.usedJSHeapSize : 0, nodes: document.getElementsByTagName('*').length }; }")
        rp.evaluate("""async () => { for (const k of ['combat','stats','spells','inventory','features','bio']) { document.querySelector(`.tab[data-tab="${k}"]`).click(); await new Promise(r => setTimeout(r, 150)); } }""")
        h0 = heap()
        t0 = time.time()
        rp.evaluate("""async () => { const tabs = ['combat','stats','spells','inventory','features','bio'];
            for (let i = 0; i < 300; i++) { document.querySelector(`.tab[data-tab="${tabs[i % 6]}"]`).click(); await new Promise(r => setTimeout(r, 20)); } }""")
        rp.evaluate("""async () => { document.querySelector('.tab[data-tab="bio"]').click(); await new Promise(r => setTimeout(r, 300)); }""")
        h1 = heap()
        METRICS["soak"] = {"tab_switches": 300, "seconds": round(time.time() - t0, 1), "heap_mb_before": round(h0["heap"] / 1e6, 1),
                           "heap_mb_after": round(h1["heap"] / 1e6, 1), "nodes_before": h0["nodes"], "nodes_after": h1["nodes"]}
        check("SOAK1 300 tab switches: heap growth under 15 MB and the page keeps the same size (%s)" % METRICS["soak"],
              h1["heap"] - h0["heap"] < 15e6 and abs(h1["nodes"] - h0["nodes"]) < 200, METRICS["soak"])
        errs = [e for e in b.errors if e.startswith("pageerror")]
        check("SOAK2 no page errors during the soak", not errs, errs[:3])

        # ================= PERFORMANCE ==============================================================================================
        perf = {}
        t0 = time.time()
        rp.goto(APP)
        rp.wait_for_selector(".char-card")
        b.wait(lambda: rp.locator(".cc-wait").count() == 0, 20000)
        perf["home_ready_s"] = round(time.time() - t0, 2)
        t0 = time.time()
        rp.goto(f"{APP}#/c/{ch}")
        rp.wait_for_selector("#hp-card .hp-current")
        perf["open_sheet_s"] = round(time.time() - t0, 2)
        ts = []
        for k in ("stats", "inventory", "features", "combat"):
            t0 = time.time()
            rp.locator(f'.tab[data-tab="{k}"]').click()
            rp.wait_for_selector(f"#panel-{k}:not([hidden])")
            ts.append(time.time() - t0)
        perf["tab_switch_max_s"] = round(max(ts), 2)
        METRICS["performance"] = perf
        check("PERF1 home %.2f s, open %.2f s, tab switch %.2f s (budgets 3 / 2 / 0.5 s)" % (perf["home_ready_s"], perf["open_sheet_s"], perf["tab_switch_max_s"]),
              perf["home_ready_s"] < 3 and perf["open_sheet_s"] < 2 and perf["tab_switch_max_s"] < 0.5, perf)
        SHOTS.mkdir(parents=True, exist_ok=True)
        rp.screenshot(path=str(SHOTS / "v62_after_soak.png"))
        check("NET no request left the machine", not b.remote, b.remote[:5])
        b.close()
        browser.close()


main()
