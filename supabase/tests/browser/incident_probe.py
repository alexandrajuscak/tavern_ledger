"""Incident probe (docs/PRODUCTION_INCIDENT_REALTIME_TIMEOUTS.md): request and Realtime pressure of the character sheet under
production-like latency. LOCAL ONLY, synthetic user and characters inside isolation.Isolated. Diagnostic, not a pass/fail test
(the regression thresholds live in production_timeout_incident_test.py).

What it separates:
  * frontend timing   - wall time in the page until the sheet is usable / the picker shows results;
  * network delay     - Chromium network emulation (LATENCY_MS per request, default 150), requests still run in parallel;
  * server work       - which RPCs reached PostgREST (requestfinished) versus were cancelled in the browser (requestfailed);
  * Realtime          - WebSocket count, phx_join / phx_leave frames, postgres_changes bindings per join, realtime.subscription rows.

Limitations: local PostgreSQL is much faster than the Free compute (docs: ~105 ms vs 1-3 s per derived RPC), so times are
lower than production; request COUNTS and which character they belong to are the comparable numbers. A cancelled fetch
(requestfailed) may still have reached the server; the probe counts it separately and does not claim it saved server time.

Usage: LATENCY_MS=150 OUT=<file.json> python incident_probe.py
"""
import json
import os
import re
import time
from collections import Counter

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import ANON, API, RUN, Sheet, User, call

LAT = int(os.environ.get("LATENCY_MS", "150"))
OUT = os.environ.get("OUT")
HEAVY = {"get_character_derived_stats", "get_character_proficiencies", "get_character_spell_slots", "get_character_resources",
         "get_character_class_features", "get_character_class_summary", "get_character_spellbook", "get_character_states",
         "get_character_feats", "get_character_transformation"}
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


class Net:
    """Every Supabase REST/RPC request of one page: name, character, start, end, outcome."""

    def __init__(self, page):
        self.rows, self.ws, self.joins, self.leaves, self.bindings = [], 0, 0, 0, []
        self.by_req = {}
        page.on("request", self._req)
        page.on("requestfinished", lambda r: self._end(r, "ok"))
        page.on("requestfailed", lambda r: self._end(r, "cancelled" if "ABORT" in (r.failure or "").upper() else f"failed:{r.failure}"))
        page.on("websocket", self._ws)

    def _req(self, r):
        if "/rest/v1/" not in r.url:
            return
        m = re.search(r"/rest/v1/(rpc/)?([a-z_0-9]+)", r.url)
        name = m.group(2) if m else "?"
        body = r.post_data or ""
        ids = UUID.findall(r.url + " " + body)
        row = {"name": name, "rpc": bool(m and m.group(1)), "method": r.method, "char": ids[0] if ids else None,
               "t0": time.time(), "t1": None, "outcome": "pending"}
        self.by_req[id(r)] = row
        self.rows.append(row)

    def _end(self, r, outcome):
        row = self.by_req.get(id(r))
        if row:
            row["t1"], row["outcome"] = time.time(), outcome

    def _ws(self, ws):
        if "/realtime/" not in ws.url:
            return
        self.ws += 1

        def sent(payload):
            try:
                msg = json.loads(payload)
            except Exception:
                return
            ev = msg.get("event") if isinstance(msg, dict) else (msg[3] if isinstance(msg, list) and len(msg) > 3 else None)
            pl = msg.get("payload") if isinstance(msg, dict) else (msg[4] if isinstance(msg, list) and len(msg) > 4 else {})
            if ev == "phx_join":
                self.joins += 1
                self.bindings.append(len(((pl or {}).get("config") or {}).get("postgres_changes") or []))
            elif ev == "phx_leave":
                self.leaves += 1
        ws.on("framesent", sent)

    def mark(self):
        return len(self.rows)

    def since(self, i):
        return self.rows[i:]


def summary(rows, chars=None):
    heavy = [r for r in rows if r["name"] in HEAVY]
    out = {"requests": len(rows), "heavy_rpcs": len(heavy), "by_name": dict(Counter(r["name"] for r in rows)),
           "outcomes": dict(Counter(r["outcome"] for r in rows))}
    if chars:
        out["by_character"] = {label: {"requests": sum(1 for r in rows if r["char"] == cid),
                                       "heavy": sum(1 for r in heavy if r["char"] == cid),
                                       "heavy_completed": sum(1 for r in heavy if r["char"] == cid and r["outcome"] == "ok"),
                                       "cancelled": sum(1 for r in rows if r["char"] == cid and r["outcome"] == "cancelled")}
                               for label, cid in chars.items()}
    return out


def subs():
    return int(iso.psql("select count(*) from realtime.subscription"))


def emulate(sheet, page, latency=LAT, offline=False):
    cdp = sheet.ctx.new_cdp_session(page)
    cdp.send("Network.enable")
    cdp.send("Network.emulateNetworkConditions", {"offline": offline, "latency": latency, "downloadThroughput": -1, "uploadThroughput": -1})
    return cdp


USABLE = """() => { const r = document.querySelector('.sheet-root'); if (!r || r.classList.contains('is-stale')) return false;
  const a = document.querySelector('[data-derived="ac"]'); return !!a && !!a.textContent.trim() && a.textContent.trim() !== '…'; }"""


def run(t):
    res = {"latency_ms": LAT, "run": RUN}
    pl = User("incident")
    spec = (("A", [("fighter-phb", 5)]), ("B", [("wizard-phb", 5)]), ("C", [("cleric-phb", 3), ("fighter-phb", 2)]), ("D", [("rogue-phb", 2)]))
    chars = {k: pl.character(f"Incident {k} {RUN}", v, strength=14, dexterity=14, constitution=14, wisdom=14, intelligence=14) for k, v in spec}
    t.note(characters=list(chars.values()))
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(b, pl, tab="combat")
        page = s.page
        # test-only: remember the page's WebSockets so S6 can drop the Realtime connection like a network loss would
        s.ctx.add_init_script("(() => { const W = window.WebSocket; window.__tlSockets = []; window.WebSocket = function (...a) {"
                              " const w = new W(...a); window.__tlSockets.push(w); return w; }; window.WebSocket.prototype = W.prototype;"
                              " Object.assign(window.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 }); })();")
        page.reload(); page.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)
        net = Net(page)
        emulate(s, page)

        def open_usable(cid, timeout=60000):
            page.evaluate(f"location.hash = '#/c/{cid}'")
            page.wait_for_function(USABLE, timeout=timeout)

        # warm-up: shared reference data and the bundle cache
        open_usable(chars["D"])
        page.wait_for_timeout(3000)
        res["subscriptions_one_sheet"] = subs()

        # S1 one open (warm)
        i = net.mark(); t0 = time.time()
        open_usable(chars["A"])
        res["open_usable_s"] = round(time.time() - t0, 2)
        page.wait_for_timeout(4000)
        res["open"] = summary(net.since(i), {"A": chars["A"]})

        # S2 rapid A -> B -> C (150 ms apart), then C usable; what A and B still did
        open_usable(chars["D"]); page.wait_for_timeout(3000)
        i = net.mark(); j0 = net.joins; l0 = net.leaves; t0 = time.time()
        for k in ("A", "B", "C"):
            page.evaluate(f"location.hash = '#/c/{chars[k]}'")
            page.wait_for_timeout(150)
        page.wait_for_function(USABLE, timeout=60000)
        res["switch_c_usable_s"] = round(time.time() - t0, 2)
        page.wait_for_timeout(5000)
        res["switch"] = summary(net.since(i), {k: chars[k] for k in ("A", "B", "C")})
        res["switch"]["final_name_ok"] = page.evaluate(f"() => document.querySelector('.sheet-root')?.textContent.includes('Incident C {RUN}')")
        res["switch"]["joins"], res["switch"]["leaves"] = net.joins - j0, net.leaves - l0
        res["subscriptions_after_switch"] = subs()

        # S2b the same at a reading pace (700 ms apart): A and B mount and start their reads before the next switch
        open_usable(chars["D"]); page.wait_for_timeout(3000)
        i = net.mark(); t0 = time.time()
        for k in ("A", "B", "C"):
            page.evaluate(f"location.hash = '#/c/{chars[k]}'")
            page.wait_for_timeout(700)
        page.wait_for_function(USABLE, timeout=60000)
        res["switch_paced_c_usable_s"] = round(time.time() - t0, 2)
        page.wait_for_timeout(5000)
        res["switch_paced"] = summary(net.since(i), {k: chars[k] for k in ("A", "B", "C")})

        # S3 Background picker on C (Build tab)
        page.locator('.tab[data-tab="features"]').first.click(); page.wait_for_timeout(1500)
        i = net.mark(); t0 = time.time()
        page.locator('[data-action="bg-choose"]').first.click()
        try:
            page.wait_for_selector(".modal", timeout=20000); shell = round(time.time() - t0, 2)
        except Exception:
            shell = None
        try:
            page.wait_for_selector(".modal [data-bg-pick]", timeout=20000); listed = round(time.time() - t0, 2)
        except Exception:
            listed = None
        res["bg_picker"] = {"shell_s": shell, "results_s": listed, "count": page.locator(".modal [data-bg-pick]").count(),
                            **summary(net.since(i))}
        page.keyboard.press("Escape"); page.wait_for_timeout(800)

        # S4 own HP edit while a second session views the same character: heavy RPCs in both sessions
        s2 = Sheet(b, pl, tab="combat"); net2 = Net(s2.page); emulate(s2, s2.page)
        s2.page.evaluate(f"location.hash = '#/c/{chars['C']}'"); s2.page.wait_for_function(USABLE, timeout=60000)
        page.locator('.tab[data-tab="combat"]').first.click(); page.wait_for_timeout(2500)
        i1, i2 = net.mark(), net2.mark()
        hp = page.locator("#hp-card .hp-current").first
        hp.fill("33"); hp.press("Enter"); page.wait_for_timeout(5000)
        res["hp_edit"] = {"editor": summary(net.since(i1)), "viewer": summary(net2.since(i2))}

        # S5 a DELETE on ANOTHER character (D, not open) while C is open in two sessions
        # (set_character_proficiency enabled=false deletes the character_proficiencies row: replica identity default)
        st, _ = pl.rpc("set_character_proficiency", p_character=chars["D"], p_group="simple-weapons", p_item=None, p_enabled=True)
        page.wait_for_timeout(2500)
        i1, i2 = net.mark(), net2.mark()
        st2, _ = pl.rpc("set_character_proficiency", p_character=chars["D"], p_group="simple-weapons", p_item=None, p_enabled=False)
        page.wait_for_timeout(4000)
        res["foreign_delete"] = {"status": [st, st2], "viewer_of_C_1": summary(net.since(i1)), "viewer_of_C_2": summary(net2.since(i2))}
        # the same again (steady state: the sheets know their own rows by now), then a delete on C itself (must refresh)
        pl.rpc("set_character_proficiency", p_character=chars["D"], p_group="martial-weapons", p_item=None, p_enabled=True)
        page.wait_for_timeout(2500)
        i1, i2 = net.mark(), net2.mark()
        pl.rpc("set_character_proficiency", p_character=chars["D"], p_group="martial-weapons", p_item=None, p_enabled=False)
        page.wait_for_timeout(4000)
        res["foreign_delete_2"] = {"viewer_of_C_1": summary(net.since(i1)), "viewer_of_C_2": summary(net2.since(i2))}
        pl.rpc("set_character_proficiency", p_character=chars["C"], p_group="firearms", p_item=None, p_enabled=True)
        page.wait_for_timeout(2500)
        i1, i2 = net.mark(), net2.mark()
        pl.rpc("set_character_proficiency", p_character=chars["C"], p_group="firearms", p_item=None, p_enabled=False)
        page.wait_for_timeout(4000)
        res["own_delete"] = {"viewer_of_C_1": summary(net.since(i1)), "viewer_of_C_2": summary(net2.since(i2))}
        s2.close()
        page.wait_for_timeout(1500)

        # S6 Realtime connection drop (socket closed, the client reconnects by itself) x3: reloads, joins, subscription rows
        before = subs(); i = net.mark(); j0 = net.joins
        for _ in range(3):
            page.evaluate("() => window.__tlSockets.filter((w) => w.url.includes('/realtime/') && w.readyState === 1).forEach((w) => w.close())")
            page.wait_for_timeout(8000)
        page.wait_for_timeout(4000)
        res["reconnect"] = {"cycles": 3, "subs_before": before, "subs_after": subs(), "joins": net.joins - j0, **summary(net.since(i))}

        res["websockets_total"] = net.ws
        res["bindings_per_join"] = sorted(set(net.bindings))
        res["console_errors"] = [e for e in s.errors if "Failed to load resource" not in e][:10]
        s.close(); b.close()
    return res


if __name__ == "__main__":
    with iso.Isolated("DIAG incident probe") as t:
        out = run(t)
    print(json.dumps(out, indent=1))
    if OUT:
        with open(OUT, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=1)
