"""V6.2 adversarial browser test (docs/V62_ADVERSARIAL_HARDENING_REVIEW.md): inert injection payloads, malformed numbers,
duplicate actions, interrupted and offline saves, error boundaries, deep links, storage after sign-out and missing assets.

Runs inside isolation.Isolated: synthetic users only (ui-*@example.test); every public table is compared with its start
state afterwards and the result is journaled. Refuses non-local URLs (class_ui_common). Screenshots go to SCREENSHOT_DIR.
"""
import json
import os
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, SHOTS, Sheet, User, call, check, report

# every payload must stay text: a successful one sets window.__xss
XSS = {
    "name": '<img src=x onerror="window.__xss=1">Vex',
    "note": '<script>window.__xss=2</script><b>bold?</b>',
    "feature": '"><svg onload="window.__xss=3">',
    "attack": "javascript:window.__xss=4//<a href=javascript:window.__xss=4>x</a>",
    "item": '<iframe srcdoc="<script>parent.__xss=5</script>"></iframe>Bag',
    "tracker": "{{constructor.constructor('window.__xss=6')()}}",
}
TECH = ("PGRST", "violates", "constraint", "relation \"", "row-level security", "JWT", "SQLSTATE", "null value in column", "syntax error")


def db(q):
    return iso.psql(q)


def put(loc, value):
    """What a browser delivers for a typed value: a number input turns non-numbers into ''; then input, change and blur."""
    loc.evaluate("(e, v) => { e.focus(); e.value = v; e.dispatchEvent(new Event('input', { bubbles: true })); e.dispatchEvent(new Event('change', { bubbles: true })); e.blur(); }", value)


def main():
    with iso.Isolated("V62-UI adversarial") as t:
        run(t)
    report()


def run(t):
    pl, other = User("v62u-pl"), User("v62u-other")
    ch = pl.character(XSS["name"], [("fighter-phb", 3)], strength=15, constitution=14, hp_max=30, hp_current=30)
    foreign = other.character(f"V62 Foreign {RUN}", [("wizard-phb", 1)])
    t.note(characters=[ch, foreign])
    db(f"""update public.notes set content = $x${XSS['note']}$x$ where character_id = '{ch}' and kind = 'character';
      insert into public.features (character_id, name, description, category, activation, sort_order) values ('{ch}', $x${XSS['feature']}$x$, $x${XSS['note']}$x$, 'custom', 'passive', 0);
      insert into public.attacks (character_id, name, notes) values ('{ch}', $x${XSS['attack']}$x$, $x${XSS['feature']}$x$);
      insert into public.feature_trackers (character_id, name, max, current, reset_on, sort_order) values ('{ch}', $x${XSS['tracker']}$x$, 2, 2, 'long', 0);
      update public.characters set conditions = jsonb_build_array($x${XSS['feature']}$x$::text) where id = '{ch}';""")
    _, inv = call("GET", f"/rest/v1/inventories?character_id=eq.{ch}&kind=eq.character&select=id", token=pl.jwt)
    st, r = pl.rpc("add_inventory_item", p_inventory=inv[0]["id"], p_item="dagger", p_quantity=1, p_custom_name=XSS["item"], p_notes=XSS["note"], p_state={})
    assert st == 200, (st, r)

    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, pl, tab="combat")
        page = s.page

        # ---- 1. injection payloads stay text everywhere ---------------------------------------------------------------------------
        page.goto(APP)
        page.wait_for_selector(".char-card")
        s.wait(lambda: page.locator(".cc-wait").count() == 0)
        home_ok = XSS["name"] in page.locator(f'.char-card[data-char="{ch}"]').inner_text()
        s.open(ch)
        for tab in ("combat", "stats", "spells", "inventory", "features", "bio"):
            s.tab(tab)
            page.wait_for_timeout(500)
        injected = page.evaluate("""() => ({ flag: window.__xss ?? null,
            nodes: document.querySelectorAll('img[src="x"], iframe[srcdoc], svg[onload], script:not([src]):not([type])').length,
            jsLinks: [...document.querySelectorAll('a[href]')].filter((a) => /^\\s*javascript:/i.test(a.getAttribute('href'))).length })""")
        check("XSS1 six payloads (name, notes, feature, attack, item, resource, condition) execute nothing on home and all six tabs",
              injected == {"flag": None, "nodes": 0, "jsLinks": 0} and home_ok, injected)
        s.tab("bio")
        check("XSS2 ... and are shown literally as text (the name field holds the exact payload)",
              page.locator('#panel-bio input[data-f="name"]').input_value() == XSS["name"])
        body = page.locator("body").inner_text()
        check("XSS3 the notes payload is visible as typed text, not as bold markup", any("<b>bold?</b>" in v for v in page.locator('textarea[data-t="notes"]').evaluate_all("ts => ts.map((t) => t.value)"))
              and page.locator("b:text('bold?')").count() == 0, body[:200])

        # ---- 2. malformed numbers through the inputs ------------------------------------------------------------------------------
        s.tab("stats")
        cases = {}
        score = page.locator('#ability-cards input[data-f="strength"]')
        for raw in ("0", "31", "-4", "abc", "1e9", "99999999999999999999"):
            put(score, raw)
            page.wait_for_timeout(250)
            cases[f"STR {raw}"] = score.input_value()
        s.wait(lambda: page.locator("#save-status").get_attribute("data-state") in ("saved", "idle"), 8000)
        stored = db(f"select strength from public.characters where id = '{ch}'")
        check("NUM1 ability scores typed as 0 / 31 / -4 / abc / 1e9 / 20 digits stay within 1..30 on screen and in the database",
              all(v.isdigit() and 1 <= int(v) <= 30 for v in cases.values()) and 1 <= int(stored) <= 30, (cases, stored))
        s.tab("inventory")
        gp = page.locator('.coins input[data-f="gp"]')
        put(gp, "-25")
        hp = page.locator("#hp-card .hp-current")
        put(hp, "-7")
        s.wait(lambda: page.locator("#save-status").get_attribute("data-state") == "saved", 8000)
        page.wait_for_timeout(600)
        vals = db(f"select gp || ',' || hp_current from public.characters where id = '{ch}'")
        check("NUM2 negative coins and negative current HP become 0 (and the server would refuse them anyway)", vals == "0,0", vals)
        st, r = call("PATCH", f"/rest/v1/characters?id=eq.{ch}", {"gp": -5}, token=pl.jwt, key=os.environ["ANON_KEY"])
        check("NUM3 a negative coin value written around the UI is refused by the database", st >= 400 and db(f"select gp from public.characters where id = '{ch}'") == "0", (st, str(r)[:160]))
        put(hp, "30")
        s.wait(lambda: db(f"select hp_current from public.characters where id = '{ch}'") == "30", 8000)

        # ---- 3. interrupted save: the request is aborted, the edit is kept and lands after the network returns ------------------
        s.tab("bio")
        name = page.locator('#panel-bio input[data-f="name"]')
        page.route("**/rest/v1/characters?*", lambda route: route.abort() if route.request.method == "PATCH" else route.continue_())
        name.fill(f"Interrupted {RUN}")
        name.press("Tab")
        failed_state = s.wait(lambda: page.locator("#save-status").get_attribute("data-state") in ("error", "offline", "pending"), 10000)
        page.wait_for_timeout(1500)
        not_saved = db(f"select name from public.characters where id = '{ch}'") != f"Interrupted {RUN}"
        status_text = page.locator("#save-status").inner_text()
        page.unroute("**/rest/v1/characters?*")
        landed = s.wait(lambda: db(f"select name from public.characters where id = '{ch}'") == f"Interrupted {RUN}", 20000)
        check("INT1 an aborted autosave is reported (status '%s'), keeps the edit and saves it when the network is back" % status_text,
              failed_state and not_saved and landed, (status_text, not_saved, landed))

        # ---- 4. offline: edits queue and sync when the connection returns ---------------------------------------------------------
        s.ctx.set_offline(True)
        name.fill(f"Offline {RUN}")
        name.press("Tab")
        off = s.wait(lambda: "Offline" in page.locator("#save-status").inner_text() or page.locator("#save-status").get_attribute("data-state") in ("offline", "error"), 10000)
        off_text = page.locator("#save-status").inner_text()
        s.ctx.set_offline(False)
        page.evaluate("window.dispatchEvent(new Event('online'))")
        synced = s.wait(lambda: db(f"select name from public.characters where id = '{ch}'") == f"Offline {RUN}", 20000)
        check("OFF1 offline edits say so ('%s') and sync after reconnecting" % off_text, off and synced, (off_text, synced))
        db(f"update public.characters set name = $x${XSS['name']}$x$ where id = '{ch}'")

        # ---- 5. duplicate actions ------------------------------------------------------------------------------------------------
        s.tab("combat")
        s.wait(lambda: page.locator('[data-cf-action="res-use"][data-key*="second-wind"]').count() > 0)
        before = db(f"select coalesce(sum(expended), 0) from public.character_resources where character_id = '{ch}' and resource_key like '%second-wind%'")
        btn = page.locator('[data-cf-action="res-use"][data-key*="second-wind"]').first
        btn.dblclick()
        page.wait_for_timeout(1500)
        after = db(f"select coalesce(sum(expended), 0) from public.character_resources where character_id = '{ch}' and resource_key like '%second-wind%'")
        check("DUP1 a double-click on 'Use' spends one use, not two (%s -> %s)" % (before, after), int(after) - int(before) == 1, (before, after))

        # ---- 6. error boundaries: failing reads and actions show words, never database text --------------------------------------
        errors_before = len([e for e in s.errors if e.startswith("pageerror")])
        page.route("**/rest/v1/rpc/get_character_derived_stats*", lambda route: route.fulfill(status=500, content_type="application/json",
                   body=json.dumps({"code": "XX000", "message": "relation \"public._character_mods\" does not exist"})))
        s.open(ch)
        page.wait_for_timeout(1500)
        txt = page.locator("body").inner_text()
        check("ERR1 a failing derived-stats read leaves a usable sheet (tabs, HP) without database text on the page",
              page.locator(".tab").count() == 6 and page.locator("#hp-card").count() == 1 and not any(w in txt for w in TECH),
              [w for w in TECH if w in txt])
        page.unroute("**/rest/v1/rpc/get_character_derived_stats*")
        s.open(ch)
        s.tab("combat")
        page.route("**/rest/v1/rpc/expend_character_resource*", lambda route: route.fulfill(status=401, content_type="application/json",
                   body=json.dumps({"code": "PGRST301", "message": "JWT expired"})))
        page.locator('[data-cf-action="res-use"]').first.click()
        s.wait(lambda: page.locator(".toast").count() > 0, 6000)
        toast = s.toasts()
        check("ERR2 an expired session on an action says 'session has expired' and 'nothing was changed'",
              "session has expired" in toast.lower() and "nothing was changed" in toast.lower(), toast)
        page.unroute("**/rest/v1/rpc/expend_character_resource*")
        page.route("**/rest/v1/rpc/expend_character_resource*", lambda route: route.fulfill(status=400, content_type="application/json",
                   body=json.dumps({"code": "23514", "message": "new row for relation \"character_resources\" violates check constraint \"x\""})))
        page.wait_for_timeout(6600)
        page.locator('[data-cf-action="res-use"]').first.click()
        s.wait(lambda: "not valid" in s.toasts(), 6000)
        toast = s.toasts()
        check("ERR3 a constraint failure is shown as 'Some of the data is not valid. Nothing was changed.' without the constraint text",
              "not valid" in toast and "violates" not in toast and "character_resources" not in toast, toast)
        page.unroute("**/rest/v1/rpc/expend_character_resource*")
        check("ERR4 none of the injected failures produced an uncaught page error", len([e for e in s.errors if e.startswith("pageerror")]) == errors_before,
              [e for e in s.errors if e.startswith("pageerror")])

        # ---- 7. deep links ------------------------------------------------------------------------------------------------------
        links = {}
        for label, target in (("unknown id", str(uuid.uuid4())), ("not a uuid", "not-a-uuid'%3Cscript%3E"), ("someone else's character", foreign)):
            s.open(ch)   # a sheet is open before each link: nothing of it may remain on the error screen
            page.goto(f"{APP}#/c/{target}")
            page.wait_for_timeout(1800)
            links[label] = page.locator("body").inner_text()
        leak = "V62 Foreign" in links["someone else's character"]
        tech = {k: [w for w in TECH + ("JSON object requested", "invalid input syntax for type uuid") if w in v] for k, v in links.items()}
        stale = [k for k, v in links.items() if XSS["name"] in v and k != "not a uuid"]   # the list rightly shows own characters
        check("LINK1 unknown and foreign character links show the same 'could not be loaded' screen (no existence leak); a malformed link opens the list",
              "could not be loaded" in links["unknown id"] and "could not be loaded" in links["someone else's character"]
              and "Your characters" in links["not a uuid"] and not leak, {k: v[:160] for k, v in links.items()})
        check("LINK1b the error screen carries nothing of the character open before (top bar name / HP)", not stale, stale)
        check("LINK2 ... without database wording, with a way back to the character list",
              not any(tech.values()) and page.locator('a[href="#/"]:has-text("Back to your characters")').count() == 1, tech)
        page.locator('a[href="#/"]:has-text("Back to your characters")').click()
        check("LINK3 the way back works", s.wait(lambda: page.locator(".char-card").count() >= 1, 10000))
        page.goto(f"{APP}#/campaigns")
        page.wait_for_timeout(1500)
        check("LINK4 the admin route as a player shows no admin data and no error", len([e for e in s.errors if e.startswith("pageerror")]) == errors_before
              and page.locator("text=Manage campaigns").count() == 0 and "Something went wrong" not in page.locator("body").inner_text(), page.locator("body").inner_text()[:200])

        # ---- 8. missing assets: icons and fonts fail, the sheet still works ------------------------------------------------------
        page.route("**/*.{webp,svg,woff2}", lambda route: route.abort())
        s.open(ch)
        s.tab("inventory")
        s.tab("combat")
        check("ASSET1 with every icon and font failing to load the sheet still renders its tabs and actions, without page errors",
              page.locator(".tab").count() == 6 and page.locator('[data-cf-action="res-use"]').count() > 0
              and len([e for e in s.errors if e.startswith("pageerror")]) == errors_before)
        page.unroute("**/*.{webp,svg,woff2}")
        SHOTS.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=str(SHOTS / "v62_assets_missing.png"))

        # ---- 9. storage after sign-out ------------------------------------------------------------------------------------------
        s.open(ch)
        page.wait_for_timeout(800)
        page.goto(APP)
        page.wait_for_selector("#btn-signout")
        page.locator("#btn-signout").click()
        page.wait_for_selector("input[name=email]", timeout=10000)
        page.wait_for_timeout(500)
        store = page.evaluate("""() => ({ local: Object.keys(localStorage), session: Object.keys(sessionStorage),
            values: Object.keys(localStorage).map((k) => localStorage.getItem(k)).join(' ') + Object.keys(sessionStorage).map((k) => sessionStorage.getItem(k)).join(' ') })""")
        token_left = [k for k in store["local"] + store["session"] if "auth-token" in k or k.startswith("sb-")]
        data_left = [w for w in ("Interrupted", "Second Wind", ch) if w in store["values"]]
        check("STORE1 after sign-out no session token and no cached character data remain in local or session storage",
              not token_left and not data_left, (store["local"], store["session"], data_left))
        st, r = call("GET", f"/rest/v1/characters?id=eq.{ch}&select=name", token=os.environ["ANON_KEY"], key=os.environ["ANON_KEY"])
        check("STORE2 the anonymous key (all that is left in the browser) reads nothing", st == 200 and r == [], (st, r))
        page.goto(f"{APP}#/c/{ch}")
        page.wait_for_timeout(1200)
        check("STORE3 a signed-out deep link shows the sign-in form, not the cached sheet", page.locator("input[name=email]").count() == 1
              and XSS["name"] not in page.locator("body").inner_text())
        check("CONSOLE no uncaught page errors during the whole suite", not [e for e in s.errors if e.startswith("pageerror")],
              [e for e in s.errors if e.startswith("pageerror")])
        check("NET no request left the machine", not s.remote, s.remote[:5])
        s.close()
        browser.close()


main()
