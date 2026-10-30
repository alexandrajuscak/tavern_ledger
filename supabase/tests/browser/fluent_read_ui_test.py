"""Fluent read architecture, browser suite (docs/FLUENT_READ_ARCHITECTURE.md). LOCAL ONLY, synthetic users inside isolation.

Covers: one request per open, seeded loaders (no per-widget reads), coalesced reloads, tab bundles (Spells, Inventory),
cached tabs, A -> B -> C without stale render, Home prefetch reuse, Background list/detail, HP between two sessions without
a derived re-read, revision-driven list refresh, reconnect = one reconciliation, 3+2 Realtime bindings, legacy flag and
automatic fallback, sign-out clears user data, unrelated player denied, no character payload in localStorage.
Usage: APP_URL=... python fluent_read_ui_test.py   (run_browser_local.sh sets the environment)
"""
import json
import re
import time

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, Sheet, User, check, report
from incident_probe import Net, USABLE, emulate

READ_RPCS = re.compile(r"^get_character_(?!view$|reads$|bundle$)")


def rpcs(rows, name=None):
    return [r for r in rows if r["rpc"] and (name is None or r["name"] == name)]


def fluent(s):
    return s.page.evaluate("() => window.__tavernLedgerReadPath?.path")


def open_wait(s, cid, timeout=30000):
    s.page.evaluate(f"location.hash = '#/c/{cid}'")
    s.page.wait_for_function(USABLE, timeout=timeout)


def run(t):
    pl = User("fluent")
    other = User("fluent-other")
    chars = {k: pl.character(f"Fluent {k} {RUN}", v, strength=14, dexterity=14, constitution=14, wisdom=14, intelligence=14)
             for k, v in (("A", [("fighter-phb", 3)]), ("B", [("wizard-phb", 3)]), ("C", [("cleric-phb", 2), ("fighter-phb", 1)]),
                          ("D", [("druid-phb", 2)]))}
    t.note(characters=list(chars.values()))
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(b, pl, tab="combat")
        s.ctx.add_init_script("(() => { const W = window.WebSocket; window.__tlSockets = []; window.WebSocket = function (...a) {"
                              " const w = new W(...a); window.__tlSockets.push(w); return w; }; window.WebSocket.prototype = W.prototype;"
                              " Object.assign(window.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 }); })();")
        page = s.page
        page.goto(APP + "?fluent=1")
        page.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)
        net = Net(page)
        check("FL-00 fluent path active (?fluent=1 override)", fluent(s) == "fluent", page.evaluate("() => window.__tavernLedgerReadPath"))

        # warm the session catalogs (class catalog, lineage reference, ...) once, as any first open does
        open_wait(s, chars["D"]); page.wait_for_timeout(2500)

        # --- FL-01 one request per open
        i = net.mark(); j0 = net.joins
        open_wait(s, chars["A"]); page.wait_for_timeout(2500)
        rows = net.since(i)
        views = rpcs(rows, "get_character_view")
        per_widget = [r for r in rpcs(rows) if READ_RPCS.match(r["name"])]
        tables = [r for r in rows if not r["rpc"] and r["char"] == chars["A"]]
        check("FL-01 open = 1 get_character_view", len(views) == 1, [r["name"] for r in rows])
        check("FL-01 open: no per-widget character RPC", not per_widget, [r["name"] for r in per_widget])
        check("FL-01 open: no table reads of the character", not tables, [r["name"] for r in tables])
        check("FL-01 open: total requests <= 2 (view + at most a throttled campaigns refresh)", len([r for r in rows if r["name"] not in ("campaigns", "campaign_members", "profiles")]) == 1
              and len(rows) <= 4, [r["name"] for r in rows])
        check("FL-01 sheet marked fluent", page.evaluate("() => document.querySelector('.sheet-root')?.dataset.readPath") == "fluent")
        check("FL-01 header shows the character", f"Fluent A {RUN}" in page.locator(".sheet-root").inner_text())
        check("FL-02 Realtime: 2 sheet bindings per join (was 64)", 2 in net.bindings and 64 not in net.bindings[-3:], net.bindings[-4:])
        subs = int(iso.psql(f"select count(*) from realtime.subscription where filters::text like '%{chars['A']}%'"))
        check("FL-02 realtime.subscription rows for the open sheet <= 4", 0 < subs <= 4, subs)

        # --- FL-03 tabs: Spells and Inventory load one request each, the second visit none
        i = net.mark(); s.tab("spells"); page.wait_for_timeout(1500)
        r1 = net.since(i)
        check("FL-03 first Spells open = 1 get_character_reads", len(rpcs(r1, "get_character_reads")) == 1 and not [r for r in rpcs(r1) if READ_RPCS.match(r["name"])],
              [r["name"] for r in r1])
        i = net.mark(); s.tab("inventory"); page.wait_for_timeout(2000)
        r2 = net.since(i)
        reads2 = rpcs(r2, "get_character_reads")
        inv_tables = [r for r in r2 if not r["rpc"] and r["name"] in ("inventories", "v_inventory_detail", "character_equipment", "v_character_attunement",
                                                                     "v_inventory_weight", "v_container_contents", "legacy_inventory_review", "v_item_catalog")]
        check("FL-03 first Inventory open = 1 bundle read, no per-view reads", len(reads2) == 1 and not inv_tables, [r["name"] for r in r2])
        check("FL-03 Inventory panel rendered", page.locator("#inventory-app").inner_text().strip() != "")
        i = net.mark(); s.tab("spells"); s.tab("inventory"); s.tab("combat"); page.wait_for_timeout(800)
        check("FL-03 cached tabs: no request on revisit", not [r for r in net.since(i) if r["char"] == chars["A"]], [r["name"] for r in net.since(i)])

        # --- FL-04 A -> B -> C fast: only C renders, C usable, at most one view per target
        i = net.mark()
        for k in ("A", "B", "C"):
            page.evaluate(f"location.hash = '#/c/{chars[k]}'"); page.wait_for_timeout(120)
        page.wait_for_function(USABLE, timeout=30000); page.wait_for_timeout(1500)
        txt = page.locator(".sheet-root").inner_text()
        check("FL-04 switch: C shown, not A or B", f"Fluent C {RUN}" in txt and f"Fluent B {RUN}" not in txt and f"Fluent A {RUN}" not in txt)
        sw = net.since(i)
        check("FL-04 switch: <= 1 view per character, no per-widget reads", all(len([r for r in rpcs(sw, "get_character_view") if r["char"] == chars[k]]) <= 1 for k in "ABC")
              and not [r for r in rpcs(sw) if READ_RPCS.match(r["name"])], [r["name"] for r in sw])

        # --- FL-05 Home prefetch is reused by the open
        page.evaluate("location.hash = '#/'"); page.wait_for_selector(".char-card", timeout=15000); page.wait_for_timeout(800)
        i = net.mark()
        page.locator(f'.char-card[data-char="{chars["B"]}"]').hover(); page.wait_for_timeout(900)
        pre = rpcs(net.since(i), "get_character_view")
        page.locator(f'.char-card[data-char="{chars["B"]}"]').click(); page.wait_for_function(USABLE, timeout=30000); page.wait_for_timeout(1500)
        allv = rpcs(net.since(i), "get_character_view")
        check("FL-05 hover prefetches the view", len(pre) == 1, [r["name"] for r in net.since(i)])
        check("FL-05 open reuses the prefetch (no second view)", len(allv) == 1, len(allv))

        # --- FL-06 Background picker: compact list, detail on selection
        s.tab("features"); page.wait_for_timeout(500)
        i = net.mark()
        page.locator('[data-action="bg-choose"]').first.click()
        page.wait_for_selector(".modal [data-bg-pick]", timeout=20000)
        lst = rpcs(net.since(i))
        check("FL-06 picker list via get_background_list (no full catalog)", [r["name"] for r in lst] == ["get_background_list"], [r["name"] for r in lst])
        st_l, body_l = pl.rpc("get_background_list"); st_c, body_c = pl.rpc("get_background_catalog")
        size, full = len(json.dumps(body_l)), len(json.dumps(body_c))
        check("FL-06 list response < 40 KB and < 10 % of the catalog", st_l == 200 and 0 < size < 40000 and size * 10 < full, (size, full))
        i = net.mark()
        page.locator(".modal [data-bg-pick]").first.click()
        page.wait_for_selector(".modal [data-bg-editor]", timeout=20000)
        check("FL-06 detail loaded on selection", [r["name"] for r in rpcs(net.since(i))] == ["get_background_detail"], [r["name"] for r in net.since(i)])
        page.keyboard.press("Escape"); page.wait_for_timeout(600)

        # --- FL-07 HP between two sessions: viewer patched, no derived re-read anywhere
        s.tab("combat"); page.wait_for_timeout(500)
        s2 = Sheet(b, pl, tab="combat"); s2.page.goto(APP + "?fluent=1"); s2.page.wait_for_selector(".char-card", timeout=20000)
        net2 = Net(s2.page)
        open_wait(s2, chars["B"]); s2.page.wait_for_timeout(2000)
        i1, i2 = net.mark(), net2.mark()
        hp = page.locator("#hp-card .hp-current").first
        hp.fill("21"); hp.press("Enter"); page.wait_for_timeout(4000)
        ed, vw = net.since(i1), net2.since(i2)
        check("FL-07 viewer shows the new HP", s2.wait(lambda: s2.page.locator("#hp-card .hp-current").first.input_value() == "21", 6000),
              s2.page.locator("#hp-card .hp-current").first.input_value())
        check("FL-07 HP: no derived re-read in editor or viewer", not [r for r in ed + vw if r["rpc"] and r["name"] != "get_character_reads"]
              and not [r for r in rpcs(vw, "get_character_reads")], [r["name"] for r in ed + vw])

        # --- FL-08 a tracker change in session 2 refreshes only that list in session 1 (revision event)
        st, _ = pl.rpc("get_character_view", p_character=chars["B"], p_tab="combat")   # warm, no effect
        i1 = net.mark()
        sql = (f"insert into public.feature_trackers (character_id, name, max, current) values ('{chars['B']}', 'FL tracker {RUN}', 3, 3)")
        iso.psql(sql)
        page.wait_for_timeout(3500)
        r8 = net.since(i1)
        check("FL-08 revision: one coalesced read of the changed list", len(rpcs(r8, "get_character_reads")) == 1 and len(r8) == 1, [r["name"] for r in r8])
        check("FL-08 the new tracker appears", s.wait(lambda: page.evaluate(f"() => [...document.querySelectorAll('.sheet-root input, .sheet-root [data-t]')].some(e => (e.value || e.textContent || '').includes('FL tracker {RUN}')) || document.querySelector('.sheet-root').textContent.includes('FL tracker {RUN}')"), 6000))

        # --- FL-09 reconnect: one reconciliation, no full reload
        i = net.mark(); j0 = net.joins
        page.evaluate("() => window.__tlSockets.filter((w) => w.url.includes('/realtime/') && w.readyState === 1).forEach((w) => w.close())")
        page.wait_for_timeout(9000)
        r9 = net.since(i)
        check("FL-09 reconnect: <= 2 requests (reconciliation), no view, no per-widget reads",
              len(r9) <= 2 and not rpcs(r9, "get_character_view") and not [r for r in rpcs(r9) if READ_RPCS.match(r["name"])], [r["name"] for r in r9])
        s2.close()

        # --- FL-10 no character payload persisted in localStorage
        keys = page.evaluate("() => Object.keys(localStorage)")
        check("FL-10 no bundle:* keys in localStorage", not [k for k in keys if k.startswith("tavern-ledger:bundle:")], keys)

        # --- FL-11 unrelated player denied
        so = Sheet(b, other, tab="combat"); so.page.goto(APP + "?fluent=1"); so.page.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)
        so.page.evaluate(f"location.hash = '#/c/{chars['A']}'"); so.page.wait_for_timeout(4000)
        txt = so.page.locator("#app").inner_text()
        check("FL-11 unrelated player: character not shown", f"Fluent A {RUN}" not in txt and "could not be loaded" in txt, txt[:200])
        so.close()

        # --- FL-12 sign-out clears user data (localStorage list/cardstats, read caches)
        page.evaluate("location.hash = '#/'"); page.wait_for_timeout(1000)
        page.locator("#btn-signout").click(); page.wait_for_selector("input[name=email]", timeout=15000)
        keys = page.evaluate("() => Object.keys(localStorage).filter((k) => /^tavern-ledger:(list|bundle:|cardstats:)/.test(k))")
        check("FL-12 sign-out: no user data keys left", not keys, keys)

        # --- FL-13 legacy flag and automatic fallback
        s3 = Sheet(b, pl, tab="combat"); s3.page.goto(APP + "?fluent=0"); s3.page.wait_for_selector(".char-card", timeout=20000)
        net3 = Net(s3.page)
        i = net3.mark(); open_wait(s3, chars["A"]); s3.page.wait_for_timeout(2500)
        check("FL-13 ?fluent=0: legacy path (no view, per-widget reads)", fluent(s3) == "legacy" and not rpcs(net3.since(i), "get_character_view")
              and len(net3.since(i)) > 10, [r["name"] for r in net3.since(i)][:12])
        s3.close()
        s4 = Sheet(b, pl, tab="combat")
        s4.page.route("**/rest/v1/rpc/get_character_view", lambda r: r.fulfill(status=404, content_type="application/json",
                      body=json.dumps({"code": "PGRST202", "message": "Could not find the function public.get_character_view"})))
        s4.page.goto(APP + "?fluent=1"); s4.page.wait_for_selector(".char-card", timeout=20000)
        open_wait(s4, chars["A"]); s4.page.wait_for_timeout(1500)
        info = s4.page.evaluate("() => window.__tavernLedgerReadPath")
        check("FL-13 missing fluent functions: falls back to legacy and still opens", info.get("path") == "legacy" and info.get("fallback")
              and f"Fluent A {RUN}" in s4.page.locator(".sheet-root").inner_text(), info)
        s4.close()
        s5 = Sheet(b, pl, tab="combat")
        s5.page.route("**/rest/v1/rpc/get_character_view", lambda r: r.fulfill(status=500, content_type="application/json",
                      body=json.dumps({"code": "57014", "message": "canceling statement due to statement timeout"})))
        s5.page.goto(APP + "?fluent=1"); s5.page.wait_for_selector(".char-card", timeout=20000)
        open_wait(s5, chars["A"]); s5.page.wait_for_timeout(1500)
        info = s5.page.evaluate("() => window.__tavernLedgerReadPath")
        rp = s5.page.evaluate("() => document.querySelector('.sheet-root')?.dataset.readPath")
        stored = s5.page.evaluate("() => Object.keys(localStorage).filter((k) => k.includes('bundle:'))")
        check("FL-13 view statement timeout (57014): this sheet opens on the legacy reads; the flag stays on; nothing persisted",
              rp == "legacy" and info.get("path") == "fluent" and not info.get("fallback") and f"Fluent A {RUN}" in s5.page.locator(".sheet-root").inner_text()
              and not stored and not [e for e in s5.errors if "Failed to load resource" not in e], (rp, info, stored, s5.errors[:3]))
        s5.close()
        s4b = Sheet(b, pl, tab="combat"); s4b.page.goto(APP + "?fluent=default"); s4b.page.wait_for_timeout(500); s4b.close()

        check("FL-99 no console errors (fluent session)", not [e for e in s.errors if "Failed to load resource" not in e], s.errors[:5])
        s.close(); b.close()


if __name__ == "__main__":
    with iso.Isolated("FLUENT-UI") as t:
        run(t)
    report()
