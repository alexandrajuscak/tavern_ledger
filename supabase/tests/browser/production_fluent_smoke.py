"""Production smoke test of the fluent read release (docs/FLUENCY_PRODUCTION_DEPLOYMENT.md §Smoke).

Runs against the LIVE GitHub Pages site with SYNTHETIC accounts only (scripts/fluent/smoke_users.sql: smoke-fl-*@example.test,
their own campaign and two characters). Never opens a real player's character. The password comes from the environment
(SMOKE_PW) and is never printed. Output: PASSED/FAILED lines and one JSON summary with counts and timings (no player data).
Env: SMOKE_RUN, SMOKE_PW, FLAG ('1' = ?fluent=1, '' = site default), PROD_APP (default the production URL), OUT (json).
"""
import json
import os
import re
import time

from playwright.sync_api import sync_playwright

APP = os.environ.get("PROD_APP", "https://alexandrajuscak.github.io/tavern_ledger/")
RUN, PW = os.environ["SMOKE_RUN"], os.environ["SMOKE_PW"]
FLAG = os.environ.get("FLAG", "1")
QS = f"?fluent={FLAG}" if FLAG else ""
EMAIL = lambda kind: f"smoke-fl-{kind}-{RUN}@example.test"
HERO, SOLO = f"Smoke FL Hero {RUN}", f"Smoke FL Solo {RUN}"
SECRETS = ("Smoke hidden curse", "Smoke secret note", "unrevealed")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
USABLE = """() => { const r = document.querySelector('.sheet-root'); if (!r || r.classList.contains('is-stale')) return false;
  const a = document.querySelector('[data-derived="ac"]'); return !!a && !!a.textContent.trim() && a.textContent.trim() !== '…'; }"""
results, summary = [], {"run_flag": FLAG}


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(("PASSED  " if ok else "FAILED  ") + name + ("" if ok else f"   <-- {str(detail)[:300]}"), flush=True)


class Session:
    def __init__(self, b, kind):
        self.ctx = b.new_context(viewport={"width": 1366, "height": 900})
        self.ctx.add_init_script("(() => { const W = window.WebSocket; window.__tlSockets = []; window.WebSocket = function (...a) {"
                                 " const w = new W(...a); window.__tlSockets.push(w); return w; }; window.WebSocket.prototype = W.prototype;"
                                 " Object.assign(window.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 }); })();"
                                 "localStorage.setItem('tavern-ledger:tab', 'combat');")
        if os.environ.get("LOCAL_API"):   # rehearsal against the LOCAL stack only (the local app reads this override)
            self.ctx.add_init_script("localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({url: %s, key: %s}));"
                                     % (json.dumps(os.environ["LOCAL_API"]), json.dumps(os.environ["LOCAL_KEY"])))
        self.page = self.ctx.new_page()
        self.rows, self.bodies, self.errors, self.bindings, self.joins, self.leaves = [], [], [], [], 0, 0
        self.page.on("console", lambda m: self.errors.append(m.text) if m.type == "error" else None)
        self.page.on("pageerror", lambda e: self.errors.append(f"pageerror: {e}"))
        self.page.on("request", self._req)
        self.page.on("requestfinished", lambda r: self._end(r, "ok"))
        self.page.on("requestfailed", lambda r: self._end(r, "failed"))
        self.page.on("response", self._resp)
        self.page.on("websocket", self._ws)
        p = self.page
        p.goto(APP + QS)
        p.fill("input[name=email]", EMAIL(kind))
        p.fill("input[name=password]", PW)
        p.click("button[value=signin]")
        # Home's list (a.brand is in the header before the list has loaded)
        p.wait_for_selector(".char-card, .empty-state", timeout=30000)

    def _req(self, r):
        if "/rest/v1/" not in r.url:
            return
        m = re.search(r"/rest/v1/(rpc/)?([a-z_0-9]+)", r.url)
        r._row = {"name": m.group(2) if m else "?", "rpc": bool(m and m.group(1)), "t0": time.time(), "t1": None, "outcome": "pending",
                  "status": None, "bytes": 0}
        self.rows.append(r._row)

    def _end(self, r, outcome):
        row = getattr(r, "_row", None)
        if row:
            row["t1"], row["outcome"] = time.time(), outcome

    def _resp(self, resp):
        row = getattr(resp.request, "_row", None)
        if not row:
            return
        row["status"] = resp.status
        if row["name"] in ("get_character_view", "get_character_shell", "get_character_reads", "get_background_list", "get_background_detail"):
            try:
                body = resp.text()
                row["bytes"] = len(body.encode())
                self.bodies.append((row["name"], body))
            except Exception:
                pass

    def _ws(self, ws):
        if "/realtime/" not in ws.url:
            return

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

    def char_id(self, name):
        return self.page.evaluate("(n) => [...document.querySelectorAll('.char-card[data-char]')].find(c => c.textContent.includes(n))?.dataset.char", name)

    def open(self, cid):
        i = self.mark(); t0 = time.time()
        self.page.evaluate(f"location.hash = '#/c/{cid}'")
        self.page.wait_for_function(USABLE, timeout=60000)
        t = time.time() - t0
        self.page.wait_for_timeout(2500)
        return t, self.since(i)

    def tab(self, key):
        self.page.locator(f'.tab[data-tab="{key}"]').first.click()
        self.page.wait_for_timeout(1200)

    def text(self):
        return self.page.evaluate("() => document.querySelector('#app')?.textContent || ''")


def run():
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)
        pl = Session(b, "player")
        info = pl.page.evaluate("() => window.__tavernLedgerReadPath")
        summary["read_path_player"] = info
        check("SM-01 player signed in; read path as requested", info.get("path") == ("fluent" if FLAG in ("1", "") else "legacy") or (FLAG == "" and info.get("path")), info)
        home = pl.text()
        check("SM-02 Home lists exactly the player's synthetic characters", HERO in home and SOLO in home)
        hero, solo = pl.char_id(HERO), pl.char_id(SOLO)
        t_open, rows = pl.open(hero)
        summary["open"] = {"usable_ms": round(t_open * 1000), "requests": len(rows), "names": sorted({r["name"] for r in rows}),
                           "shell_bytes": sum(r["bytes"] for r in rows if r["name"] == "get_character_shell"),
                           "domain_bytes": sum(r["bytes"] for r in rows if r["name"] == "get_character_reads"),
                           "shell_ms": [round((r["t1"] - r["t0"]) * 1000) for r in rows if r["name"] == "get_character_shell" and r["t1"]],
                           "domain_ms": [round((r["t1"] - r["t0"]) * 1000) for r in rows if r["name"] == "get_character_reads" and r["t1"]],
                           "failed": [r["name"] for r in rows if r["outcome"] == "failed" or (r["status"] or 200) >= 500]}
        check("SM-03 open: Character Shell renders (name, AC)", HERO in pl.text())
        if info.get("path") == "fluent":
            check("SM-03 open: progressive (1 shell + 1 domain request), no full view, no per-widget reads",
                  len([r for r in rows if r["name"] == "get_character_shell"]) == 1 and len([r for r in rows if r["name"] == "get_character_reads"]) == 1
                  and not [r for r in rows if r["name"] == "get_character_view"]
                  and not [r for r in rows if r["rpc"] and r["name"].startswith("get_character_") and r["name"] not in ("get_character_shell", "get_character_reads")],
                  summary["open"]["names"])
        check("SM-03 open: no failed / 5xx request", not summary["open"]["failed"], summary["open"]["failed"])
        for key in ("combat", "stats", "spells", "inventory", "features", "bio"):
            i = pl.mark(); pl.tab(key)
            panel = pl.page.evaluate(f"() => document.querySelector('.panel[data-panel=\"{key}\"]')?.textContent.trim().length || 0")
            summary.setdefault("tabs", {})[key] = {"requests": len(pl.since(i)), "chars": panel}
            check(f"SM-04 tab {key} renders", panel > 20, panel)
        i = pl.mark(); pl.tab("spells"); pl.tab("inventory")
        summary["tabs_revisit_requests"] = len(pl.since(i))
        # rapid switch Hero -> Solo -> Hero
        pl.page.evaluate("location.hash = '#/'"); pl.page.wait_for_selector(".char-card", timeout=30000)
        i = pl.mark(); t0 = time.time()
        for cid in (hero, solo, hero):
            pl.page.evaluate(f"location.hash = '#/c/{cid}'"); pl.page.wait_for_timeout(150)
        pl.page.wait_for_function(USABLE, timeout=60000); t_sw = time.time() - t0; pl.page.wait_for_timeout(2000)
        txt = pl.text()
        summary["switch"] = {"usable_ms": round(t_sw * 1000), "requests": len(pl.since(i))}
        check("SM-05 rapid switch: final character shown, no stale render", HERO in txt and SOLO not in txt.split(HERO)[0][-200:])
        # pickers
        pl.tab("features")
        i = pl.mark(); t0 = time.time(); pl.page.locator('[data-action="bg-choose"]').first.click()
        pl.page.wait_for_selector(".modal [data-bg-pick]", timeout=30000); t_l = time.time() - t0
        t1 = time.time(); pl.page.locator(".modal [data-bg-pick]").first.click()
        pl.page.wait_for_selector(".modal [data-bg-editor]", timeout=30000); t_d = time.time() - t1
        bg = pl.since(i)
        summary["background_picker"] = {"list_ms": round(t_l * 1000), "detail_ms": round(t_d * 1000), "requests": [r["name"] for r in bg],
                                        "list_bytes": sum(r["bytes"] for r in bg if r["name"] == "get_background_list")}
        check("SM-06 Background picker: list then detail", bool(bg) and pl.page.locator(".modal [data-bg-editor]").count() > 0, summary["background_picker"])
        pl.page.keyboard.press("Escape"); pl.page.wait_for_timeout(600)
        t0 = time.time(); pl.page.locator('[data-action="lineage-choose"]').first.click()
        ok = True
        try: pl.page.wait_for_selector(".modal [data-lineage-pick], .modal [data-lin-pick], .modal li button", timeout=30000)
        except Exception: ok = False
        summary["lineage_picker_ms"] = round((time.time() - t0) * 1000)
        check("SM-07 Lineage picker opens with results", ok)
        pl.page.keyboard.press("Escape"); pl.page.wait_for_timeout(600)
        pl.tab("spells")
        # the Spells tab re-renders when its reads arrive (legacy: 5 of them); a click on the old button is lost, so retry once
        ok = False
        t0 = time.time()
        for _ in range(2):
            pl.page.locator('[data-action="spell-add"]').first.click()
            try: pl.page.wait_for_selector(".modal input[type=search], .modal [data-spell-pick], .modal li", timeout=15000); ok = True; break
            except Exception: pass
        summary["spell_picker_ms"] = round((time.time() - t0) * 1000)
        check("SM-08 Spell picker opens", ok)
        pl.page.keyboard.press("Escape"); pl.page.wait_for_timeout(600)

        # DM session on the same character (two sessions)
        dm = Session(b, "dm")
        dm.page.evaluate("location.hash = '#/dm'"); dm.page.wait_for_timeout(3500)
        dm_ok = []
        for sec in ("party", "approvals", "content", "hidden", "rules"):
            dm.page.evaluate(f"location.hash = '#/dm/{sec}'"); dm.page.wait_for_timeout(2500)
            dm_ok.append((sec, len(dm.text()) > 100 and "could not be loaded" not in dm.text().lower()))
        check("SM-09 DM Space sections render (Party, Approvals, Content, Hidden, Campaign rules)", all(o for _, o in dm_ok), dm_ok)
        t_dm, _ = dm.open(hero)
        check("SM-10 DM opens the campaign character", HERO in dm.text())
        dm_seen = any(s in body for n, body in dm.bodies for s in SECRETS[:1])
        summary["dm_sees_hidden_condition_in_reads"] = dm_seen
        pl.tab("combat"); pl.page.evaluate(f"location.hash = '#/c/{hero}'"); pl.page.wait_for_function(USABLE, timeout=60000); pl.page.wait_for_timeout(1500)
        i1, i2 = pl.mark(), dm.mark()
        hp = pl.page.locator("#hp-card .hp-current").first
        hp.fill("9"); hp.press("Enter"); pl.page.wait_for_timeout(1000)
        seen = False
        for _ in range(40):
            if dm.page.locator("#hp-card .hp-current").first.input_value() == "9":
                seen = True; break
            dm.page.wait_for_timeout(250)
        check("SM-11 HP change reaches the DM session (Realtime)", seen)
        ed, vw = pl.since(i1), dm.since(i2)
        summary["hp_edit"] = {"editor": [r["name"] for r in ed], "viewer": [r["name"] for r in vw]}
        check("SM-11 HP change: no derived re-read in either session", not [r for r in ed + vw if r["rpc"]], summary["hp_edit"])
        hp.fill("12"); hp.press("Enter"); pl.page.wait_for_timeout(2500)   # restore
        summary["bindings_per_join"] = sorted(set(pl.bindings))
        summary["player_joins_leaves"] = [pl.joins, pl.leaves]
        if FLAG != "0":
            check("SM-12 Realtime: sheet channel has 2 bindings (was 64)", 2 in pl.bindings and 64 not in pl.bindings, pl.bindings)
        i = pl.mark()
        pl.page.evaluate("() => window.__tlSockets.filter((w) => w.url.includes('/realtime/') && w.readyState === 1).forEach((w) => w.close())")
        pl.page.wait_for_timeout(10000)
        rc = pl.since(i)
        summary["reconnect"] = {"requests": [r["name"] for r in rc]}
        if FLAG != "0":
            check("SM-13 reconnect: one reconciliation, no full reload", len(rc) <= 2 and not [r for r in rc if r["name"] in ("get_character_view", "get_character_shell")], summary["reconnect"])

        # security: hidden data absent from every player response; stranger denied
        leaked = [n for n, body in pl.bodies if any(s in body for s in SECRETS)]
        check("SM-14 player responses contain no hidden condition / DM note", not leaked, leaked)
        check("SM-14 player page shows no hidden data", not any(s in pl.text() for s in SECRETS))
        st = Session(b, "stranger")
        check("SM-15 stranger Home does not list the characters", HERO not in st.text() and SOLO not in st.text())
        st.page.evaluate(f"location.hash = '#/c/{hero}'"); st.page.wait_for_timeout(5000)
        check("SM-15 stranger cannot open the character", HERO not in st.text())
        check("SM-15 stranger responses contain no character data", not any(HERO in body for _, body in st.bodies))
        st.ctx.close()

        # sign-out clears user data
        pl.page.evaluate("location.hash = '#/'"); pl.page.wait_for_timeout(1500)
        pl.page.locator("#btn-signout").click(); pl.page.wait_for_selector("input[name=email]", timeout=30000)
        keys = pl.page.evaluate("() => Object.keys(localStorage).filter((k) => /^tavern-ledger:(list|bundle:|cardstats:)/.test(k))")
        check("SM-16 sign-out: no user data left in localStorage", not keys, keys)
        errs = [e for e in pl.errors + dm.errors if "Failed to load resource" not in e]
        summary["console_errors"] = errs[:5]
        check("SM-17 no console errors", not errs, errs[:3])
        summary["all_requests_player"] = len(pl.rows)
        summary["status_5xx"] = sum(1 for s in (pl, dm) for r in s.rows if (r["status"] or 0) >= 500)
        dm.ctx.close(); pl.ctx.close(); b.close()


if __name__ == "__main__":
    run()
    summary["passed"], summary["failed"] = sum(results), len(results) - sum(results)
    print(json.dumps(summary, indent=1))
    if os.environ.get("OUT"):
        with open(os.environ["OUT"], "w", encoding="utf-8") as f: json.dump(summary, f, indent=1)
