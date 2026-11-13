"""Regression suite of the production incident 2026-10-23 (57014 statement timeouts, Realtime IncreaseSubscriptionConnectionPool,
Background picker without a final state). docs/PRODUCTION_INCIDENT_REALTIME_TIMEOUTS.md, docs/CHARACTER_LOAD_COORDINATOR.md,
docs/CATALOG_PICKER_LOADING.md, docs/REALTIME_SUBSCRIPTION_ARCHITECTURE.md.

LOCAL ONLY: synthetic users and characters inside isolation.Isolated, every request delayed by LATENCY_MS (default 150 ms,
the production round trip). Thresholds come from the measured fix (docs/PRODUCTION_PERFORMANCE_BASELINE.md).
"""
import json
import os
import re
import time

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import ANON, APP, PW, RUN, Sheet, User, call, check, report
from incident_probe import HEAVY, Net, emulate, summary

LAT = int(os.environ.get("LATENCY_MS", "150"))
USABLE = """() => { const r = document.querySelector('.sheet-root'); if (!r || r.classList.contains('is-stale')) return false;
  const a = document.querySelector('[data-derived="ac"]'); return !!a && !!a.textContent.trim() && a.textContent.trim() !== '…'; }"""
SOCKETS = ("(() => { const W = window.WebSocket; window.__tlSockets = []; window.WebSocket = function (...a) {"
           " const w = new W(...a); window.__tlSockets.push(w); return w; }; window.WebSocket.prototype = W.prototype;"
           " Object.assign(window.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 }); })();")
DROP = "() => window.__tlSockets.filter((w) => w.url.includes('/realtime/') && w.readyState === 1).forEach((w) => w.close())"
RAW = re.compile(r"permission denied for|PGRST\d|SQLSTATE|canceling statement|42501|57014|row-level security|function public\.", re.I)
MAX_OPEN_REQUESTS = 35        # measured after the fix: 35 (release 9b810aa: 36)
MAX_OPEN_HEAVY = 9            # measured after the fix: 9 (release: 10; the spellbook loads with the Spells section)


def subs_for(user_id, character_id=None):
    q = f"select count(*) from realtime.subscription where claims ->> 'sub' = '{user_id}'"
    if character_id:
        q += f" and filters::text like '%{character_id}%'"
    return int(iso.psql(q))


PUMP = []   # a page whose wait lets Playwright deliver network events (the sync API dispatches them only inside its calls)


def wait_until(fn, timeout=10.0, step=0.25):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if fn():
                return True
        except Exception:
            pass
        if PUMP:
            PUMP[0].wait_for_timeout(int(step * 1000))
        else:
            time.sleep(step)
    return False


def new_sheet(b, user, tab="combat", width=1366, height=900):
    s = Sheet(b, user, tab=tab, width=width, height=height)
    s.ctx.add_init_script(SOCKETS)
    s.page.reload(); s.page.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)
    net = Net(s.page)
    emulate(s, s.page)
    return s, net


def go(page, cid, wait=True):
    page.evaluate(f"location.hash = '#/c/{cid}'")
    if wait:
        page.wait_for_function(USABLE, timeout=60000)


def bad_toasts(page):
    return [t for t in page.locator(".toast.bad, .toast-bad, .toast[data-type=bad]").all_inner_texts()]


def run(t):
    pl = User("incident")
    other = User("incident-outsider")
    spec = (("A", [("fighter-phb", 5)], 11), ("B", [("wizard-phb", 5)], 22), ("C", [("cleric-phb", 3), ("fighter-phb", 2)], 33),
            ("D", [("rogue-phb", 2)], 44))
    chars = {}
    for k, classes, hp in spec:
        chars[k] = pl.character(f"Incident {k} {RUN}", classes, strength=14, dexterity=14, constitution=14, hp_current=hp)
    t.note(characters=list(chars.values()))

    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)
        s, net = new_sheet(b, pl)
        page = s.page
        PUMP.append(page)
        FLUENT = page.evaluate("() => window.__tavernLedgerReadPath?.path === 'fluent'")
        # fluent read path: one sheet = 2 bindings (characters row + character_revisions INSERT) + 2 of the request bar;
        # a derived refresh is a coalesced get_character_reads request; a reconnect is one reconciliation read
        SUBS_ALL, SUBS_CHAR = (4, 4) if FLUENT else (72, 49)   # legacy +6 since 20261107: character_feats / _choices (2 filtered + 1 DELETE each)
        REFRESH = HEAVY | {"get_character_reads"} if FLUENT else HEAVY
        heavy_of = lambda rows: sum(1 for r in rows if r["name"] in REFRESH)

        # ---------------------------------------------------------------- incident reproduction + request budget
        go(page, chars["D"]); page.wait_for_timeout(2500)     # warm-up: shared reference data, bundle cache
        i = net.mark(); t0 = time.time()
        go(page, chars["A"]); usable = time.time() - t0
        page.wait_for_timeout(4000)
        o = summary(net.since(i))
        check("1 high-latency open: usable in %.1f s" % usable, usable < 15, usable)
        check("31 open stays within the request budget (%d requests, %d heavy)" % (o["requests"], o["heavy_rpcs"]),
              o["requests"] <= MAX_OPEN_REQUESTS and o["heavy_rpcs"] <= MAX_OPEN_HEAVY, o["by_name"])
        check("25 one Supabase client per page", page.evaluate("globalThis.__tavernLedgerClients") == 1,
              page.evaluate("globalThis.__tavernLedgerClients"))
        check("26 one Realtime WebSocket per page", net.ws == 1, net.ws)
        # one sheet = 70 bindings (47 filtered on the character + 23 DELETE without filter) + 2 of the request bar
        # the server removes the previous sheet's subscriptions asynchronously: wait for the steady state
        wait_until(lambda: subs_for(pl.id) == SUBS_ALL, 15)
        n_sub, n_all = subs_for(pl.id, chars["A"]), subs_for(pl.id)
        check("27 one character channel: %d filtered / %d total subscriptions" % (n_sub, n_all), n_sub == SUBS_CHAR and n_all == SUBS_ALL, (n_sub, n_all))

        # rapid A -> B -> C, 10 times: C renders, nothing of A or B, obsolete reads cancelled, no error
        stale_render, errors_before = False, len(s.errors)
        heavy_after_ready, cancelled = 0, 0
        for rnd in range(10):
            go(page, chars["D"]); page.wait_for_timeout(600)
            i = net.mark()
            for k in ("A", "B", "C"):
                page.evaluate(f"location.hash = '#/c/{chars[k]}'")
                page.wait_for_timeout(120)
            page.wait_for_function(USABLE, timeout=60000)
            ready_at = time.time()
            page.wait_for_timeout(2500)
            rows = net.since(i)
            hp = page.locator("#hp-card .hp-current").first.input_value()
            name_ok = page.evaluate(f"() => document.querySelector('.sheet-root')?.textContent.includes('Incident C {RUN}')")
            stale_render |= hp != "33" or not name_ok
            heavy_after_ready += sum(1 for r in rows if r["char"] in (chars["A"], chars["B"]) and r["name"] in HEAVY
                                     and r["outcome"] == "ok" and (r["t1"] or 0) > ready_at)
            cancelled += sum(1 for r in rows if r["char"] in (chars["A"], chars["B"]) and r["outcome"] == "cancelled")
        check("2/6 rapid A->B->C x10: C is shown every time (name and HP), never A or B", not stale_render)
        check("5 obsolete A/B reads are cancelled (%d cancelled over 10 rounds)" % cancelled, cancelled > 0, cancelled)
        check("34 no A/B heavy read completes after C is usable (%d)" % heavy_after_ready, heavy_after_ready == 0, heavy_after_ready)
        check("7/45 superseded reads are silent (no error toast, no console error)",
              not bad_toasts(page) and len(s.errors) == errors_before, (bad_toasts(page), s.errors[errors_before:]))
        check("28 old channels left: no subscription for A or B after the switches",
              wait_until(lambda: subs_for(pl.id, chars["A"]) == 0 and subs_for(pl.id, chars["B"]) == 0, 15),
              (subs_for(pl.id, chars["A"]), subs_for(pl.id, chars["B"])))
        check("8 the current load stays active: one channel for C", wait_until(lambda: subs_for(pl.id, chars["C"]) == SUBS_CHAR, 10),
              subs_for(pl.id, chars["C"]))
        i = net.mark(); page.wait_for_timeout(5000)
        idle = net.since(i)
        check("35 no request storm: an open sheet sends nothing while idle (%d requests in 5 s)" % len(idle), len(idle) == 0,
              [r["name"] for r in idle])

        # 9 a write submitted on A completes although the user switches to B at once
        go(page, chars["A"]); page.wait_for_timeout(1500)
        hp = page.locator("#hp-card .hp-current").first
        hp.fill("7"); hp.press("Enter")
        go(page, chars["B"], wait=False)
        page.wait_for_function(USABLE, timeout=60000)
        def stored_hp(cid):
            st, rows = call("GET", f"/rest/v1/characters?id=eq.{cid}&select=hp_current", token=pl.jwt, key=ANON)
            return rows[0]["hp_current"] if st == 200 and rows else None
        check("9 the HP write on A is stored after switching to B", wait_until(lambda: stored_hp(chars["A"]) == 7, 15), stored_hp(chars["A"]))
        check("9 B shows its own HP, not A's write", page.locator("#hp-card .hp-current").first.input_value() == "22",
              page.locator("#hp-card .hp-current").first.input_value())

        # HP echo: an HP change reaches a second open session without re-reading derived stats in either
        s2, net2 = new_sheet(b, pl)
        go(s2.page, chars["B"]); go(page, chars["B"]); page.wait_for_timeout(2500)
        i1, i2 = net.mark(), net2.mark()
        hp = page.locator("#hp-card .hp-current").first
        hp.fill("21"); hp.press("Enter"); page.wait_for_timeout(4500)
        heavy1 = heavy_of(net.since(i1)); heavy2 = heavy_of(net2.since(i2))
        seen = s2.page.locator("#hp-card .hp-current").first.input_value()
        check("HP edit: no derived re-read in the editing session (%d) or the viewing session (%d)" % (heavy1, heavy2),
              heavy1 == 0 and heavy2 == 0)
        check("HP edit still reaches the second session (%s)" % seen, seen == "21", seen)
        # an ability score change still re-reads the derived stats in the other session
        i2 = net2.mark()
        pst, pbody = call("PATCH", f"/rest/v1/characters?id=eq.{chars['B']}", {"dexterity": 16}, token=pl.jwt, key=ANON)
        check("ability change still re-reads derived stats in the other session",
              wait_until(lambda: any(r["name"] in ("get_character_derived_stats", "get_character_reads" if FLUENT else "-") for r in net2.since(i2)), 8),
              (pst, str(pbody)[:160], [r["name"] for r in net2.since(i2)]))

        # DELETE attribution: a delete on another character costs nothing (after learning), on this one it refreshes
        def toggle(cid, group):
            pl.rpc("set_character_proficiency", p_character=cid, p_group=group, p_item=None, p_enabled=True)
            time.sleep(1.5)
            m1, m2 = net.mark(), net2.mark()
            pl.rpc("set_character_proficiency", p_character=cid, p_group=group, p_item=None, p_enabled=False)
            page.wait_for_timeout(3500)
            return heavy_of(net.since(m1)), heavy_of(net2.since(m2))
        toggle(chars["D"], "simple-weapons")                    # first one: learned, conservative
        f1, f2 = toggle(chars["D"], "martial-weapons")
        check("foreign DELETE (character D, not open) re-reads nothing in two sheets of B (%d, %d)" % (f1, f2), f1 == 0 and f2 == 0)
        o1, o2 = toggle(chars["B"], "firearms")
        check("own DELETE (character B) still refreshes both sheets of B (%d, %d)" % (o1, o2), o1 > 0 and o2 > 0)
        s2.close()

        # ---------------------------------------------------------------- Realtime reconnect
        go(page, chars["C"]); page.wait_for_timeout(2500)
        wait_until(lambda: subs_for(pl.id) == SUBS_ALL, 15)
        before = subs_for(pl.id)
        i = net.mark()
        page.evaluate(DROP); page.wait_for_timeout(400); page.evaluate(DROP)      # two drops in quick succession
        page.wait_for_timeout(9000)
        rows = net.since(i)
        bundle_reads = sum(1 for r in rows if r["name"] == ("get_character_reads" if FLUENT else "characters") and r["char"] == chars["C"])
        check("29 two quick reconnects cause one coordinated refresh (%d %s)" % (bundle_reads, "reconciliation reads" if FLUENT else "bundle reads"),
              bundle_reads == 1 and not (FLUENT and any(r["name"] == "get_character_view" for r in rows)), [r["name"] for r in rows])
        check("4 reconnect keeps the sheet usable and on C", page.evaluate(USABLE) and page.locator("#hp-card .hp-current").first.input_value() == "33")
        check("reconnect: no extra channel (subscriptions %d -> %d)" % (before, subs_for(pl.id)),
              wait_until(lambda: subs_for(pl.id) == before, 15), (before, subs_for(pl.id)))

        # ---------------------------------------------------------------- Background picker
        page.locator('.tab[data-tab="features"]').first.click(); page.wait_for_timeout(800)
        go(page, chars["A"], wait=False)
        page.wait_for_function(USABLE, timeout=60000)
        page.locator('.tab[data-tab="features"]').first.click()
        # 3/13/14 while the sheet still loads and Inventory / spellbook answers are held back for 8 s
        slow = []
        def delay(route):
            # fluent (progressive): only the coalesced reads that carry the spellbook or the inventory are held back; the open's
            # domain request (Build, Play) is not part of this scenario
            body = route.request.post_data or ""
            if "get_character_reads" in route.request.url and "get_character_spellbook" not in body and "inventory_bundle" not in body:
                route.continue_(); return
            slow.append(route)
        page.route("**/rest/v1/v_inventory_detail*", delay)
        page.route("**/rest/v1/rpc/get_character_spellbook", delay)
        page.route("**/rest/v1/rpc/get_character_reads", delay)   # fluent: any later coalesced read of the sheet
        go(page, chars["C"], wait=False)
        page.wait_for_function(USABLE, timeout=60000)
        i = net.mark(); t0 = time.time()
        page.locator('[data-action="bg-choose"]').first.click()
        page.wait_for_selector(".modal", timeout=5000); shell = time.time() - t0
        loading_seen = page.locator('.modal [data-picker-state="loading"][role="status"][aria-live="polite"]').count() > 0 or \
            page.locator(".modal [data-bg-pick]").count() > 0
        page.wait_for_selector(".modal [data-bg-pick]", timeout=20000); listed = time.time() - t0
        check("11 Background picker opens at once (%.2f s)" % shell, shell < 1.5, shell)
        check("47 loading state is announced (role=status, aria-live) or results are already there", loading_seen)
        # fluent: Inventory and the spellbook are not read on open at all (held-back count may be 0); legacy: they are held back
        check("3/13/14 results while Inventory and spellbook are still held back (%.2f s)" % listed, listed < 8 and (FLUENT or len(slow) > 0), (listed, len(slow)))
        for r in slow:
            try: r.continue_()
            except Exception: pass
        page.unroute("**/rest/v1/v_inventory_detail*"); page.unroute("**/rest/v1/rpc/get_character_spellbook"); page.unroute("**/rest/v1/rpc/get_character_reads")
        n = page.locator(".modal [data-bg-pick]").count()
        check("12 permitted backgrounds are listed (%d, 29 enabled by default)" % n, n == 29, n)
        check("50 focus stays inside the picker", page.evaluate("() => !!document.activeElement?.closest('.modal')"))
        page.fill('.modal input[name="q"]', "sage")
        names = page.locator(".modal [data-bg-pick] strong").all_inner_texts()
        check("15 search filters (%s)" % names, names and all("sage" in x.lower() for x in names), names)
        page.locator(".modal [data-bg-pick]").first.click()
        page.locator(".modal [data-bg-editor]").wait_for(timeout=15000)   # detail on selection (fluent path)
        check("16 first click after search picks the background",
              page.locator(".modal [data-bg-pick].is-picked").count() == 1 and not page.locator(".modal [data-bg-save]").is_disabled())
        page.fill('.modal input[name="q"]', "zzzz")
        check("17 empty search is explained", "No background matches" in page.locator(".modal [data-bg-list]").inner_text())
        page.keyboard.press("Escape"); page.wait_for_timeout(500)
        check("51 closing restores focus to the opener",
              page.evaluate("() => document.activeElement?.dataset.focusKey") in ("bg-choose", "bg-change"),
              page.evaluate("() => document.activeElement?.outerHTML?.slice(0, 120)"))
        i = net.mark()
        page.locator('[data-action="bg-choose"]').first.click(); page.wait_for_selector(".modal [data-bg-pick]", timeout=5000)
        check("33 reopening uses the cached catalog (0 requests)", summary(net.since(i))["requests"] == 0, summary(net.since(i))["by_name"])
        # 24 keyboard: Tab from the search field reaches the list, Enter picks
        page.focus('.modal input[name="q"]')
        trail = []
        for _ in range(8):
            page.keyboard.press("Tab")
            trail.append(page.evaluate("() => (document.activeElement?.tagName || '') + (document.activeElement?.name ? ':' + document.activeElement.name : '') + (document.activeElement?.dataset?.bgPick ? ':pick' : '')"))
            if trail[-1].endswith(":pick"):
                break
        page.keyboard.press("Enter")
        check("24 keyboard: Tab reaches a background, Enter picks it",
              wait_until(lambda: page.locator(".modal [data-bg-pick].is-picked").count() == 1, 5), trail)
        page.keyboard.press("Escape"); page.wait_for_timeout(500)

        # 19/20/21/22 failures: a fresh page each (the catalog is cached per page)
        def picker_with(handler, wait_ms=6000):
            sx, nx = new_sheet(b, pl, tab="features")
            px = sx.page
            go(px, chars["C"])
            px.route("**/rest/v1/rpc/get_background_catalog", handler)
            px.route("**/rest/v1/rpc/get_background_list", handler)
            ix = nx.mark()
            px.locator('[data-action="bg-choose"]').first.click()
            px.wait_for_selector(".modal", timeout=5000)
            px.wait_for_selector('.modal [data-picker-state="error"]', timeout=wait_ms)
            return sx, nx, px, ix
        err = lambda status, code, msg: (lambda route: route.fulfill(status=status, content_type="application/json",
                                                                      body=json.dumps({"code": code, "message": msg, "details": None, "hint": None})))
        sx, nx, px, _ = picker_with(err(401, "PGRST301", "JWT expired"))
        txt = px.locator('.modal [data-picker-state="error"]').inner_text()
        check("19 401 / expired session is explained (%s)" % txt.strip()[:80], "session has expired" in txt.lower() and not RAW.search(txt), txt)
        sx.close()
        sx, nx, px, _ = picker_with(err(403, "42501", "permission denied for function get_background_catalog"))
        txt = px.locator('.modal [data-picker-state="error"]').inner_text()
        check("20 403 is explained without SQL text (%s)" % txt.strip()[:80], "campaign or dm" in txt.lower() and not RAW.search(txt), txt)
        check("43/44 no raw error text and no toast for a picker failure", not bad_toasts(px), bad_toasts(px))
        sx.close()
        sx, nx, px, _ = picker_with(err(500, "57014", "canceling statement due to statement timeout"))
        txt = px.locator('.modal [data-picker-state="error"]').inner_text()
        check("server statement timeout (57014) is explained (%s)" % txt.strip()[:80], "too long" in txt.lower() and not RAW.search(txt), txt)
        check("48 the error is announced (role=alert)", px.locator('.modal [data-picker-state="error"][role="alert"]').count() == 1)
        # 49/22 Retry with the keyboard: one request, then results
        px.unroute("**/rest/v1/rpc/get_background_catalog"); px.unroute("**/rest/v1/rpc/get_background_list")
        ix = nx.mark()
        px.focus(".modal [data-picker-retry]"); px.keyboard.press("Enter"); px.keyboard.press("Enter")
        px.wait_for_selector(".modal [data-bg-pick]", timeout=10000)
        tries = sum(1 for r in nx.since(ix) if r["name"] in ("get_background_catalog", "get_background_list"))
        check("22/49 Retry by keyboard loads the list with one request (%d)" % tries, tries == 1, tries)
        sx.close()
        # 21/41/42/46 a request that never answers: a final state with Retry, and no automatic retry afterwards
        sx, nx, px, ix = picker_with(lambda route: None, wait_ms=25000)
        txt = px.locator('.modal [data-picker-state="error"]').inner_text()
        check("21/41/46 an unanswered request ends in a message with Retry (%s)" % txt.strip()[:60],
              "too long" in txt.lower() and px.locator(".modal [data-picker-retry]").count() == 1, txt)
        px.wait_for_timeout(6000)
        n_tries = sum(1 for r in nx.since(ix) if r["name"] in ("get_background_catalog", "get_background_list"))
        check("42 no automatic retry (%d request)" % n_tries, n_tries == 1, n_tries)
        px.unroute("**/rest/v1/rpc/get_background_catalog"); px.unroute("**/rest/v1/rpc/get_background_list")
        px.locator(".modal [data-picker-retry]").click()
        check("22 Retry after a stalled request sends a new request and shows the list",
              wait_until(lambda: px.locator(".modal [data-bg-pick]").count() == 29, 15))
        sx.close()

        # 23 mobile
        sm, nm = new_sheet(b, pl, tab="features", width=390, height=844)
        go(sm.page, chars["C"])
        sm.page.locator('[data-action="bg-choose"]').first.click()
        sm.page.wait_for_selector(".modal [data-bg-pick]", timeout=15000)
        check("23 mobile 390 px: picker lists backgrounds without horizontal overflow",
              sm.page.locator(".modal [data-bg-pick]").count() == 29 and sm.overflow() <= 0, sm.overflow())
        sm.close()

        # ---------------------------------------------------------------- related pickers: failure ends in a final state
        sr, nr = new_sheet(b, pl, tab="features")
        pr = sr.page
        # the class catalog is read (and cached) when the sheet opens: make that read fail too, so the picker has to load it
        pr.route("**/rest/v1/classes*", err(500, "57014", "canceling statement due to statement timeout"))
        go(pr, chars["C"])
        pr.locator('[data-action="class-add"]').first.click()
        check("class picker: a failed catalog read is explained, not silent",
              wait_until(lambda: "too long" in " ".join(pr.locator(".toast").all_inner_texts()).lower(), 8),
              pr.locator(".toast").all_inner_texts())
        check("class picker: no dialog left half-open", pr.locator(".modal").count() == 0)
        pr.unroute("**/rest/v1/classes*")
        pr.locator('[data-action="class-add"]').first.click()
        check("class picker: clicking again (retry) opens it", wait_until(lambda: pr.locator(".modal").count() == 1, 10))
        pr.keyboard.press("Escape"); pr.wait_for_timeout(500)
        pr.locator('.tab[data-tab="spells"]').first.click(); pr.wait_for_timeout(500)
        pr.route("**/rest/v1/v_spell_catalog*", err(500, "57014", "canceling statement due to statement timeout"))
        pr.locator('[data-action="spell-add"]').first.click()
        check("spell picker: a failed catalog read is explained, not silent",
              wait_until(lambda: "too long" in " ".join(pr.locator(".toast").all_inner_texts()).lower(), 8),
              pr.locator(".toast").all_inner_texts())
        pr.unroute("**/rest/v1/v_spell_catalog*")
        pr.locator('[data-action="spell-add"]').first.click()
        check("spell picker: clicking again (retry) opens it", wait_until(lambda: pr.locator(".modal").count() == 1, 10))
        pr.keyboard.press("Escape"); pr.wait_for_timeout(500)
        check("lazy spellbook: the Spells section shows the spellbook", wait_until(lambda: pr.locator("#spellbook-list").count() == 1, 5))
        pr.locator('.tab[data-tab="features"]').first.click(); pr.wait_for_timeout(500)
        pr.route("**/rest/v1/v_lineage_catalog*", err(500, "57014", "canceling statement due to statement timeout"))
        pr.locator('[data-action="lineage-choose"]').first.click()
        check("lineage picker: a failed catalog read ends in a message inside the dialog",
              wait_until(lambda: pr.locator(".modal").count() == 1 and pr.locator(".modal .spinner").count() == 0
                         and len(pr.locator(".modal").inner_text().strip()) > 0, 10))
        pr.keyboard.press("Escape"); pr.wait_for_timeout(500)
        pr.unroute("**/rest/v1/v_lineage_catalog*")
        pr.route("**/rest/v1/rpc/get_feat_catalog", err(500, "57014", "canceling statement due to statement timeout"))
        pr.locator('[data-feat="add"]').first.click()
        check("feat picker: a failed catalog read ends in a message inside the dialog",
              wait_until(lambda: pr.locator(".modal [data-count]").count() == 1 and len(pr.locator(".modal [data-count]").inner_text().strip()) > 0, 10))
        pr.keyboard.press("Escape")
        sr.close()

        # ---------------------------------------------------------------- security (unchanged behaviour)
        st, body = other.rpc("get_character_derived_stats", p_character=chars["C"])
        check("37 an outsider cannot read the character's derived stats", st >= 400 or body in (None, {}, []), (st, str(body)[:120]))
        st, rows = call("GET", f"/rest/v1/character_proficiencies?character_id=eq.{chars['C']}&select=id", token=other.jwt, key=ANON)
        check("37 the DELETE-attribution read shows an outsider nothing", st == 200 and rows == [], (st, rows))
        st, body = call("POST", "/rest/v1/rpc/get_background_catalog", {}, token=ANON, key=ANON)
        check("36 the background catalog is unchanged (public official catalog, 30 versions)",
              st == 200 and len(body.get("versions", [])) == 30, (st, str(body)[:100]))

        # 10/30 sign-out: reads stop, channels are removed
        go(page, chars["C"], wait=False)
        page.wait_for_timeout(300)
        page.evaluate("async () => { const m = await import('./js/supabase.js?v=27'); await m.supabase.auth.signOut(); }")
        page.wait_for_selector("input[name=email]", timeout=15000)
        check("30 sign-out removes every Realtime subscription of the user", wait_until(lambda: subs_for(pl.id) == 0, 15), subs_for(pl.id))
        check("10 sign-out: no sheet is rendered afterwards", page.locator(".sheet-root").count() == 0)
        check("no console error during the suite", not [e for e in s.errors if "Failed to load resource" not in e],
              [e for e in s.errors if "Failed to load resource" not in e][:5])
        s.close(); b.close()


with iso.Isolated("production timeout incident") as t:
    run(t)
report()
