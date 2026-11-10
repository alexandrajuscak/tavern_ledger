"""Cross-feature hardening test of the V6 product pass (docs/V6_PRODUCT_HARDENING_REVIEW.md).

Home, vitals, Abilities, Play, Spells, Inventory, Build, Wild Shape, approvals, DM Space, hidden data, accessibility,
responsive layouts and reliability (stale responses, duplicate actions, permanent save errors, Realtime cleanup, console,
network). It does not repeat the feature suites; it checks that the features hold together and the fixes of this pass.

Synthetic users (ui-*@example.test, removed by run_browser_local.sh) own everything; the campaign "UI Hardening Campaign" is
created and removed here. Refuses non-local URLs. Screenshots go to SCREENSHOT_DIR (outside the repository).
"""
import json
import subprocess
import uuid
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

from class_ui_common import APP, RUN, SHOTS, Sheet, User, call, check, report

DB = "supabase_db_tavern_ledger"
CAMP_NAME = "UI Hardening Campaign"
CURSE = "Bound to the bearer until dawn of doom"
TRUE_NAME = f"Ring of the Hollow Crown {RUN}"


def sql(q):
    r = subprocess.run(["docker", "exec", "-i", DB, "psql", "-U", "postgres", "-qAt", "-v", "ON_ERROR_STOP=1"], input=q.encode(), capture_output=True)
    if r.returncode:
        raise SystemExit(r.stderr.decode())
    return r.stdout.decode().strip()


sql(f"delete from public.characters where campaign_id in (select id from public.campaigns where name = '{CAMP_NAME}');"
    f"delete from public.campaigns where name = '{CAMP_NAME}'")
pl, dm = User("v6h-pl"), User("v6h-dm")
# A: Fighter 4 with Tough (base max 36, authoritative 44), daggers + chain mail, coins
fighter = pl.character(f"V6 Tough Fighter {RUN}", [("fighter-phb", 4)], strength=16, dexterity=14, constitution=14, intelligence=8,
                       wisdom=12, charisma=10, hp_max=36, hp_current=36)
st, r = pl.rpc("assign_character_feat", p_character=fighter, p_version="tough-2024", p_choices={}, p_source_type="direct",
               p_source_note=None, p_override_reason=None, p_notes=None)
assert st == 200, (st, r)
# a 2024 background (its card has sub-headings: the heading sweep covers them); modifiers stay the same (CON 15, INT 9, WIS 13)
st, r = pl.rpc("set_character_background", p_character=fighter, p_version="sage-2024", p_ability={"mode": "plus1_x3", "allocation": {"con": 1, "int": 1, "wis": 1}},
               p_choices={}, p_replacements=[], p_options={})
assert st == 200, (st, r)
_, inv = call("GET", f"/rest/v1/inventories?character_id=eq.{fighter}&kind=eq.character&select=id", token=pl.jwt)
items = {}
for item, qty in (("dagger", 2), ("chain-mail", 1)):
    st, r = pl.rpc("add_inventory_item", p_inventory=inv[0]["id"], p_item=item, p_quantity=qty, p_custom_name=None, p_notes=None, p_state={})
    assert st == 200, (item, st, r)
    items[item] = r["id"] if isinstance(r, dict) and "id" in r else r
# B: Wizard 5 with Fireball (Evocation) for slots and school icons
wizard = pl.character(f"V6 Wizard {RUN}", [("wizard-phb", 5)], intelligence=18, dexterity=14, hp_max=27, hp_current=27)
_, rows = call("GET", f"/rest/v1/character_spellcasting_sources?character_id=eq.{wizard}&select=id", token=pl.jwt)
st, r = pl.rpc("set_character_spell", p_character=wizard, p_source=rows[0]["id"], p_spell_version="fireball-phb", p_known=True, p_prepared=True,
               p_always_prepared=False, p_casting_ability=None, p_ritual_allowed=None, p_notes=None)
assert st == 200, (st, r)
# C: Moon Druid 6 in Brown Bear form
druid = pl.character(f"V6 Moon Druid {RUN}", [("druid-phb", 6, "druid-moon-phb")], strength=8, dexterity=14, constitution=14, intelligence=12,
                     wisdom=16, charisma=10, hp_max=45, hp_current=45)
st, r = pl.rpc("start_transformation", p_character=druid, p_creature="brown-bear", p_options={})
assert st == 200, (st, r)
# D: governed fighter in a standard campaign; E: build-locked rogue
gov = pl.character(f"V6 Governed Fighter {RUN}", [("fighter-phb", 3)], strength=15, constitution=14)
locked = pl.character(f"V6 Locked Rogue {RUN}", [("rogue-phb", 3)], dexterity=16)
camp = str(uuid.uuid4())
sql(f"""insert into public.campaigns (id, name, created_by) values ('{camp}', '{CAMP_NAME}', '{dm.id}');
insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player');
insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'standard');
update public.characters set campaign_id = '{camp}' where id in ('{gov}', '{locked}');
insert into public.character_governance (character_id, setup_complete, lock_mode, lock_reason) values ('{gov}', true, 'unlocked', null),
  ('{locked}', true, 'build_locked', 'Session in progress');""")
# a hidden, unidentified item assigned by the DM
st, ring = dm.rpc("create_dm_content", p_type="item", p_campaign=camp, p_request_id=str(uuid.uuid4()), p_fields={
    "name": TRUE_NAME, "player_text": "Cold to the touch.", "definition": {"item": {"kind_id": "gear", "is_magic": True, "rarity_id": "rare"},
    "hidden": {"unidentified_name": "Dull pewter ring", "curse": CURSE}}})
assert 200 <= st < 300, ring
st, ring = dm.rpc("publish_dm_content", p_content=ring["id"])
assert 200 <= st < 300, ring
st, r = dm.rpc("dm_assign_content", p_content=ring["id"], p_characters=[gov], p_mode="inventory", p_options={"quantity": 1, "identified": False})
assert 200 <= st < 300, r
# a pending player request (a class level) for the DM's "Needs you"
st, req = pl.rpc("create_change_request", p_character=gov, p_ops=[{"op": "set_character_class", "args": {"p_class_version": "fighter-phb", "p_level": 4}}],
                 p_idempotency_key=str(uuid.uuid4()))
assert 200 <= st < 300, req


def shot(page, name, sel=None):
    SHOTS.mkdir(parents=True, exist_ok=True)
    (page.locator(sel).first if sel else page).screenshot(path=str(SHOTS / f"{name}.png"))


HEADINGS = """() => { const vis = (e) => !!(e.offsetParent || e.getClientRects().length);
  const hs = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].filter(vis).map((h) => +h.tagName[1]);
  return hs.filter((l, i) => i > 0 && l > hs[i - 1] + 1).length; }"""
UNNAMED = """() => { const vis = (e) => !!(e.offsetParent || e.getClientRects().length);
  return [...document.querySelectorAll('button, a[href], input:not([type=hidden]), select, textarea')].filter(vis).filter((e) => {
    const lb = e.getAttribute('aria-labelledby');
    const n = (e.getAttribute('aria-label') || (lb && lb.split(' ').map((i) => document.getElementById(i)?.textContent || '').join('')) || e.textContent
      || e.getAttribute('title') || e.getAttribute('placeholder') || (e.id && document.querySelector(`label[for="${e.id}"]`)?.textContent) || e.closest('label')?.textContent || '').trim();
    return !n; }).map((e) => e.outerHTML.slice(0, 100)); }"""


def main():
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, pl, tab="combat")
        page = s.page
        external, joins, bodies = [], {"join": 0, "leave": 0}, []
        s.ctx.on("request", lambda r: external.append(r.url) if urlparse(r.url).hostname not in ("127.0.0.1", "localhost") else None)

        def ws(w):
            w.on("framesent", lambda f: joins.update(join=joins["join"] + (1 if '"phx_join"' in str(f) and "realtime:" in str(f) else 0),
                                                     leave=joins["leave"] + (1 if '"phx_leave"' in str(f) else 0)))
            w.on("framereceived", lambda f: bodies.append(str(f)[:4000]))
        page.on("websocket", ws)
        page.on("response", lambda r: bodies.append(r.text()[:20000]) if "/rest/v1/" in r.url and r.request.method in ("GET", "POST") and r.ok else None)
        # (bodies: every player REST response and Realtime frame; the DM's own reads are not collected)

        # ================= HOME ============================================================================================
        # the card values are held back for a moment: since the 2026-11 performance release they come through the server read
        # cache and can arrive before the first look at the page (the check is about what shows BEFORE they arrive)
        slow = "**/rest/v1/rpc/get_character_{reads,derived_stats}"
        page.route(slow, lambda r: (page.wait_for_timeout(1200), r.continue_()))
        page.goto(APP)
        page.wait_for_selector(".char-card")
        first = page.evaluate("""() => [...document.querySelectorAll('.char-card')].map((c) => c.querySelector('[data-cc-ac]').textContent.trim())""")
        page.unroute(slow)
        der_f = pl.rpc("get_character_derived_stats", p_character=fighter)[1]
        check("H3 a fresh browser shows loading marks, never the legacy stored AC, until the authoritative values arrive", set(first) == {"…"}, sorted(set(first)))
        s.wait(lambda: page.locator(".cc-wait").count() == 0, timeout=20000)
        card = page.locator(f'.char-card[data-char="{fighter}"]')
        check("H1 the fighter card shows the derived maximum HP with Tough (36 / 44)", "36 / 44" in card.inner_text(), card.inner_text())
        check("H2 the card AC is the authoritative one", card.locator("[data-cc-ac]").inner_text().strip() == str(der_f["armor_class"]["value"]))
        dcard, lcard, gcard = (page.locator(f'.char-card[data-char="{x}"]') for x in (druid, locked, gov))
        check("H4 urgent state on cards: Wild Shape, Locked, and the pending request",
              "Wild Shape" in dcard.inner_text() and "Locked" in lcard.inner_text() and "waiting" in gcard.inner_text().lower(),
              (dcard.inner_text(), lcard.inner_text(), gcard.inner_text()))
        n_cards = page.locator(".char-card").count()
        check("H5 the search box appears only for longer lists (five characters: no search box to scroll past)",
              n_cards == 5 and not page.locator("#char-search").is_visible(), n_cards)
        shot(page, "home_1366")

        # ================= VITALS + HP =====================================================================================
        s.open(fighter)
        s.wait(lambda: page.locator('#hp-card [data-derived="hp-max"]').inner_text().strip() == "44")
        hp = page.locator("#hp-card .hp-current")
        hp.fill("120")
        hp.press("Tab")
        check("V4 typing a current HP above the maximum is limited to the authoritative maximum (44)", s.wait(lambda: hp.input_value() == "44"), hp.input_value())
        page.fill("#hp-amount", "44")
        page.locator('[data-action="hp-damage"]').click()
        check("V2a damage to zero shows 'Down' in words and the death saves", s.wait(lambda: page.locator("[data-hp-state-text]").inner_text().strip() == "Down")
              and page.locator("#hp-card .death-saves").is_visible())
        page.fill("#hp-amount", "1")
        page.locator('[data-action="hp-heal"]').click()
        check("V2b healing 1 from zero: 1 / 44, Critical", s.wait(lambda: hp.input_value() == "1") and page.locator("[data-hp-state-text]").inner_text().strip() == "Critical")
        page.fill("#hp-amount", "100")
        page.locator('[data-action="hp-heal"]').dblclick()
        check("V3 a double-click on Heal applies once (cleared field) and stops at 44", s.wait(lambda: hp.input_value() == "44"))
        page.locator(".compact-toggle").click()
        check("V1 collapse keeps HP, bar, shield and cards", page.locator("#hp-card .hp-bar").is_visible() and page.locator(".tile-ac").is_visible())
        page.locator(".compact-toggle").click()

        # ================= ABILITIES =======================================================================================
        s.tab("stats")
        s.wait(lambda: page.locator('#ability-cards [data-ability="int"] .ability-mod').inner_text().strip() != "")
        check("A1 six ability cards in order", page.locator("#ability-cards > .ab-block").evaluate_all("bs => bs.map((b) => b.dataset.ability)") == ["str", "dex", "con", "int", "wis", "cha"])
        check("A2 skills under their ability (Stealth under DEX, Insight under WIS)", page.locator('#ability-cards [data-ability="dex"] [data-k="stealth"]').count() == 1
              and page.locator('#ability-cards [data-ability="wis"] [data-k="insight"]').count() == 1)
        insp = page.locator('.sum-tile [data-action="toggle-inspiration"]')
        insp.click()
        check("A5 Inspiration turns on (aria-pressed) and is saved", s.wait(lambda: insp.get_attribute("aria-pressed") == "true")
              and s.wait(lambda: sql(f"select inspiration from public.characters where id = '{fighter}'") == "t"))
        insp.click()
        s.wait(lambda: sql(f"select inspiration from public.characters where id = '{fighter}'") == "f")
        check("A4 passive values (Perception 11)", page.locator('.sum-tile [data-derive="passive:perception"]').inner_text().strip() == "11")
        dot = page.locator('#ability-cards [data-action="cycle-skill"][data-k="arcana"]')
        dot.scroll_into_view_if_needed()   # elementFromPoint only sees the viewport
        box = dot.bounding_box()
        hit = page.evaluate("""(k) => { const d = document.querySelector(`#ability-cards [data-k="${k}"]`); const r = d.getBoundingClientRect();
            return document.elementFromPoint(r.left - 3, r.top + r.height / 2) === d; }""", "arcana")
        check("X6a the skill marks keep a 20 px look but a larger hit area (a click 3 px outside still hits)", box["width"] <= 22 and hit, (box, hit))

        # ================= PLAY ============================================================================================
        s.tab("combat")
        s.wait(lambda: page.locator('[data-cf-action="res-use"]').count() > 0)
        groups = page.locator("#panel-combat .section-title, #panel-combat .play-title").all_inner_texts()
        check("P1 Play shows Attacks and the action timings (Actions, Bonus actions)", any("ttack" in g for g in groups) and any("Bonus" in g for g in groups), groups)
        use = page.locator('[data-cf-action="res-use"][data-key*="second-wind"], [data-cf-action="res-use"]').first
        key = use.get_attribute("data-key")
        before = page.locator(f'[data-cf-res="{key}"] [data-cf-res-count]').first.inner_text()
        use.click()
        check("P3 using a resource changes its count and says so", s.wait(lambda: page.locator(f'[data-cf-res="{key}"] [data-cf-res-count]').first.inner_text() != before), (key, before))
        check("X1 Play headings never skip a level", page.evaluate(HEADINGS) == 0, page.evaluate(HEADINGS))

        # ================= INVENTORY =======================================================================================
        s.tab("inventory")
        s.wait(lambda: page.locator(".inv-summary .inv-metric").count() == 4)
        check("I1 metric cards: 2 items, 3 pieces, 57 lb", "3 pieces" in page.locator(".inv-m-items").inner_text() and "57" in page.locator(".inv-m-weight").inner_text())
        ac0 = page.locator('[data-derived="ac"]').first.inner_text().strip()
        st, r = pl.rpc("equip_item", p_item=items["chain-mail"], p_slot="armor", p_replace=False)
        check("I2 equipping armor elsewhere (API) updates the vitals AC through Realtime (12 -> 16)",
              200 <= st < 300 and s.wait(lambda: page.locator('[data-derived="ac"]').first.inner_text().strip() == "16", timeout=15000), (st, r, ac0))
        check("X1b Inventory headings never skip a level", page.evaluate(HEADINGS) == 0)

        # ================= SPELLS: duplicate prevention + character switch with a pending mutation ===========================
        s.open(wizard)
        s.tab("spells")
        s.wait(lambda: page.locator('#slot-tracker [data-action="slot-use"][data-level="1"]').count() == 1)
        icon = page.locator('#spellbook-list .sp-card[data-spell="fireball-phb"] img.sp-icon')
        check("S3 Fireball keeps its school icon (Evocation)", icon.count() == 1 and icon.first.get_attribute("data-icon") == "spell.school.evocation")
        page.locator('#slot-tracker [data-action="slot-use"][data-level="1"]').dblclick()
        s.wait(lambda: "3 / 4" in page.locator('#slot-tracker [data-slot-count="1"]').inner_text(), timeout=10000)
        page.wait_for_timeout(1200)
        used = sql(f"select expended from public.character_spell_slot_state where character_id = '{wizard}' and pool = 'standard' and slot_level = 1")
        check("S2 a double-click on Use spends exactly one slot (server: 1 expended)", used == "1", used)
        page.locator('#slot-tracker [data-action="slot-use"][data-level="2"]').click()
        page.goto(f"{APP}#/c/{fighter}")              # leave while the slot request is in flight
        s.wait(lambda: page.locator(".char-name").inner_text().startswith("V6 Tough Fighter"))
        page.wait_for_timeout(1500)
        wiz2 = sql(f"select expended from public.character_spell_slot_state where character_id = '{wizard}' and pool = 'standard' and slot_level = 2")
        check("Z1 switching characters during a slot request: the wizard spent exactly one 2nd-level slot and the fighter sheet shows the fighter",
              wiz2 == "1" and "V6 Tough Fighter" in page.locator(".char-name").inner_text() and page.locator("#slot-tracker [data-slot-pool]").count() == 0, wiz2)
        for cid in (wizard, druid, fighter, wizard, gov):
            page.goto(f"{APP}#/c/{cid}")
            page.wait_for_timeout(150)
        check("Z2 rapid switching ends on the last character", s.wait(lambda: page.locator(".char-name").inner_text().startswith("V6 Governed Fighter")))
        page.wait_for_timeout(1500)
        check("Z6 Realtime channels are cleaned up when switching (open = 2: the sheet and its requests)", joins["join"] - joins["leave"] == 2, joins)

        # ================= BUILD, locks and governance labels ===============================================================
        s.tab("features")
        check("B3 a governed character asks the DM: 'Request level up', and the open request is shown as waiting",
              s.wait(lambda: "Request level up" in page.locator("#panel-features").inner_text())
              and "waiting" in (page.locator("#sheet-chips").inner_text() + page.locator("#gov-bar").inner_text()).lower())
        nexts = page.locator("#build-next-wrap li, #build-next-wrap .next-list > *").all_inner_texts()
        check("B1 each Next step appears once", len(nexts) == len(set(nexts)), nexts)
        check("X1c Build headings never skip a level", page.evaluate(HEADINGS) == 0)
        s.tab("inventory")
        s.wait(lambda: "Dull pewter ring" in page.locator("#panel-inventory").inner_text())
        html = page.content()
        store = page.evaluate("() => JSON.stringify({ l: { ...localStorage }, s: { ...sessionStorage } })")
        check("SEC1 the unidentified ring shows only its disguise; the true name and curse are not in the DOM or browser storage",
              TRUE_NAME not in html and CURSE not in html and TRUE_NAME not in store and CURSE not in store)
        s.tab("bio")
        with page.expect_download() as dl:
            page.locator('[data-action="export-json"]').click()
        data = open(dl.value.path(), encoding="utf-8").read()
        check("SEC2 the exported character file holds no hidden DM data", CURSE not in data and TRUE_NAME not in data and "Dull pewter ring" in data)
        page.goto(f"{APP}#/c/{locked}")
        s.wait(lambda: page.locator(".gov-lock").count() > 0)
        check("L1 a build-locked character shows the lock banner with the DM's reason", "Session in progress" in page.locator("#gov-bar").inner_text())
        s.tab("features")
        lvl = page.locator('[data-level-up-blocked], [data-action="level-up"]').first
        check("L2 level up is disabled with an explanation that names the build lock", lvl.is_disabled() and "locked the build" in page.locator("#level-up-reason").inner_text(),
              page.locator("#panel-features").inner_text()[:300])
        s.tab("combat")
        page.fill("#hp-amount", "2")
        page.locator('[data-action="hp-damage"]').click()
        check("L3 runtime actions still work on a build-locked character (damage applies)", s.wait(lambda: "Took 2 damage" in s.toasts()))

        # ================= WILD SHAPE ======================================================================================
        page.goto(f"{APP}#/c/{druid}")
        s.wait(lambda: "Brown Bear" in page.locator("#hp-card").inner_text())
        check("W1 form HP is the primary HP in the vitals (34 / 34)", "34" in page.locator("#hp-card .hp-form-num").inner_text())
        s.tab("stats")
        s.wait(lambda: page.locator('#ability-cards [data-ability="str"] .ab-src').inner_text().strip() == "From form")
        check("W2 STR from the form (+4), WIS retained (+3)", page.locator('#ability-cards [data-ability="str"] .ability-mod').inner_text().strip() == "+4"
              and page.locator('#ability-cards [data-ability="wis"] .ab-src').inner_text().strip() == "Retained from character")
        s.tab("combat")
        page.locator('[data-action="tf-end"]').first.click()
        page.wait_for_selector(".modal [data-ok]")
        check("X3 a confirmation dialog takes focus when it opens", s.wait(lambda: page.evaluate("() => !!document.activeElement.closest('.modal')")))
        page.locator(".modal [data-ok]").last.click()
        check("W3 Revert ends the form: normal HP 45 is primary again", s.wait(lambda: not page.locator("#hp-card").evaluate("e => e.classList.contains('is-form')"), timeout=15000)
              and page.locator("#hp-card .hp-current").input_value() == "45")

        # ================= RELIABILITY: a save the server refuses is not retried forever ====================================
        page.goto(f"{APP}#/c/{fighter}")
        s.wait(lambda: page.locator("#hp-card .hp-current").count() == 1)
        s.tab("bio")
        hits = []

        def refuse(route):
            if route.request.method == "PATCH":
                hits.append(1)
                return route.fulfill(status=400, content_type="application/json",
                                     body=json.dumps({"code": "23514", "message": 'new row for relation "characters" violates check constraint "characters_x_check"', "details": None, "hint": None}))
            return route.continue_()
        page.route("**/rest/v1/characters?*", refuse)
        page.locator('[data-f="alignment"]').fill(f"Lawful Testing {RUN}")
        page.locator('[data-f="alignment"]').press("Tab")
        check("Z7 a permanently refused save is reported in plain words, without the constraint name",
              s.wait(lambda: "Not saved: Some of the data is not valid" in s.toasts(), timeout=8000) and "characters_x_check" not in s.toasts(), s.toasts())
        page.wait_for_timeout(4000)
        check("Z7b ... and it is not retried in a loop", len(hits) == 1, len(hits))
        page.unroute("**/rest/v1/characters?*")
        s.wait(lambda: page.locator(".char-name").count() == 1)

        # ================= RESPONSIVE + A11Y sweep ==========================================================================
        page.goto(f"{APP}#/c/{fighter}")
        s.wait(lambda: page.locator(".tab").count() > 0)
        over, skips, unnamed = {}, {}, {}
        for w, h in ((1366, 768), (820, 1180), (390, 844), (360, 800)):
            page.set_viewport_size({"width": w, "height": h})
            for t in ("combat", "stats", "spells", "inventory", "features", "bio"):
                s.tab(t)
                o = s.overflow()
                if o > 0:
                    over[f"{w}/{t}"] = o
                k = page.evaluate(HEADINGS)
                if k:
                    skips[f"{w}/{t}"] = k
                u = page.evaluate(UNNAMED)
                if u:
                    unnamed[f"{w}/{t}"] = u[:3]
        check("R1 no page-level horizontal overflow on any tab at 1366, 820, 390 and 360", not over, over)
        check("X1d no heading-level skips on any tab at any width", not skips, skips)
        check("X2 every visible control has an accessible name", not unnamed, unnamed)
        page.set_viewport_size({"width": 390, "height": 844})
        s.tab("combat")
        small = page.evaluate("""() => ['.compact-toggle', '.ac-button'].map((q) => { const r = document.querySelector(q).getBoundingClientRect(); return [q, Math.round(r.width), Math.round(r.height)]; })""")
        check("X6b on a phone the collapse handle and the AC button are at least 24 px targets", all(wd >= 24 and ht >= 24 for _, wd, ht in small), small)
        shot(page, "fighter_390")
        page.emulate_media(reduced_motion="reduce")
        dur = page.evaluate("() => getComputedStyle(document.querySelector('.hp-fill')).transitionDuration")
        check("X5 reduced motion: transitions are off", all(x in ("0s", "0ms") for x in dur.split(", ")), dur)
        page.emulate_media(reduced_motion="no-preference")
        page.set_viewport_size({"width": 1366, "height": 900})
        s.close()

        # ================= DM ==============================================================================================
        D = Sheet(browser, dm, tab="combat")
        d = D.page
        d.goto(APP + "#/dm/overview")
        D.wait(lambda: d.locator("[data-dm-campaign]").count() > 0)
        d.select_option("[data-dm-campaign]", camp)
        D.wait(lambda: CAMP_NAME in d.locator(".dm-title h1").inner_text())
        check("DM1 'Needs you' lists the pending request", D.wait(lambda: any(w in d.locator("[data-dm-panel]").inner_text().lower() for w in ("request", "approval"))),
              d.locator("[data-dm-panel]").inner_text()[:300])
        for sec in ("party", "approvals", "assign", "hidden", "rules", "audit"):
            d.locator(f'[data-dm-section="{sec}"]').click()
            d.wait_for_timeout(900)
            k = d.evaluate(HEADINGS)
            if k:
                skips[f"dm/{sec}"] = k
        check("DM2 DM Space sections never skip a heading level (a section h2 sits above the cards)", not any(x.startswith("dm/") for x in skips), skips)
        d.set_viewport_size({"width": 360, "height": 800})
        d.locator('[data-dm-section-select]').select_option("rules")
        d.wait_for_timeout(1200)
        check("DM3 Campaign rules fit a 360 px phone (long button labels wrap)", D.overflow() <= 0, D.overflow())
        check("C1 no console errors for the player or the DM", not D.errors, D.errors[:3])
        D.close()
        check("NET1 no request left this machine (supabase-js and fonts are self-hosted)", not external, external[:3])
        leak = [b[:120] for b in bodies if CURSE in b or TRUE_NAME in b]
        check("SEC3 no player REST response or Realtime frame carried the true name or the curse", not leak and len(bodies) > 50, (len(bodies), leak[:2]))
        browser.close()
    sql(f"delete from public.characters where campaign_id = '{camp}'; delete from public.campaigns where id = '{camp}'")
    report()


main()
